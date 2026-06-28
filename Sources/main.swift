import Cocoa
import WebKit
import Carbon.HIToolbox
import Speech
import AVFoundation

// MARK: - Configuration
// Global hotkey: ⌘⌥G -> show the pill and start listening immediately (Siri-style).
private let geminiURL = URL(string: "https://gemini.google.com/app")!
private let hotKeyKeyCode = UInt32(kVK_ANSI_G)
private let hotKeyModifiers = UInt32(cmdKey | optionKey)

private let pillWidth: CGFloat = 480
private let pillHeight: CGFloat = 64
private let maxPillHeight: CGFloat = 340     // grows vertically to show long transcripts
private let loginHeight: CGFloat = 620        // only used for one-time Google sign-in
private let silenceSeconds: TimeInterval = 1.3 // auto-finish after this much silence

private let safariUserAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

// Injected JS: clean Gemini's UI (only matters during the sign-in view).
private let glassJS = """
(function () {
  function apply() {
    document.documentElement.style.setProperty('filter', 'grayscale(1) contrast(1.05)', 'important');
    var nodes = document.querySelectorAll('body *');
    for (var i = 0; i < nodes.length; i++)
      nodes[i].style.setProperty('box-shadow', 'none', 'important');
  }
  apply();
  var p; new MutationObserver(function(){clearTimeout(p);p=setTimeout(apply,300);})
    .observe(document.documentElement,{childList:true,subtree:true});
})();
"""

// Injected JS: feed text into Gemini and post the streamed answer back to the app.
private let askJS = """
(function () {
  function editor() { return document.querySelector('rich-textarea .ql-editor, .ql-editor, [contenteditable=true], textarea'); }
  function send() {
    return document.querySelector('button[aria-label*="Send" i], button[aria-label*="Submit" i], button.send-button');
  }
  window.__geminiAsk = function (text) {
    var ed = editor();
    if (!ed) { window.webkit.messageHandlers.gemini.postMessage({ type: 'error', text: 'no-input' }); return; }
    ed.focus();
    if (ed.tagName === 'TEXTAREA') {
      ed.value = text; ed.dispatchEvent(new Event('input', { bubbles: true }));
    } else {
      ed.innerHTML = '<p></p>';
      try { document.execCommand('insertText', false, text); }
      catch (e) { ed.textContent = text; }
      ed.dispatchEvent(new InputEvent('input', { bubbles: true }));
    }
    setTimeout(function () {
      var s = send();
      if (s && !s.disabled) s.click();
      else ed.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true }));
      observe();
    }, 250);
  };
  function observe() {
    var last = '', stable, started = Date.now();
    var obs = new MutationObserver(function () {
      var r = document.querySelectorAll('message-content, .model-response-text, .markdown, [class*=response-content]');
      if (!r.length) return;
      var txt = (r[r.length - 1].innerText || '').trim();
      if (txt && txt !== last) {
        last = txt;
        clearTimeout(stable);
        stable = setTimeout(function () {
          obs.disconnect();
          window.webkit.messageHandlers.gemini.postMessage({ type: 'answer', text: last });
        }, 1100);
      }
    });
    obs.observe(document.body, { childList: true, subtree: true, characterData: true });
    setTimeout(function () { try { obs.disconnect(); } catch (e) {}
      window.webkit.messageHandlers.gemini.postMessage({ type: 'answer', text: last || '(no response)' }); }, 35000);
  }
})();
"""

// MARK: - Helpers
final class GeminiPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class ClickView: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
}

// MARK: - App Delegate
final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate,
                         WKScriptMessageHandler, AVSpeechSynthesizerDelegate {
    private var panel: GeminiPanel!
    private var container: NSView!
    private var header: ClickView!
    private var webView: WKWebView!
    private var bodyLabel: NSTextField!
    private var logo: NSView!
    private var micBg: NSView!
    private var hotKeyRef: EventHotKeyRef?
    private var statusItem: NSStatusItem!

    // Speech
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private let synth = AVSpeechSynthesizer()
    private var listening = false
    private var loginMode = false
    private var webReady = false

    enum State { case idle, listening, thinking, answer }
    private var state: State = .idle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        synth.delegate = self
        buildWindow()
        buildMenuBarItem()
        registerHotKey()
        requestPermissions()
        render("Talk to Gemini")
        positionTopRight()
        panel.orderFront(nil)
    }

    // MARK: Permissions
    private func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { _ in }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    // MARK: Window / pill
    private func buildWindow() {
        let frame = NSRect(x: 0, y: 0, width: pillWidth, height: pillHeight)
        panel = GeminiPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

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
        effect.alphaValue = 0.65
        effect.autoresizingMask = [.width, .height]
        container.addSubview(effect)

        // Hidden Gemini engine: lives full-size but clipped beneath the pill so WebKit
        // keeps it active. Only revealed for one-time sign-in.
        buildWebView()
        // Parked fully below the visible pill (clipped out) so only the glass shows;
        // moved on-screen only for one-time sign-in.
        webView.frame = NSRect(x: 0, y: -loginHeight, width: pillWidth, height: loginHeight)
        webView.autoresizingMask = [.width]
        container.addSubview(webView)

        buildHeader()
        container.addSubview(header)
        panel.contentView = container
    }

    private func buildHeader() {
        header = ClickView(frame: NSRect(x: 0, y: 0, width: pillWidth, height: pillHeight))
        header.autoresizingMask = [.width, .height]
        header.onClick = { [weak self] in self?.toggleListening() }

        logo = makeGeminiLogo(size: 26)
        header.addSubview(logo)

        bodyLabel = NSTextField(labelWithString: "Talk to Gemini")
        bodyLabel.font = .systemFont(ofSize: 16, weight: .medium)
        bodyLabel.textColor = NSColor.white.withAlphaComponent(0.92)
        bodyLabel.backgroundColor = .clear
        bodyLabel.isBordered = false
        bodyLabel.lineBreakMode = .byWordWrapping
        bodyLabel.maximumNumberOfLines = 0
        bodyLabel.cell?.wraps = true
        bodyLabel.cell?.isScrollable = false
        header.addSubview(bodyLabel)

        let micSize: CGFloat = 40
        micBg = NSView(frame: NSRect(x: pillWidth - micSize - 14, y: 12, width: micSize, height: micSize))
        micBg.wantsLayer = true
        micBg.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
        micBg.layer?.cornerRadius = micSize / 2
        micBg.autoresizingMask = [.minXMargin, .minYMargin]
        let mic = NSButton(frame: micBg.bounds)
        mic.isBordered = false
        mic.bezelStyle = .regularSquare
        mic.title = ""
        mic.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Talk")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
        mic.contentTintColor = NSColor.black.withAlphaComponent(0.85)
        mic.imagePosition = .imageOnly
        mic.target = self
        mic.action = #selector(micTapped)
        micBg.addSubview(mic)
        header.addSubview(micBg)
    }

    private func makeGeminiLogo(size: CGFloat) -> NSView {
        let v = NSView(frame: NSRect(x: 20, y: (pillHeight - size) / 2, width: size, height: size))
        v.wantsLayer = true
        v.autoresizingMask = [.minYMargin]
        let grad = CAGradientLayer()
        grad.frame = CGRect(x: 0, y: 0, width: size, height: size)
        grad.colors = [
            NSColor(srgbRed: 0.26, green: 0.52, blue: 0.96, alpha: 1).cgColor,
            NSColor(srgbRed: 0.61, green: 0.36, blue: 0.95, alpha: 1).cgColor,
            NSColor(srgbRed: 0.93, green: 0.41, blue: 0.55, alpha: 1).cgColor]
        grad.startPoint = CGPoint(x: 0, y: 0); grad.endPoint = CGPoint(x: 1, y: 1)
        if let symbol = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Gemini")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)),
           let cg = symbol.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let mask = CALayer(); mask.frame = grad.bounds; mask.contents = cg
            mask.contentsGravity = .resizeAspect; grad.mask = mask
        }
        v.layer?.addSublayer(grad)
        return v
    }

    private func buildWebView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.userContentController.add(self, name: "gemini")
        config.userContentController.addUserScript(WKUserScript(
            source: askJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = safariUserAgent
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.load(URLRequest(url: geminiURL))
    }

    private func positionTopRight() {
        guard let screen = NSScreen.main else { return }
        let v = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: v.maxX - panel.frame.width - 16, y: v.maxY - panel.frame.height - 16))
    }

    // MARK: Rendering (pill grows vertically, never becomes the web tab)
    private func render(_ text: String) {
        bodyLabel.stringValue = text
        let leftPad: CGFloat = 52, rightPad: CGFloat = 64, topPad: CGFloat = 19
        let textWidth = pillWidth - leftPad - rightPad
        let font = bodyLabel.font ?? .systemFont(ofSize: 16)
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        let textHeight = max(22, ceil(bounds.height))
        let newHeight = min(maxPillHeight, max(pillHeight, textHeight + topPad * 2))

        let top = panel.frame.maxY
        var f = panel.frame
        f.size.height = newHeight
        f.origin.y = top - newHeight
        panel.setFrame(f, display: true)

        let h = container.bounds.height
        logo.frame.origin = NSPoint(x: 20, y: h - 26 - topPad)
        micBg.frame.origin = NSPoint(x: pillWidth - 40 - 14, y: h - 40 - 12)
        bodyLabel.frame = NSRect(x: leftPad, y: h - topPad - textHeight, width: textWidth, height: textHeight)
    }

    // MARK: Listening
    @objc private func micTapped() { toggleListening() }

    private func toggleListening() {
        if listening { finishAndSubmit() } else { startListening() }
    }

    private func startListening() {
        guard !loginMode else { return }
        synth.stopSpeaking(at: .immediate)
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              let recognizer = recognizer, recognizer.isAvailable else {
            render("Allow Microphone + Speech Recognition in System Settings, then press ⌘⌥G")
            return
        }
        stopAudio() // clean slate
        state = .listening
        listening = true
        setMic(active: true)
        render("Listening…")

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        audioEngine.prepare()
        do { try audioEngine.start() } catch {
            render("Mic error: \(error.localizedDescription)"); listening = false; setMic(active: false); return
        }

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self = self else { return }
            if let result = result {
                let text = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    if self.listening, !text.isEmpty { self.render(text); self.resetSilenceTimer() }
                }
            }
            if error != nil { DispatchQueue.main.async { if self.listening { self.finishAndSubmit() } } }
        }
        resetSilenceTimer(initial: true)
    }

    private func resetSilenceTimer(initial: Bool = false) {
        silenceTimer?.invalidate()
        let delay = initial ? 6.0 : silenceSeconds // give 6s to start speaking, then 1.3s of silence
        silenceTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.finishAndSubmit()
        }
    }

    private func finishAndSubmit() {
        guard listening else { return }
        listening = false
        silenceTimer?.invalidate()
        setMic(active: false)
        let text = bodyLabel.stringValue
        stopAudio()
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty || query == "Listening…" { state = .idle; render("Talk to Gemini"); return }
        state = .thinking
        render(query + "\n\n…")
        askGemini(query)
    }

    private func stopAudio() {
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil; task = nil
    }

    private func setMic(active: Bool) {
        micBg.layer?.backgroundColor = active
            ? NSColor.systemRed.cgColor
            : NSColor.white.withAlphaComponent(0.92).cgColor
    }

    // MARK: Ask Gemini (hidden web session)
    private func askGemini(_ text: String) {
        let json = String(data: try! JSONSerialization.data(withJSONObject: [text]), encoding: .utf8)!
        let arg = String(json.dropFirst().dropLast()) // JSON-escaped string literal
        webView.evaluateJavaScript("window.__geminiAsk && window.__geminiAsk(\(arg))", completionHandler: nil)
    }

    // Response (or error) from the injected JS.
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any] else { return }
        let type = dict["type"] as? String ?? ""
        let text = dict["text"] as? String ?? ""
        if type == "error" {
            render("Couldn't reach Gemini. Use the menu → \"Sign in to Google\" first.")
            return
        }
        state = .answer
        render(text)
        speak(text)
    }

    // MARK: TTS
    private func speak(_ text: String) {
        synth.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "en-US")
        u.rate = 0.52
        synth.speak(u)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        // Conversation mode: listen again for a follow-up once the answer is spoken.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, self.panel.isVisible, !self.loginMode else { return }
            self.startListening()
        }
    }

    // MARK: Sign-in (one-time): reveal the web view
    @objc private func showLogin() {
        loginMode = true
        finishAndSubmitSilently()
        let top = panel.frame.maxY
        var f = panel.frame; f.size.height = loginHeight; f.origin.y = top - loginHeight
        panel.setFrame(f, display: true)
        webView.frame = NSRect(x: 0, y: 0, width: pillWidth, height: loginHeight)
        webView.isHidden = false
        header.isHidden = true
        webView.reload()
        webView.evaluateJavaScript(glassJS, completionHandler: nil)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func finishLogin() {
        loginMode = false
        header.isHidden = false
        webView.frame = NSRect(x: 0, y: -loginHeight, width: pillWidth, height: loginHeight)
        render("Talk to Gemini")
        positionTopRight()
    }

    private func finishAndSubmitSilently() {
        listening = false; silenceTimer?.invalidate(); stopAudio(); setMic(active: false)
    }

    // MARK: Menu bar
    private func buildMenuBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Gemini")
            b.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Talk  (⌘⌥G)", action: #selector(menuShow), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Sign in to Google…", action: #selector(showLogin), keyEquivalent: "")
        menu.addItem(withTitle: "Done signing in", action: #selector(finishLogin), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(menuQuit), keyEquivalent: "q")
        for i in menu.items { i.target = self }
        statusItem.menu = menu
    }

    @objc private func menuShow() { showAndListen() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    // MARK: Visibility / hotkey
    func togglePanel() {
        // ⌘⌥G: start listening immediately; press again to stop + dismiss.
        if loginMode { return }
        if listening || synth.isSpeaking { hidePanel() } else { showAndListen() }
    }

    private func showAndListen() {
        guard !loginMode else { return }
        render("Talk to Gemini")
        positionTopRight()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        startListening()
    }

    private func hidePanel() {
        finishAndSubmitSilently()
        synth.stopSpeaking(at: .immediate)
        state = .idle
        panel.orderOut(nil)
    }

    // MARK: WebKit
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webReady = true
        if loginMode { webView.evaluateJavaScript(glassJS, completionHandler: nil) }
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

    // MARK: Global hotkey
    private func registerHotKey() {
        var et = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { (_, _, userData) -> OSStatus in
            guard let userData = userData else { return noErr }
            let d = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { d.togglePanel() }
            return noErr
        }, 1, &et, Unmanaged.passUnretained(self).toOpaque(), nil)
        let id = EventHotKeyID(signature: OSType(0x47454D49), id: 1)
        RegisterEventHotKey(hotKeyKeyCode, hotKeyModifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

// MARK: - Entry point
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
