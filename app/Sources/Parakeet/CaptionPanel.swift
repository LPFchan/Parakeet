import AppKit
import SwiftUI

@Observable
final class Captions {
    private(set) var transcript: [String] = []
    private(set) var shown = ""
    var partial = ""
    private var lastUpdate = Date()

    func lock(_ text: String) {
        transcript.append(text)
        shown = trimmed(shown.isEmpty ? text : shown + " " + text)
        partial = ""
        lastUpdate = .now
    }

    func update(_ text: String) {
        partial = text
        shown = trimmed(shown)
        lastUpdate = .now
    }

    /// Fade out once nobody has spoken for a while.
    func clearIfIdle(after seconds: TimeInterval) {
        if partial.isEmpty, !shown.isEmpty, Date().timeIntervalSince(lastUpdate) > seconds { shown = "" }
    }

    /// Keep roughly three lines on screen, dropping whole words from the front.
    private func trimmed(_ text: String, budget: Int = 180) -> String {
        var words = text.split(separator: " ")
        while !words.isEmpty, words.joined(separator: " ").count + partial.count > budget { words.removeFirst() }
        return words.joined(separator: " ")
    }
}

/// A floating, draggable caption box that stays above
/// other windows, including full-screen apps.
final class CaptionPanel: NSPanel {
    init(captions: Captions) {
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

        let host = NSHostingView(rootView: CaptionView(captions: captions))
        host.sizingOptions = []
        contentView = host
    }

    override var canBecomeKey: Bool { false }
}

private struct CaptionView: View {
    let captions: Captions

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if !captions.shown.isEmpty || !captions.partial.isEmpty {
                (Text(captions.shown + (captions.shown.isEmpty ? "" : " ")).foregroundStyle(.white)
                 + Text(captions.partial).foregroundStyle(.white.opacity(0.6)))
                    .font(.system(size: 22, weight: .semibold))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(.black.opacity(0.72), in: .rect(cornerRadius: 14))
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: captions.shown.isEmpty && captions.partial.isEmpty)
    }
}
