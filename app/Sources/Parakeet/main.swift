import AppKit
import ServiceManagement
import Sparkle
import Translation

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
    private lazy var updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    private var engine: NemotronEngine?
    private var onboarding: Onboarding?   // set while the first-launch window is open
    private var onboardingWindow: OnboardingWindow?
    private var status = String(localized: "Loading speech model…")
    private var ready = false
    private var listening = false
    private var rehearse = false
    private var translationLanguages: [Locale.Language] = []

    /// What the menu and `Parakeet status` show; a revoked permission explains
    /// why nothing is being captioned.
    private var statusLine: String {
        listening && AudioPermission.status == .denied
            ? String(localized: "Audio access is off. Open System Settings and turn on Parakeet.") : status
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        // Sparkle's own schedule checks at most daily and skips the first launch;
        // also check on every launch, right after the updater starts (as Sparkle advises).
        if updater.updater.automaticallyChecksForUpdates { updater.updater.checkForUpdatesInBackground() }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()
        // `open Parakeet.app --args --rehearse-first-launch` replays what a new user sees.
        rehearse = CommandLine.arguments.contains("--rehearse-first-launch")
        if rehearse || !UserDefaults.standard.bool(forKey: "onboarded") { showOnboarding() }
        startEngine()
        captions.translateTo = UserDefaults.standard.string(forKey: "translateTo").map(Locale.Language.init(identifier:))
        Task {
            let languages = await LanguageAvailability().supportedLanguages
            translationLanguages = languages.sorted { name($0) < name($1) }
        }
        SystemAudioTap.onOutputDeviceChange { [weak self] in self?.restartTap() }
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

    private func showOnboarding() {
        let onboarding = Onboarding()
        let window = OnboardingWindow(onboarding)
        onboarding.onFinish = { [weak self] in self?.finishOnboarding() }
        onboarding.onRetry = { [weak self] in self?.startEngine() }
        self.onboarding = onboarding
        onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func finishOnboarding() {
        guard let onboarding else { return }
        self.onboarding = nil
        UserDefaults.standard.set(true, forKey: "onboarded")
        if onboarding.openAtLogin, SMAppService.mainApp.status != .enabled { try? SMAppService.mainApp.register() }
        onboardingWindow?.close()
        onboardingWindow = nil
        if ready { startListening() }
    }

    private func run(command: String) {
        switch command {
        case "captions on": if ready, !listening { startListening() }
        case "captions off": if listening { stopListening() }
        default: break
        }
        DistributedNotificationCenter.default().postNotificationName(Control.reply, object: statusLine, userInfo: nil, deliverImmediately: true)
    }

    // Rebuilt each time it opens so it always reflects current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: statusLine, action: nil, keyEquivalent: "")
        if engine == nil {
            menu.addItem(withTitle: String(localized: "Try Again"), action: #selector(startEngine), keyEquivalent: "")
        } else if listening, AudioPermission.status == .denied {
            menu.addItem(withTitle: String(localized: "Open System Settings"), action: #selector(openAudioSettings), keyEquivalent: "")
        }
        menu.addItem(.separator())
        let toggle = menu.addItem(withTitle: String(localized: "Captions"), action: #selector(toggleListening), keyEquivalent: "l")
        toggle.state = listening ? .on : .off
        toggle.isEnabled = ready
        let copy = menu.addItem(withTitle: String(localized: "Copy Transcript"), action: #selector(copyTranscript), keyEquivalent: "")
        copy.isEnabled = !captions.transcript.isEmpty
        let translate = NSMenu()
        for language in [nil] + translationLanguages.map(Optional.some) {
            let item = translate.addItem(withTitle: language.map(name) ?? String(localized: "Off"), action: #selector(translateTo(_:)), keyEquivalent: "")
            item.representedObject = language?.minimalIdentifier
            item.state = language?.minimalIdentifier == captions.translateTo?.minimalIdentifier ? .on : .off
        }
        menu.setSubmenu(translate, for: menu.addItem(withTitle: String(localized: "Translate To"), action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        let login = menu.addItem(withTitle: String(localized: "Open at Login"), action: #selector(toggleOpenAtLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let update = menu.addItem(withTitle: String(localized: "Check for Updates…"), action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        update.target = updater
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Quit Parakeet"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func handle(_ event: EngineEvent) {
        switch event {
        case .downloading(let fraction):
            status = String(localized: "Downloading speech model… \(Int(fraction * 100))%")
            onboarding?.model = .downloading(fraction)
        case .preparing:
            status = String(localized: "Preparing speech model…")
            onboarding?.model = .preparing
        case .ready:
            ready = true
            status = String(localized: "Ready")
            onboarding?.model = .ready
            // Captions start once the welcome window is done with.
            if onboarding == nil { startListening() }
        case .partial(let text):
            captions.update(text)
        case .final(let text):
            captions.lock(text)
        case .exited(let reason):
            let reason = reason.isEmpty ? String(localized: "unknown error") : reason
            ready = false
            engine = nil
            stopListening()
            status = String(localized: "Speech model stopped: \(reason)")
            onboarding?.model = .failed(reason)
        }
        updateIcon()
    }

    /// Loads the speech model; runs again from "Try Again" after a failure.
    @objc private func startEngine() {
        guard engine == nil else { return }
        status = String(localized: "Loading speech model…")
        onboarding?.model = .waiting
        engine = NemotronEngine(rehearseFirstLaunch: rehearse) { [weak self] event in self?.handle(event) }
        updateIcon()
    }

    @objc private func toggleListening() {
        listening ? stopListening() : startListening()
    }

    private func startListening() {
        do {
            try tap.start { [weak self] pcm in self?.engine?.send(pcm) }
            listening = true
            status = String(localized: "Listening to system audio")
            panel.orderFrontRegardless()
        } catch {
            tap.stop()
            status = String(localized: "Can't capture audio: \(error.localizedDescription)")
        }
        updateIcon()
    }

    /// Rebuilds the tap on the new output device, which keeps captions going
    /// when headphones are plugged in or disconnected.
    private func restartTap() {
        guard listening else { return }
        stopListening()
        startListening()
    }

    private func stopListening() {
        tap.stop()
        listening = false
        panel.orderOut(nil)
        if ready { status = String(localized: "Off") }
        updateIcon()
    }

    @objc private func translateTo(_ item: NSMenuItem) {
        let identifier = item.representedObject as? String
        UserDefaults.standard.set(identifier, forKey: "translateTo")
        captions.translateTo = identifier.map(Locale.Language.init(identifier:))
    }

    private func name(_ language: Locale.Language) -> String {
        Locale.current.localizedString(forIdentifier: language.minimalIdentifier) ?? language.minimalIdentifier
    }

    @objc private func openAudioSettings() { AudioPermission.openSettings() }

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

extension AppDelegate: SPUStandardUserDriverDelegate {
    // A menu bar app is never the active app, so Sparkle would leave an update it
    // found waiting behind other windows. Bring it to the front instead.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        DispatchQueue.main.async { [self] in
            NSApp.activate()
            updater.checkForUpdates(nil)
        }
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
        case .downloading, .preparing: break
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
