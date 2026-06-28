import Cocoa
import Carbon.HIToolbox
import Speech
import AVFoundation

// MARK: - Configuration
// Global hotkey: ⌘⌥G -> show the pill and start listening immediately (Siri-style).
private let hotKeyKeyCode = UInt32(kVK_ANSI_G)
private let hotKeyModifiers = UInt32(cmdKey | optionKey)
private let geminiModel = "gemini-2.5-flash"

private let pillWidth: CGFloat = 480
private let pillHeight: CGFloat = 64
private let maxPillHeight: CGFloat = 360
private let silenceSeconds: TimeInterval = 1.3   // auto-finish after this much silence

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
final class AppDelegate: NSObject, NSApplicationDelegate, AVSpeechSynthesizerDelegate {
    private var panel: GeminiPanel!
    private var container: NSView!
    private var header: ClickView!
    private var bodyLabel: NSTextField!
    private var logo: NSView!
    private var micBg: NSView!
    private var hotKeyRef: EventHotKeyRef?
    private var statusItem: NSStatusItem!

    // Speech in
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var listening = false

    // Speech out
    private let synth = AVSpeechSynthesizer()

    // Gemini API
    private var apiTask: URLSessionDataTask?
    private var history: [[String: Any]] = []   // multi-turn conversation context

    enum State { case idle, listening, thinking, answer }
    private var state: State = .idle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        synth.delegate = self
        buildWindow()
        buildMenuBarItem()
        registerHotKey()
        requestPermissions()
        // Stay hidden & silent at rest; the menu-bar ✦ shows it's running. ⌘⌥G summons it.
    }

    private func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { _ in }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    // MARK: API key storage (~/Library/Application Support/GeminiWindow/api_key.txt)
    private var keyFileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GeminiWindow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("api_key.txt")
    }
    private var apiKey: String? {
        let k = (try? String(contentsOf: keyFileURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (k?.isEmpty == false) ? k : nil
    }
    private func saveKey(_ key: String) {
        try? key.trimmingCharacters(in: .whitespacesAndNewlines).write(to: keyFileURL, atomically: true, encoding: .utf8)
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

    private func positionTopRight() {
        guard let screen = NSScreen.main else { return }
        let v = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: v.maxX - panel.frame.width - 16, y: v.maxY - panel.frame.height - 16))
    }

    // MARK: Rendering (grows vertically; never a big window)
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
    private func toggleListening() { listening ? finishAndSubmit() : startListening() }

    private func startListening() {
        synth.stopSpeaking(at: .immediate)
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              let recognizer = recognizer, recognizer.isAvailable else {
            render("Allow Microphone + Speech Recognition in System Settings, then ⌘⌥G")
            return
        }
        if apiKey == nil { render("Set your free API key:  ✦ menu → Set API Key…"); return }
        stopAudio()
        state = .listening; listening = true
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
        let delay = initial ? 6.0 : silenceSeconds
        silenceTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.finishAndSubmit()
        }
    }

    private func finishAndSubmit() {
        guard listening else { return }
        listening = false
        silenceTimer?.invalidate()
        setMic(active: false)
        let query = bodyLabel.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        stopAudio()
        if query.isEmpty || query == "Listening…" { state = .idle; render("Talk to Gemini"); return }
        state = .thinking
        render(query + "\n\n…")
        askGemini(query)
    }

    private func stopAudio() {
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio(); task?.cancel()
        request = nil; task = nil
        silenceTimer?.invalidate()
    }

    private func setMic(active: Bool) {
        micBg.layer?.backgroundColor = active ? NSColor.systemRed.cgColor
                                              : NSColor.white.withAlphaComponent(0.92).cgColor
    }

    // MARK: Gemini API
    private func askGemini(_ query: String) {
        guard let key = apiKey else { render("Set your free API key:  ✦ menu → Set API Key…"); return }
        history.append(["role": "user", "parts": [["text": query]]])
        let urlStr = "https://generativelanguage.googleapis.com/v1beta/models/\(geminiModel):generateContent?key=\(key)"
        guard let url = URL(string: urlStr) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["contents": history])

        apiTask?.cancel()
        apiTask = URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            guard let self = self else { return }
            DispatchQueue.main.async {
                guard self.panel.isVisible else { return } // silent if dismissed
                if let err = err { self.render("Network error: \(err.localizedDescription)"); return }
                guard let data = data else { self.render("No response from Gemini"); return }
                if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    self.render("Gemini API \(http.statusCode). Check your key.\n\(body.prefix(160))")
                    return
                }
                guard let answer = self.parseAnswer(data) else { self.render("Couldn't read Gemini's reply."); return }
                self.history.append(["role": "model", "parts": [["text": answer]]])
                self.state = .answer
                self.render(answer)
                self.speak(answer)
            }
        }
        apiTask?.resume()
    }

    private func parseAnswer(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = obj["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { return nil }
        let text = parts.compactMap { $0["text"] as? String }.joined()
        return text.isEmpty ? nil : text
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
        // Conversation mode: listen for a follow-up, but only if still on screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, self.panel.isVisible else { return }
            self.startListening()
        }
    }

    // MARK: Visibility / hotkey
    func togglePanel() {
        if panel.isVisible { hidePanel() } else { showAndListen() }
    }

    private func showAndListen() {
        history.removeAll()                 // fresh conversation each summon
        render("Talk to Gemini")
        positionTopRight()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        startListening()
    }

    private func hidePanel() {
        listening = false
        stopAudio()
        apiTask?.cancel(); apiTask = nil
        synth.stopSpeaking(at: .immediate)
        setMic(active: false)
        state = .idle
        panel.orderOut(nil)
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
        menu.addItem(withTitle: "Set API Key…", action: #selector(promptForKey), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(menuQuit), keyEquivalent: "q")
        for i in menu.items { i.target = self }
        statusItem.menu = menu
    }

    @objc private func menuShow() { showAndListen() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    @objc private func promptForKey() {
        let alert = NSAlert()
        alert.messageText = "Gemini API Key"
        alert.informativeText = "Paste your free key from aistudio.google.com/apikey"
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        tf.stringValue = apiKey ?? ""
        alert.accessoryView = tf
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { saveKey(tf.stringValue) }
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
