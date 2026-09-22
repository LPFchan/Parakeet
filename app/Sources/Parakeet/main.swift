import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let captions = Captions()
    private lazy var panel = CaptionPanel(captions: captions)
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let tap = SystemAudioTap()
    private var engine: Engine?
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
        let toggle = menu.addItem(withTitle: listening ? "Stop Listening" : "Start Listening", action: #selector(toggleListening), keyEquivalent: "l")
        toggle.isEnabled = ready
        let show = menu.addItem(withTitle: "Show Captions", action: #selector(toggleCaptions), keyEquivalent: "c")
        show.state = panel.isVisible ? .on : .off
        let copy = menu.addItem(withTitle: "Copy Transcript", action: #selector(copyTranscript), keyEquivalent: "")
        copy.isEnabled = !captions.transcript.isEmpty
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Parakeet", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func startEngine() {
        let root = URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "ParakeetRoot") as? String ?? "")
        do {
            engine = try Engine(root: root) { [weak self] event in self?.handle(event) }
        } catch {
            status = "Engine failed: \(error.localizedDescription)"
        }
    }

    private func handle(_ event: Engine.Event) {
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
        if ready { status = "Paused" }
        updateIcon()
    }

    @objc private func toggleCaptions() {
        panel.isVisible ? panel.orderOut(nil) : panel.orderFrontRegardless()
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
