import FluidAudio
import Foundation

enum EngineEvent { case downloading(Double), preparing, ready, partial(String), final(String), exited(String) }

/// NVIDIA Nemotron 3.5 ASR (cache-aware streaming, ~40 languages detected
/// automatically) running on the Neural Engine via FluidAudio. Each 560 ms
/// chunk is encoded once and emitted tokens are never revised, so there is no
/// re-transcription loop at all.
final class NemotronEngine {
    private static let chunk = 8_960     // 560 ms
    private static let pauseChunks = 2   // chunks without new tokens that end an utterance

    private let lock = NSLock()
    private var incoming: [Float] = []
    private var task: Task<Void, Never>?

    /// `rehearseFirstLaunch` plays a fake model download and the first-time
    /// preparation pause before loading the real (cached) model.
    init(rehearseFirstLaunch: Bool = false, onEvent: @escaping (EngineEvent) -> Void) {
        let emit = { (event: EngineEvent) in DispatchQueue.main.async { onEvent(event) } }
        task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                if rehearseFirstLaunch {
                    for percent in 0...100 {
                        emit(.downloading(Double(percent) / 100))
                        try await Task.sleep(for: .milliseconds(100))
                    }
                }
                let dir = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
                    languageCode: "auto", chunkMs: 560,
                    progressHandler: { emit(.downloading($0.fractionCompleted)) })
                emit(.preparing)
                if rehearseFirstLaunch { try await Task.sleep(for: .seconds(10)) }  // really ~1 min, first time only
                let asr = StreamingNemotronMultilingualAsrManager()
                try await asr.loadModels(from: dir)
                emit(.ready)
                try await self?.run(asr, emit: emit)
            } catch is CancellationError {
            } catch {
                emit(.exited(error.localizedDescription))
            }
        }
    }

    func send(_ pcm: Data) {
        let samples = pcm.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        // Loud mixes and resampling overshoot past full scale.
        lock.withLock { incoming.append(contentsOf: samples.map { $0.isFinite ? min(1, max(-1, $0)) : 0 }) }
    }

    func stop() { task?.cancel() }

    private func run(_ asr: StreamingNemotronMultilingualAsrManager, emit: @escaping (EngineEvent) -> Void) async throws {
        let chunk = Self.chunk
        var pending: [Float] = []
        var committed = 0   // characters of the running transcript already locked in
        var shown = ""
        var quietChunks = 0
        var waited = 0      // chunks the unlocked text has been waiting

        while !Task.isCancelled {
            pending += lock.withLock { () -> [Float] in
                defer { incoming.removeAll(keepingCapacity: true) }
                return incoming
            }
            guard pending.count >= chunk else {
                try await Task.sleep(for: .milliseconds(20))
                continue
            }
            let samples = Array(pending.prefix(chunk))
            pending.removeFirst(chunk)

            // Long digital silence with everything locked in: start a fresh
            // stream (bounds the running transcript) and skip the model.
            let silent = !samples.contains(where: { abs($0) > 1e-4 })
            if silent, shown.isEmpty, quietChunks >= 10 {
                if committed > 0 { await asr.reset(); committed = 0 }
                continue
            }

            _ = try await asr.process(samples: samples)

            // Tokens are never revised, so everything past `committed` is simply new.
            let all = await asr.getPartialTranscript()
            // For the same reason, every finished word is final. Lock at the end
            // of a sentence rather than waiting for a pause, which continuous
            // speech may never have; if one runs long, at a comma (~3 s) or
            // any word (~5 s), so translation isn't left waiting.
            let tail = all.dropFirst(committed)
            waited = tail.allSatisfy(\.isWhitespace) ? 0 : waited + 1
            if let end = Self.lastBreak(in: tail, at: ".?!。？！")
                ?? (waited >= 5 ? Self.lastBreak(in: tail, at: ",;:、，") : nil)
                ?? (waited >= 9 ? Self.lastBreak(in: tail, at: " ") : nil) {
                emit(.final(tail[..<end].trimmingCharacters(in: .whitespaces)))
                committed += tail.distance(from: tail.startIndex, to: end)
                waited = 0
            }
            let now = String(all.dropFirst(committed)).trimmingCharacters(in: .whitespaces)
            if now != shown {
                shown = now
                quietChunks = 0
                emit(.partial(shown))
            } else {
                quietChunks += 1
                if !shown.isEmpty, quietChunks >= Self.pauseChunks {
                    emit(.final(shown))
                    committed = all.count
                    shown = ""
                }
            }
        }
    }

    /// Just past the last of `marks` that ends a finished word: followed by a
    /// space ("fast. The", not "3.5"), a sentence end right after a letter,
    /// or any CJK mark. A space counts once the next word has begun.
    private static func lastBreak(in text: Substring, at marks: String) -> String.Index? {
        for mark in text.indices.reversed() where marks.contains(text[mark]) {
            let after = text.index(after: mark)
            let next = after < text.endIndex ? text[after] : nil
            let c = text[mark]
            let ends = c == " " ? next != nil
                : !c.isASCII || next == " " || (next == nil && ".?!".contains(c) && text[..<mark].last?.isLetter == true)
            if ends { return after }
        }
        return nil
    }
}
