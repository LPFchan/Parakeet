import AppKit

/// `Parakeet <command>` talks to the running app over distributed notifications.
enum Control {
    static let command = Notification.Name("plus.lost.parakeet.command")
    static let reply = Notification.Name("plus.lost.parakeet.status")
    static let usage = "usage: Parakeet status | captions on|off | model \(Model.allCases.map(\.rawValue).joined(separator: "|"))"
}

enum Model: String, CaseIterable {
    case redux, ane, nemotron, multilingual, sensevoice

    var title: String {
        switch self {
        case .redux: "Parakeet redux (GPU)"
        case .ane: "Parakeet v2 (Neural Engine)"
        case .nemotron: "Nemotron (English, streaming)"
        case .multilingual: "Nemotron 3.5 (multilingual, streaming)"
        case .sensevoice: "SenseVoice (Korean, Japanese, Chinese, English)"
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let captions = Captions()
    private lazy var panel = CaptionPanel(captions: captions)
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let tap = SystemAudioTap()
    private var engine: Transcriber?
    private var generation = 0   // ignores late events from an engine that was switched away from
    private var model = Model(rawValue: UserDefaults.standard.string(forKey: "model") ?? "") ?? .multilingual
    private var status = ""
    private var ready = false
    private var listening = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()
        startEngine()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [captions] _ in
            captions.clearIfIdle(after: 6)
        }
        DistributedNotificationCenter.default().addObserver(forName: Control.command, object: nil, queue: .main) { [weak self] note in
            self?.run(command: (note.object as? String)?.split(separator: " ").map(String.init) ?? [])
        }
    }

    private func run(command: [String]) {
        switch (command.first, command.dropFirst().first) {
        case ("captions", "on"): if ready, !listening { startListening() }
        case ("captions", "off"): if listening { stopListening() }
        case ("model", let name?): if let picked = Model(rawValue: name) { switchModel(to: picked) }
        default: break
        }
        DistributedNotificationCenter.default().postNotificationName(Control.reply, object: status, userInfo: nil, deliverImmediately: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        tap.stop()
        engine?.stop()
    }

    // Rebuilt each time it opens so it always reflects current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: status, action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        let toggle = menu.addItem(withTitle: "Captions", action: #selector(toggleListening), keyEquivalent: "l")
        toggle.state = listening ? .on : .off
        toggle.isEnabled = ready
        let models = NSMenu()
        for m in Model.allCases {
            let item = models.addItem(withTitle: m.title, action: #selector(selectModel), keyEquivalent: "")
            item.representedObject = m.rawValue
            item.state = m == model ? .on : .off
        }
        menu.addItem(withTitle: "Model", action: nil, keyEquivalent: "").submenu = models
        let copy = menu.addItem(withTitle: "Copy Transcript", action: #selector(copyTranscript), keyEquivalent: "")
        copy.isEnabled = !captions.transcript.isEmpty
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Parakeet", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        if let picked = (sender.representedObject as? String).flatMap(Model.init) { switchModel(to: picked) }
    }

    private func switchModel(to picked: Model) {
        guard picked != model else { return }
        model = picked
        UserDefaults.standard.set(model.rawValue, forKey: "model")
        stopListening()
        engine?.stop()
        engine = nil
        ready = false
        startEngine()
    }

    private func startEngine() {
        let root = URL(fileURLWithPath: Bundle.main.infoDictionary?["ParakeetRoot"] as? String ?? "")
        generation += 1
        let current = generation
        let onEvent: (EngineEvent) -> Void = { [weak self] event in
            if self?.generation == current { self?.handle(event) }
        }
        status = "Loading \(model.title)…"
        updateIcon()
        do {
            switch model {
            case .redux: engine = try Engine(root: root, onEvent: onEvent)
            case .ane: engine = AneEngine(onEvent: onEvent)
            case .nemotron: engine = NemotronEngine(onEvent: onEvent)
            case .multilingual: engine = NemotronEngine(language: "auto", onEvent: onEvent)
            case .sensevoice: engine = SenseVoiceEngine(onEvent: onEvent)
            }
        } catch {
            status = "Engine failed: \(error.localizedDescription)"
        }
    }

    private func handle(_ event: EngineEvent) {
        switch event {
        case .ready:
            ready = true
            status = model.title
            startListening()
        case .partial(let text):
            captions.update(text)
        case .final(let text):
            captions.lock(text)
        case .exited(let reason):
            ready = false
            engine = nil
            stopListening()
            status = "Engine stopped: \(reason.isEmpty ? "unknown error" : reason)"
        }
        updateIcon()
    }

    @objc private func toggleListening() {
        listening ? stopListening() : startListening()
    }

    private func startListening() {
        do {
            try tap.start { [weak self] pcm in self?.engine?.send(pcm) }
            listening = true
            status = "Listening · \(model.title)"
            panel.orderFrontRegardless()
        } catch {
            tap.stop()
            status = "Can't capture audio: \(error.localizedDescription)"
        }
        updateIcon()
    }

    private func stopListening() {
        tap.stop()
        listening = false
        panel.orderOut(nil)
        if ready { status = "Off · \(model.title)" }
        updateIcon()
    }

    @objc private func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(captions.transcript.joined(separator: "\n"), forType: .string)
    }

    private func updateIcon() {
        let name = listening ? "captions.bubble.fill" : "captions.bubble"
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Parakeet")
    }
}

let args = Array(CommandLine.arguments.dropFirst())
if let first = args.first, ["status", "captions", "model"].contains(first) {
    let valid = first == "status" || (first == "captions" && ["on", "off"].contains(args.dropFirst().first ?? ""))
        || (first == "model" && Model(rawValue: args.dropFirst().first ?? "") != nil)
    guard valid else { print(Control.usage); exit(2) }
    DistributedNotificationCenter.default().addObserver(forName: Control.reply, object: nil, queue: .main) { note in
        print(note.object as? String ?? "")
        exit(0)
    }
    DistributedNotificationCenter.default().postNotificationName(Control.command, object: args.joined(separator: " "), userInfo: nil, deliverImmediately: true)
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { print("Parakeet isn't running"); exit(1) }
    RunLoop.main.run()
}

// `Parakeet --bench file.wav [nemotron|sensevoice|<language>]` plays a 16 kHz float32 WAV into an engine
// in real time and reports the CPU time it took.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--bench" {
    let data = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
    let pcm = data[(data.range(of: Data("data".utf8))!.upperBound + 4)...]
    let started = Date()
    var engine: Transcriber?
    let onEvent: (EngineEvent) -> Void = { event in
        let t = String(format: "%5.2f", Date().timeIntervalSince(started))
        switch event {
        case .ready:
            print(t, "ready")
            DispatchQueue.global().async {
                var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
                let cpu0 = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
                let t0 = Date()
                let step = 1600 * 4
                for i in stride(from: pcm.startIndex, to: pcm.endIndex, by: step) {
                    engine?.send(pcm[i..<min(i + step, pcm.endIndex)])
                    Thread.sleep(forTimeInterval: 0.1)
                }
                // The tap keeps streaming silence after speech stops.
                for _ in 0..<30 { engine?.send(Data(count: step)); Thread.sleep(forTimeInterval: 0.1) }
                getrusage(RUSAGE_SELF, &usage)
                let cpu1 = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
                print(String(format: "cpu %.0f%% of one core (user %.1fs, sys %.1fs total)", (cpu1 - cpu0) / Date().timeIntervalSince(t0) * 100,
                             Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6, Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6))
                exit(0)
            }
        case .final(let text): print(t, "final:", text)
        case .partial: break
        case .exited(let reason): print("exited:", reason); exit(1)
        }
    }
    switch CommandLine.arguments.dropFirst(3).first {
    case nil: engine = AneEngine(onEvent: onEvent)
    case "nemotron": engine = NemotronEngine(onEvent: onEvent)
    case "sensevoice": engine = SenseVoiceEngine(onEvent: onEvent)
    case let language?: engine = NemotronEngine(language: language, onEvent: onEvent)
    }
    RunLoop.main.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
