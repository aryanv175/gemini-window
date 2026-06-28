import Cocoa
import WebKit
import Carbon.HIToolbox

// MARK: - Configuration
// Global hotkey: ⌘ (Command) + ⌥ (Option) + G  ->  toggles the Gemini window.
private let geminiURL = URL(string: "https://gemini.google.com/app")!
private let hotKeyKeyCode = UInt32(kVK_ANSI_G)
private let hotKeyModifiers = UInt32(cmdKey | optionKey)
// Notification-sized compact window (Mac banner ≈ 344pt wide).
private let windowWidth: CGFloat = 350
private let windowHeight: CGFloat = 185
// A normal desktop Safari UA so Google sign-in treats the WKWebView as a real browser.
private let safariUserAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

// Injected CSS: black & white + transparent backgrounds so the glass shows through.
private let styleCSS = """
/* Black & white */
html { filter: grayscale(1) contrast(1.05) !important; }
/* Make every surface transparent so the frosted glass shows through everywhere */
:root, html, body, body * {
  background: transparent !important;
  background-color: transparent !important;
  background-image: none !important;
  box-shadow: none !important;
}
/* Re-add a faint surface only where you actually need to read/type */
input, textarea, [contenteditable=true], .ql-editor,
[class*=input], [class*=Input] {
  background: rgba(255,255,255,0.08) !important;
  border-radius: 12px !important;
}
::-webkit-scrollbar { width: 0px; background: transparent; }
"""

// Injected JS: force black & white + frosted-glass transparency. Uses inline styles
// (which beat Gemini's stylesheet !important rules) and a MutationObserver to keep
// re-applying as the page re-renders.
private let glassJS = """
(function () {
  function apply() {
    document.documentElement.style.setProperty('filter', 'grayscale(1) contrast(1.05)', 'important');
    var nodes = document.querySelectorAll('body, body *');
    for (var i = 0; i < nodes.length; i++) {
      var el = nodes[i];
      el.style.setProperty('background-color', 'transparent', 'important');
      el.style.setProperty('background-image', 'none', 'important');
      el.style.setProperty('box-shadow', 'none', 'important');
    }
    hideChrome();
  }
  // Strip the top toolbar (hamburger, "Gemini Flash" model selector, new-chat icon),
  // the "+" attach button, the text input, and the zero-state greeting so the window
  // is a clean, voice-only surface.
  function hideChrome() {
    var labels = ['main menu', 'expand the menu', 'collapse the menu', 'open menu',
                  'new chat', 'new conversation', 'menu', 'settings', 'account',
                  'upload', 'attach', 'add files', 'add photo', 'insert', 'open upload'];
    var btns = document.querySelectorAll('button, [role=button], a');
    for (var i = 0; i < btns.length; i++) {
      var b = btns[i];
      var l = ((b.getAttribute('aria-label') || '') + ' ' + (b.textContent || '')).toLowerCase().trim();
      var r = b.getBoundingClientRect();
      var topStrip = r.width > 0 && r.height > 0 && r.top < 64;            // top toolbar
      var labeled = labels.some(function (k) { return l.indexOf(k) > -1; });
      var model = /\\b(flash|pro|ultra|nano)\\b/.test(l) || l.indexOf('gemini ') > -1; // model switcher
      var plus = l === '+' || l === 'add';                                // bare "+" attach button
      if (topStrip || labeled || model || plus) b.style.setProperty('display', 'none', 'important');
    }
    // Hide the typing field.
    var inputs = document.querySelectorAll('textarea, [contenteditable=true], .ql-editor, rich-textarea');
    for (var j = 0; j < inputs.length; j++) inputs[j].style.setProperty('display', 'none', 'important');
    // Hide the zero-state greeting ("Hi A, let's get into it", etc.).
    var greet = /(let'?s (jump|get|dive)|get into it|what'?s the vibe|how can i help|good (morning|afternoon|evening)|^h(i|ey|ello)\\b)/i;
    var texts = document.querySelectorAll('h1, h2, h3, p, span, div');
    for (var k = 0; k < texts.length; k++) {
      var t = texts[k];
      if (t.children.length === 0) {
        var tx = (t.textContent || '').trim();
        if (tx.length > 0 && tx.length < 60 && greet.test(tx)) {
          t.style.setProperty('display', 'none', 'important');
        }
      }
    }
  }
  apply();
  var pending;
  var obs = new MutationObserver(function () {
    clearTimeout(pending); pending = setTimeout(apply, 250);
  });
  obs.observe(document.documentElement, { childList: true, subtree: true });
})();
"""

// Injected JS: auto-enter voice mode by clicking the microphone button when it appears.
private let voiceJS = """
(function () {
  let tries = 0;
  const timer = setInterval(function () {
    tries++;
    const nodes = Array.prototype.slice.call(document.querySelectorAll('button, [role=button], [aria-label]'));
    const hit = nodes.find(function (b) {
      const label = ((b.getAttribute('aria-label') || '') + ' ' + (b.textContent || '')).toLowerCase();
      return label.indexOf('microphone') !== -1 || label.indexOf('use voice') !== -1 ||
             label.indexOf('voice input') !== -1 || label.indexOf('speak') !== -1 ||
             label.indexOf('gemini live') !== -1;
    });
    if (hit) { hit.click(); clearInterval(timer); }
    if (tries > 30) clearInterval(timer);
  }, 400);
})();
"""

// MARK: - Panel that can accept keyboard focus
final class GeminiPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - App Delegate
final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate {
    private var panel: GeminiPanel!
    private var webView: WKWebView!
    private var hotKeyRef: EventHotKeyRef?
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // background app, no Dock icon
        buildWindow()
        buildMenuBarItem()
        registerHotKey()
        showPanel() // show once on first launch so the user can sign in
    }

    // MARK: Window + WebView
    private func buildWindow() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default() // persists Google login
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        // Base CSS at document start (scrollbar + early transparency hint).
        let styleScript = WKUserScript(
            source: "var s=document.createElement('style');s.textContent=`\(styleCSS)`;"
                  + "document.documentElement.appendChild(s);",
            injectionTime: .atDocumentStart, forMainFrameOnly: true)
        config.userContentController.addUserScript(styleScript)
        // Inline-style hammer at document end (beats Gemini's stylesheet !important rules).
        config.userContentController.addUserScript(WKUserScript(
            source: glassJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true))

        let frame = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)
        webView = WKWebView(frame: frame, configuration: config)
        webView.customUserAgent = safariUserAgent
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.setValue(false, forKey: "drawsBackground") // transparent webview -> glass shows

        // Rounded container holding the glass layer and the webview as siblings, so the
        // glass can be dialed back (more see-through) without dimming the webview content.
        let container = NSView(frame: frame)
        container.wantsLayer = true
        container.layer?.cornerRadius = 22
        container.layer?.masksToBounds = true

        let effect = NSVisualEffectView(frame: frame)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        effect.alphaValue = 0.45 // lighter frost -> more see-through

        webView.frame = frame
        webView.autoresizingMask = [.width, .height]
        container.addSubview(effect)
        container.addSubview(webView) // webview on top at full opacity

        let style: NSWindow.StyleMask = [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel]
        panel = GeminiPanel(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentView = container
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        positionTopRight()
    }

    private func positionTopRight() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let margin: CGFloat = 16
        let origin = NSPoint(x: visible.maxX - size.width - margin,
                             y: visible.maxY - size.height - margin)
        panel.setFrameOrigin(origin)
    }

    // MARK: Menu bar item
    private func buildMenuBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Gemini")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Gemini  (⌘⌥G)", action: #selector(menuToggle), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Start Voice", action: #selector(menuVoice), keyEquivalent: "")
        menu.addItem(withTitle: "Reload", action: #selector(menuReload), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Gemini Window", action: #selector(menuQuit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        statusItem.menu = menu
    }

    @objc private func menuToggle() { togglePanel() }
    @objc private func menuReload() { webView.reload() }
    @objc private func menuVoice() { webView.evaluateJavaScript(voiceJS, completionHandler: nil) }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    // MARK: Panel visibility
    func togglePanel() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        // Load a fresh Gemini chat every time the window is opened.
        webView.load(URLRequest(url: geminiURL))
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(webView)
    }

    // MARK: WKNavigationDelegate — kick off voice mode once the page is ready
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript(glassJS, completionHandler: nil)
        webView.evaluateJavaScript(voiceJS, completionHandler: nil)
    }

    // MARK: WKUIDelegate
    // Grant microphone access so voice mode works inside the webview.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.grant)
    }

    // Open target=_blank links in the same view.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, navigationAction.targetFrame == nil {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    // MARK: Global hotkey (Carbon — no Accessibility permission needed)
    private func registerHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { (_, _, userData) -> OSStatus in
            guard let userData = userData else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { delegate.togglePanel() }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), nil)

        let hotKeyID = EventHotKeyID(signature: OSType(0x47454D49) /* 'GEMI' */, id: 1)
        let status = RegisterEventHotKey(hotKeyKeyCode, hotKeyModifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        let msg = status == noErr ? "GeminiWindow: hotkey registered OK (Cmd+Opt+G)\n"
                                  : "GeminiWindow: hotkey registration FAILED, status=\(status)\n"
        FileHandle.standardError.write(msg.data(using: .utf8)!)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

// MARK: - Entry point
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
