import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let captions = Captions()
    private lazy var panel = CaptionPanel(captions: captions)
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let tap = SystemAudioTap()
    private var engine: Transcriber?
    private var status = "Loading model…"
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
        let copy = menu.addItem(withTitle: "Copy Transcript", action: #selector(copyTranscript), keyEquivalent: "")
        copy.isEnabled = !captions.transcript.isEmpty
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Parakeet", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func startEngine() {
        let info = Bundle.main.infoDictionary ?? [:]
        let root = URL(fileURLWithPath: info["ParakeetRoot"] as? String ?? "")
        let onEvent: (EngineEvent) -> Void = { [weak self] event in self?.handle(event) }
        do {
            switch info["ParakeetEngine"] as? String {
            case "ane": engine = AneEngine(onEvent: onEvent)
            case "nemotron": engine = NemotronEngine(onEvent: onEvent)
            default: engine = try Engine(root: root, onEvent: onEvent)
            }
        } catch {
            status = "Engine failed: \(error.localizedDescription)"
        }
    }

    private func handle(_ event: EngineEvent) {
        switch event {
        case .ready:
            ready = true
            status = "Ready"
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
            status = "Listening to system audio"
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
        if ready { status = "Off" }
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

// `Parakeet --bench file.wav [nemotron]` plays a 16 kHz float32 WAV into an engine
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
    engine = CommandLine.arguments.last == "nemotron" ? NemotronEngine(onEvent: onEvent) : AneEngine(onEvent: onEvent)
    RunLoop.main.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
