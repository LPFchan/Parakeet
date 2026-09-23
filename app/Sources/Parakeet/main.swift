import AppKit
import ServiceManagement
import Sparkle

/// `Parakeet <command>` talks to the running app over distributed notifications.
enum Control {
    static let command = Notification.Name("plus.lost.parakeet.command")
    static let reply = Notification.Name("plus.lost.parakeet.status")
    static let usage = "usage: Parakeet status | captions on|off"
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let captions = Captions()
    private lazy var panel = CaptionPanel(captions: captions)
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let tap = SystemAudioTap()
    private let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    private var engine: NemotronEngine?
    private var status = "Loading speech model…"
    private var ready = false
    private var listening = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()
        // `open Parakeet.app --args --rehearse-first-launch` replays what a new user sees.
        let rehearse = CommandLine.arguments.contains("--rehearse-first-launch")
        engine = NemotronEngine(rehearseFirstLaunch: rehearse) { [weak self] event in self?.handle(event) }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [captions] _ in
            captions.clearIfIdle(after: 6)
        }
        DistributedNotificationCenter.default().addObserver(forName: Control.command, object: nil, queue: .main) { [weak self] note in
            self?.run(command: note.object as? String ?? "")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        tap.stop()
        engine?.stop()
    }

    private func run(command: String) {
        switch command {
        case "captions on": if ready, !listening { startListening() }
        case "captions off": if listening { stopListening() }
        default: break
        }
        DistributedNotificationCenter.default().postNotificationName(Control.reply, object: status, userInfo: nil, deliverImmediately: true)
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
        let login = menu.addItem(withTitle: "Open at Login", action: #selector(toggleOpenAtLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let update = menu.addItem(withTitle: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        update.target = updater
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Parakeet", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func handle(_ event: EngineEvent) {
        switch event {
        case .downloading(let fraction):
            // First launch only: the box is the one thing on screen that shows progress.
            status = "Downloading speech model… \(Int(fraction * 100))%"
            captions.update(status)
            panel.orderFrontRegardless()
        case .ready:
            ready = true
            captions.update("")
            startListening()
        case .partial(let text):
            captions.update(text)
        case .final(let text):
            captions.lock(text)
        case .exited(let reason):
            ready = false
            engine = nil
            stopListening()
            status = "Speech model stopped: \(reason.isEmpty ? "unknown error" : reason)"
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

    @objc private func toggleOpenAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            // Usually means the user switched it off in System Settings; send them there.
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    private func updateIcon() {
        let name = listening ? "captions.bubble.fill" : "captions.bubble"
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Parakeet")
    }
}

let args = Array(CommandLine.arguments.dropFirst())

if let first = args.first, ["status", "captions"].contains(first) {
    let command = args.joined(separator: " ")
    guard ["status", "captions on", "captions off"].contains(command) else { print(Control.usage); exit(2) }
    DistributedNotificationCenter.default().addObserver(forName: Control.reply, object: nil, queue: .main) { note in
        print(note.object as? String ?? "")
        exit(0)
    }
    DistributedNotificationCenter.default().postNotificationName(Control.command, object: command, userInfo: nil, deliverImmediately: true)
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { print("Parakeet isn't running"); exit(1) }
    RunLoop.main.run()
}

// `Parakeet --bench file.wav` plays a 16 kHz float32 WAV into the engine in
// real time and prints what it heard and the CPU time it took.
if args.count == 2, args[0] == "--bench" {
    let data = try! Data(contentsOf: URL(fileURLWithPath: args[1]))
    let pcm = data[(data.range(of: Data("data".utf8))!.upperBound + 4)...]
    let started = Date()
    var engine: NemotronEngine?
    engine = NemotronEngine { event in
        let t = String(format: "%5.2f", Date().timeIntervalSince(started))
        switch event {
        case .downloading: break
        case .ready:
            print(t, "ready")
            DispatchQueue.global().async {
                func cpuTime() -> Double {
                    var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
                    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
                }
                let cpu0 = cpuTime(), t0 = Date()
                let step = 1600 * 4
                for i in stride(from: pcm.startIndex, to: pcm.endIndex, by: step) {
                    engine?.send(pcm[i..<min(i + step, pcm.endIndex)])
                    Thread.sleep(forTimeInterval: 0.1)
                }
                // The tap keeps streaming silence after speech stops.
                for _ in 0..<30 { engine?.send(Data(count: step)); Thread.sleep(forTimeInterval: 0.1) }
                print(String(format: "cpu %.0f%% of one core", (cpuTime() - cpu0) / Date().timeIntervalSince(t0) * 100))
                exit(0)
            }
        case .final(let text): print(t, "final:", text)
        case .partial(let text): print(t, "  ~", text)
        case .exited(let reason): print("exited:", reason); exit(1)
        }
    }
    RunLoop.main.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
