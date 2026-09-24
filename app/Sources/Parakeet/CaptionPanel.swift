import AppKit
import NaturalLanguage
import SwiftUI
import Translation

/// One continuous run of text per burst of speech. New characters type in
/// a few at a time instead of popping in, so the eye can follow them.
@Observable
final class Captions {
    private(set) var transcript: [String] = []
    private(set) var locked = ""
    private(set) var partial = ""
    private(set) var revealed = 0
    private var lastUpdate = Date()
    @ObservationIgnored private var ticker: Timer?

    var isEmpty: Bool { locked.isEmpty && partial.isEmpty }
    private var target: Int { full.count }
    private var full: String { locked.isEmpty || partial.isEmpty ? locked + partial : locked + " " + partial }

    /// The typed-in part, split into locked (bright) and still-changing (dim).
    var visible: (locked: String, partial: String) {
        let shown = String(full.prefix(revealed))
        let split = min(shown.count, locked.count)
        return (String(shown.prefix(split)), String(shown.dropFirst(split)))
    }

    func lock(_ text: String) {
        // Streaming models can deliver a sentence's full stop after the pause.
        let attaches = text.first.map { ".,?!。、？！".contains($0) } ?? false
        if attaches, !transcript.isEmpty { transcript[transcript.count - 1] += text } else { transcript.append(text) }
        if transcript.count > 5000 { transcript.removeFirst() }  // hours of speech; the app runs for weeks
        // Japanese and Chinese don't put spaces between sentences (Korean does).
        let unspaced = locked.last?.unicodeScalars.first.map { (0x3000...0x9FFF).contains($0.value) } ?? false
        locked = locked.isEmpty ? text : locked + (attaches || unspaced ? "" : " ") + text
        // Only ~3 lines are on screen; text above them has scrolled out of view,
        // and laying it out again on every typed character is what costs CPU.
        if locked.count > 400 {
            let drop = locked.count - 300
            let cut = locked.index(locked.startIndex, offsetBy: drop)
            let wordStart = locked[cut...].firstIndex(of: " ").map { locked.index(after: $0) } ?? cut
            revealed = max(0, revealed - locked.distance(from: locked.startIndex, to: wordStart))
            locked = String(locked[wordStart...])
        }
        partial = ""
        changed()
    }

    func update(_ text: String) {
        partial = text
        changed()
    }

    /// Fade out once nobody has spoken for a while.
    func clearIfIdle(after seconds: TimeInterval) {
        if partial.isEmpty, !locked.isEmpty, Date().timeIntervalSince(lastUpdate) > seconds {
            locked = ""
            revealed = 0
        }
    }

    private func changed() {
        lastUpdate = .now
        revealed = min(revealed, target)
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            let remaining = target - revealed
            if remaining <= 0 { timer.invalidate(); ticker = nil; return }
            // Close the gap in ~150 ms whatever its size, but never jump a whole word at once.
            revealed += min(max(1, remaining / 5), 6)
        }
    }
}

/// Translates each locked sentence into its own caption stream, shown above
/// the original. Sentences already in the target language pass through.
@Observable
final class Translator {
    let output = Captions()
    var target: Locale.Language? {
        didSet { queue.removeAll(); output.clearIfIdle(after: 0) }
    }
    /// The language being heard. Translation needs it spelled out: left to
    /// detect it, the framework stops to ask the user.
    private var source: Locale.Language?
    @ObservationIgnored private var queue: [String] = []
    @ObservationIgnored private var wake: AsyncStream<Void>.Continuation?

    /// Drives `.translationTask`, which restarts `run` when either language changes.
    var configuration: TranslationSession.Configuration? { target.map { .init(source: source, target: $0) } }

    func translate(_ text: String) {
        guard target != nil else { return }
        queue.append(text)
        wake?.yield()
    }

    /// Works through the queue, one sentence at a time and in order. On the
    /// main actor: the captions it feeds are UI state, typed in by a main-thread timer.
    @MainActor func run(_ session: TranslationSession) async {
        let (signals, wake) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        self.wake = wake
        wake.yield()  // anything queued while the session was starting
        for await _ in signals {
            while let text = queue.first {
                let heard = language(of: text)
                if let heard, heard != target?.languageCode, heard != source?.languageCode {
                    source = Locale.Language(languageCode: heard)  // a session for the new language picks it up
                    return
                }
                // Already in the target language, or nothing to translate from yet: show it as heard.
                let translate = source != nil && (heard ?? source?.languageCode) != target?.languageCode
                let result = translate ? try? await session.translate(text) : nil
                if Task.isCancelled { return }  // keep it queued for the next session
                queue.removeFirst()
                output.lock(result?.targetText ?? text)
            }
        }
    }

    /// Short fragments are ambiguous, so this leans toward the language already
    /// being heard and only switches on a confident guess.
    private func language(of text: String) -> Locale.LanguageCode? {
        let recognizer = NLLanguageRecognizer()
        if let code = source?.languageCode?.identifier { recognizer.languageHints = [NLLanguage(rawValue: code): 0.8] }
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first, confidence >= 0.6 else { return nil }
        return Locale.Language(identifier: language.rawValue).languageCode
    }
}

/// A floating, draggable caption box that stays above
/// other windows, including full-screen apps.
final class CaptionPanel: NSPanel {
    init(captions: Captions, translator: Translator) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovableByWindowBackground = true
        hidesOnDeactivate = false

        let screen = NSScreen.main?.visibleFrame ?? .init(x: 0, y: 0, width: 1440, height: 900)
        let width = min(900, screen.width * 0.7)
        let height: CGFloat = 150
        setFrame(.init(x: screen.midX - width / 2, y: screen.minY + 60, width: width, height: height), display: false)
        setFrameAutosaveName("Captions")  // remember where it was dragged to

        let host = NSHostingView(rootView: CaptionView(captions: captions, translator: translator))
        host.sizingOptions = []
        contentView = host
    }

    override var canBecomeKey: Bool { false }
}

struct CaptionView: View {
    let captions: Captions
    var translator: Translator?

    private var translation: Captions? { translator?.target == nil ? nil : translator?.output }
    private var isEmpty: Bool { captions.isEmpty && translation?.isEmpty ?? true }

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if !isEmpty {
                // Translating: the translation large on top, the original live below.
                VStack(spacing: 6) {
                    if let translation {
                        CaptionText(captions: translation, size: 22, lines: 2, opacity: 1)
                        CaptionText(captions: captions, size: 15, lines: 2, opacity: 0.7)
                    } else {
                        CaptionText(captions: captions, size: 22, lines: 3, opacity: 1)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.black.opacity(0.72), in: .rect(cornerRadius: 14))
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.3), value: isEmpty)
        .translationTask(translator?.configuration) { session in await translator?.run(session) }
    }
}

/// Text that grows upward from the bottom edge; the frame clips it and fades
/// out the top line, so wrapping reads as a scroll.
private struct CaptionText: View {
    let captions: Captions
    let size: CGFloat
    let lines: CGFloat
    let opacity: Double
    @State private var lift: CGFloat = 0

    var body: some View {
        let visible = captions.visible
        (Text(visible.locked).foregroundStyle(.white.opacity(opacity))
         + Text(visible.partial).foregroundStyle(.white.opacity(opacity * 0.6)))
            .font(.system(size: size, weight: .semibold))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            // When a new line wraps in, start it one line lower and glide
            // up. Only the offset animates, so the text isn't re-laid out
            // every frame (animating the text itself cost ~90% CPU).
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { old, new in
                guard new > old else { return }
                lift += new - old
                withAnimation(.easeOut(duration: 0.25)) { lift = 0 }
            }
            .offset(y: lift)
            .frame(height: (size * 1.32).rounded() * lines, alignment: .bottom)
            .clipped()
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.3)], startPoint: .top, endPoint: .bottom))
    }
}
