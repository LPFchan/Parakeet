import FluidAudio
import Foundation

/// SenseVoice Small via FluidAudio: Korean, Japanese, Chinese, Cantonese and
/// English, with no language lock. It gives no word timings, so Silero VAD
/// decides where an utterance ends; until then the utterance is re-transcribed
/// every 128 ms.
final class SenseVoiceEngine: Transcriber {
    private static let tick = 2_048                    // 128 ms between re-transcriptions
    private static let maxLatin = 16_000 * 6           // nonstop speech this long is locked in at a gap…
    private static let maxCJK = 16_000 * 13            // …but Korean/Japanese/Chinese get worse on short clips
    private static let preroll = 8_192                 // samples kept from before speech starts

    private let lock = NSLock()
    private var incoming: [Float] = []
    private var task: Task<Void, Never>?

    init(onEvent: @escaping (EngineEvent) -> Void) {
        let emit = { (event: EngineEvent) in DispatchQueue.main.async { onEvent(event) } }
        task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                // Text-norm 14 ("withitn") adds punctuation and writes numbers as digits.
                let asr = SenseVoiceManager(models: try await SenseVoiceModels.downloadAndLoad(), textNorm: 14)
                let vad = try await VadManager()
                emit(.ready)
                try await self?.run(asr: asr, vad: vad, emit: emit)
            } catch is CancellationError {
            } catch {
                emit(.exited(error.localizedDescription))
            }
        }
    }

    func send(_ pcm: Data) {
        let samples = pcm.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        lock.withLock { incoming.append(contentsOf: samples.map { $0.isFinite ? min(1, max(-1, $0)) : 0 }) }
    }

    func stop() { task?.cancel() }

    private func run(asr: SenseVoiceManager, vad: VadManager, emit: @escaping (EngineEvent) -> Void) async throws {
        let segmentation = VadSegmentationConfig(minSilenceDuration: 0.5)
        var state = await vad.makeStreamState()
        var pending: [Float] = []
        var audio: [Float] = []   // the current utterance
        var unheard: [Float] = []  // audio the VAD hasn't seen yet (it takes 256 ms blocks)
        var shown = ""

        while !Task.isCancelled {
            pending += lock.withLock { () -> [Float] in
                defer { incoming.removeAll(keepingCapacity: true) }
                return incoming
            }
            guard pending.count >= Self.tick else {
                try await Task.sleep(for: .milliseconds(20))
                continue
            }
            let samples = Array(pending.prefix(Self.tick))
            pending.removeFirst(Self.tick)

            // The tap streams digital silence when nothing plays; don't wake the ANE for it.
            if !state.triggered, !samples.contains(where: { abs($0) > 1e-4 }) {
                audio = []; unheard = []
                continue
            }
            audio += samples
            unheard += samples

            var ended = false
            if unheard.count >= VadManager.chunkSize {
                let result = try await vad.processStreamingChunk(unheard, state: state, config: segmentation)
                state = result.state
                ended = result.event?.isEnd == true
                unheard = []
            }

            if ended {
                let text = try await asr.transcribe(audio: audio)
                if !text.isEmpty { emit(.final(text)) } else if !shown.isEmpty { emit(.partial("")) }
                audio = []; shown = ""
                continue
            }
            guard state.triggered else {
                // No speech yet; keep a little audio so the first word isn't clipped.
                audio = Array(audio.suffix(Self.preroll))
                continue
            }

            let cjk = shown.unicodeScalars.contains { $0.value >= 0x3000 }
            if audio.count >= (cjk ? Self.maxCJK : Self.maxLatin) {
                let cut = Self.quietestPoint(in: audio)
                let text = try await asr.transcribe(audio: Array(audio[..<cut]))
                if !text.isEmpty { emit(.final(text)) }
                audio.removeFirst(cut); shown = ""
            }

            let text = try await asr.transcribe(audio: audio)
            if text != shown { shown = text; emit(.partial(text)) }
        }
    }

    /// The quietest 50 ms between 2 s in and the last half second, likely a
    /// gap between words, so a forced cut doesn't split one.
    private static func quietestPoint(in audio: [Float]) -> Int {
        let window = 800, hop = 160
        var best = (energy: Float.infinity, at: audio.count - 8_000)
        for start in stride(from: 32_000, to: audio.count - 8_000 - window, by: hop) {
            let energy = audio[start..<start + window].reduce(0) { $0 + $1 * $1 }
            if energy < best.energy { best = (energy, start + window / 2) }
        }
        return best.at
    }
}
