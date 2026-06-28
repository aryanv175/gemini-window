import Cocoa
import WebKit
import Carbon.HIToolbox

// MARK: - Configuration
// Global hotkey: ⌘ (Command) + ⌥ (Option) + G  ->  toggles the Gemini pill.
private let geminiURL = URL(string: "https://gemini.google.com/app")!
private let hotKeyKeyCode = UInt32(kVK_ANSI_G)
private let hotKeyModifiers = UInt32(cmdKey | optionKey)

// A Siri-style pill that grows into a small voice panel when you tap to talk.
private let pillWidth: CGFloat = 460
private let pillHeight: CGFloat = 64        // collapsed: just the "Talk to Gemini" pill
private let panelHeight: CGFloat = 540       // expanded: pill header + Gemini voice webview

// A normal desktop Safari UA so Google sign-in treats the WKWebView as a real browser.
private let safariUserAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

// Injected JS: force black & white + frosted-glass transparency, and strip Gemini's
// chrome (top bar, model selector, attach "+", text box, greeting) so the expanded
// panel is a clean voice surface. Inline styles beat Gemini's stylesheet !important.
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
  function hideChrome() {
    var labels = ['main menu', 'expand the menu', 'collapse the menu', 'open menu',
                  'new chat', 'new conversation', 'menu', 'settings', 'account',
                  'upload', 'attach', 'add files', 'add photo', 'insert', 'open upload'];
    var btns = document.querySelectorAll('button, [role=button], a');
    for (var i = 0; i < btns.length; i++) {
      var b = btns[i];
      var l = ((b.getAttribute('aria-label') || '') + ' ' + (b.textContent || '')).toLowerCase().trim();
      var r = b.getBoundingClientRect();
      var topStrip = r.width > 0 && r.height > 0 && r.top < 64;
      var labeled = labels.some(function (k) { return l.indexOf(k) > -1; });
      var model = /\\b(flash|pro|ultra|nano)\\b/.test(l) || l.indexOf('gemini ') > -1;
      var plus = l === '+' || l === 'add';
      if (topStrip || labeled || model || plus) b.style.setProperty('display', 'none', 'important');
    }
    var inputs = document.querySelectorAll('textarea, [contenteditable=true], .ql-editor, rich-textarea');
    for (var j = 0; j < inputs.length; j++) inputs[j].style.setProperty('display', 'none', 'important');
    var greet = /(let'?s (jump|get|dive)|get into it|what'?s the vibe|how can i help|good (morning|afternoon|evening)|^h(i|ey|ello)\\b)/i;
    var texts = document.querySelectorAll('h1, h2, h3, p, span, div');
    for (var k = 0; k < texts.length; k++) {
      var t = texts[k];
      if (t.children.length === 0) {
        var tx = (t.textContent || '').trim();
        if (tx.length > 0 && tx.length < 60 && greet.test(tx)) t.style.setProperty('display', 'none', 'important');
      }
    }
  }
  apply();
  var pending;
  var obs = new MutationObserver(function () { clearTimeout(pending); pending = setTimeout(apply, 250); });
  obs.observe(document.documentElement, { childList: true, subtree: true });
})();
"""

// Injected JS: auto-enter voice mode by clicking the microphone button when it appears.
private let voiceJS = """
(function () {
  var tries = 0;
  var timer = setInterval(function () {
    tries++;
    var nodes = Array.prototype.slice.call(document.querySelectorAll('button, [role=button], [aria-label]'));
    var hit = nodes.find(function (b) {
      var label = ((b.getAttribute('aria-label') || '') + ' ' + (b.textContent || '')).toLowerCase();
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

// A view that reports clicks (so the whole pill is tappable to start talking).
final class ClickView: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
}

// MARK: - App Delegate
final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate {
    private var panel: GeminiPanel!
    private var container: NSView!
    private var header: ClickView!
    private var webView: WKWebView!
    private var promptLabel: NSTextField!
    private var hotKeyRef: EventHotKeyRef?
    private var statusItem: NSStatusItem!
    private var expanded = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildWindow()
        buildMenuBarItem()
        registerHotKey()
        showPanel()
    }

    // MARK: Window
    private func buildWindow() {
        let frame = NSRect(x: 0, y: 0, width: pillWidth, height: pillHeight)
        panel = GeminiPanel(contentRect: frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        // Rounded container with a translucent glass backing.
        container = NSView(frame: frame)
        container.wantsLayer = true
        container.layer?.cornerRadius = 20
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        let effect = NSVisualEffectView(frame: frame)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.alphaValue = 0.6
        effect.autoresizingMask = [.width, .height]
        container.addSubview(effect)

        buildWebView()
        webView.frame = NSRect(x: 0, y: 0, width: pillWidth, height: panelHeight - pillHeight)
        webView.autoresizingMask = [.width]
        webView.isHidden = true
        container.addSubview(webView)

        buildHeader() // pill header sits at the top, always visible
        container.addSubview(header)

        panel.contentView = container
        positionTopRight()
    }

    // The "Talk to Gemini" pill header: gradient spark logo + label + mic button.
    private func buildHeader() {
        header = ClickView(frame: NSRect(x: 0, y: pillHeight - pillHeight, width: pillWidth, height: pillHeight))
        header.autoresizingMask = [.width, .minYMargin] // pinned to top when window grows
        header.onClick = { [weak self] in self?.startTalking() }

        let logo = makeGeminiLogo(size: 26)
        logo.frame.origin = NSPoint(x: 20, y: (pillHeight - 26) / 2)
        header.addSubview(logo)

        promptLabel = NSTextField(labelWithString: "Talk to Gemini")
        promptLabel.font = .systemFont(ofSize: 17, weight: .medium)
        promptLabel.textColor = NSColor.white.withAlphaComponent(0.92)
        promptLabel.backgroundColor = .clear
        promptLabel.isBordered = false
        promptLabel.sizeToFit()
        promptLabel.frame.origin = NSPoint(x: 58, y: (pillHeight - promptLabel.frame.height) / 2)
        header.addSubview(promptLabel)

        let micSize: CGFloat = 40
        let micBg = NSView(frame: NSRect(x: pillWidth - micSize - 14, y: (pillHeight - micSize) / 2,
                                         width: micSize, height: micSize))
        micBg.wantsLayer = true
        micBg.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
        micBg.layer?.cornerRadius = micSize / 2
        micBg.autoresizingMask = [.minXMargin]

        let mic = NSButton(frame: micBg.bounds)
        mic.isBordered = false
        mic.bezelStyle = .regularSquare
        mic.title = ""
        let micCfg = NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        mic.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Talk")?
            .withSymbolConfiguration(micCfg)
        mic.contentTintColor = NSColor.black.withAlphaComponent(0.85)
        mic.imagePosition = .imageOnly
        mic.target = self
        mic.action = #selector(micTapped)
        micBg.addSubview(mic)
        header.addSubview(micBg)
    }

    // Gemini-style four-point spark with a blue→purple→pink gradient.
    private func makeGeminiLogo(size: CGFloat) -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        v.wantsLayer = true
        let grad = CAGradientLayer()
        grad.frame = v.bounds
        grad.colors = [
            NSColor(srgbRed: 0.26, green: 0.52, blue: 0.96, alpha: 1).cgColor,
            NSColor(srgbRed: 0.61, green: 0.36, blue: 0.95, alpha: 1).cgColor,
            NSColor(srgbRed: 0.93, green: 0.41, blue: 0.55, alpha: 1).cgColor]
        grad.startPoint = CGPoint(x: 0, y: 0)
        grad.endPoint = CGPoint(x: 1, y: 1)
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        if let symbol = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Gemini")?
            .withSymbolConfiguration(cfg),
           let cg = symbol.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let mask = CALayer()
            mask.frame = v.bounds
            mask.contents = cg
            mask.contentsGravity = .resizeAspect
            grad.mask = mask
        }
        v.layer?.addSublayer(grad)
        return v
    }

    private func buildWebView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.userContentController.addUserScript(WKUserScript(
            source: glassJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true))

        webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = safariUserAgent
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
    }

    private func positionTopRight() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(x: visible.maxX - panel.frame.width - 16,
                             y: visible.maxY - panel.frame.height - 16)
        panel.setFrameOrigin(origin)
    }

    // MARK: Expand / collapse
    @objc private func micTapped() { startTalking() }

    private func startTalking() {
        if !expanded { setExpanded(true) }
    }

    private func setExpanded(_ on: Bool) {
        expanded = on
        let top = panel.frame.maxY
        let newHeight = on ? panelHeight : pillHeight
        var f = panel.frame
        f.size.height = newHeight
        f.origin.y = top - newHeight // keep the top edge fixed; grow downward
        webView.isHidden = !on
        promptLabel.stringValue = on ? "Listening…" : "Talk to Gemini"
        panel.setFrame(f, display: true, animate: true)
        if on {
            webView.frame = NSRect(x: 0, y: 0, width: f.width, height: newHeight - pillHeight)
            webView.load(URLRequest(url: geminiURL)) // fresh chat + auto voice (see didFinish)
        }
    }

    // MARK: Menu bar
    private func buildMenuBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Gemini")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Gemini  (⌘⌥G)", action: #selector(menuToggle), keyEquivalent: "")
        menu.addItem(withTitle: "Talk", action: #selector(micTapped), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(menuQuit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        statusItem.menu = menu
    }

    @objc private func menuToggle() { togglePanel() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    // MARK: Visibility
    func togglePanel() {
        if panel.isVisible { panel.orderOut(nil) } else { showPanel() }
    }

    private func showPanel() {
        setExpanded(false) // always reset to the clean pill when shown
        positionTopRight()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: WebKit
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript(glassJS, completionHandler: nil)
        webView.evaluateJavaScript(voiceJS, completionHandler: nil)
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.grant)
    }

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
