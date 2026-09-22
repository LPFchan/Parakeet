import CoreML
import FluidAudio
import Foundation

/// Same loop as engine/engine.py, but in-process with FluidAudio's CoreML
/// Parakeet (English-only v2), whose encoder runs on the Neural Engine.
final class AneEngine: Transcriber {
    private static let sr = 16_000.0
    private static let tick = Double(ProcessInfo.processInfo.environment["PK_TICK"] ?? "") ?? 0.2          // seconds of new audio between re-transcriptions
    private static let pause = 0.8         // silence after the last word that locks everything in
    private static let settle = 1.0        // a sentence must end this long before "now" to lock in
    private static let maxBuffer = 14.0    // stay inside the model's single 15 s window
    private static let forceKeep = 3.0     // on a forced cut, keep this much audio unlocked
    private static let idleFlush = 1.0     // wall-clock seconds without audio before locking in
    private static let margin = 0.08       // keep a little audio before a cut (one encoder frame)

    private let lock = NSLock()
    private var incoming: [Float] = []
    private var lastAudio = Date()
    private var task: Task<Void, Never>?

    init(onEvent: @escaping (EngineEvent) -> Void) {
        let emit = { (event: EngineEvent) in DispatchQueue.main.async { onEvent(event) } }
        task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let env = ProcessInfo.processInfo.environment
                let units: [String: MLComputeUnits] = ["cpu": .cpuOnly, "ane": .cpuAndNeuralEngine, "gpu": .cpuAndGPU, "all": .all]
                let config = MLModelConfiguration()
                config.computeUnits = units[env["PK_REST"] ?? "ane"]!
                let models = try await AsrModels.downloadAndLoad(configuration: config, version: .v2, encoderComputeUnits: units[env["PK_ENC"] ?? "ane"]!)
                let asr = AsrManager(config: .default)
                try await asr.loadModels(models)
                emit(.ready)
                try await self?.run(asr: asr, emit: emit)
            } catch is CancellationError {
            } catch {
                emit(.exited(error.localizedDescription))
            }
        }
    }

    func send(_ pcm: Data) {
        let samples = pcm.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        lock.withLock {
            // Loud mixes and resampling overshoot past full scale.
            incoming.append(contentsOf: samples.map { $0.isFinite ? min(1, max(-1, $0)) : 0 })
            lastAudio = .now
        }
    }

    func stop() { task?.cancel() }

    private struct Word { var text: String; var start: Double; var end: Double }

    private func run(asr: AsrManager, emit: @escaping (EngineEvent) -> Void) async throws {
        let sr = Self.sr
        var audio: [Float] = []
        var sinceTick = 0
        var lastPartial = ""

        func cut(_ seconds: Double, margin: Double = Self.margin) {
            audio.removeFirst(min(audio.count, max(0, Int((seconds - margin) * sr))))
        }

        while !Task.isCancelled {
            let (chunk, last) = lock.withLock { () -> ([Float], Date) in
                defer { incoming.removeAll(keepingCapacity: true) }
                return (incoming, lastAudio)
            }
            audio += chunk
            sinceTick += chunk.count

            let idle = Date().timeIntervalSince(last) > Self.idleFlush
            if Double(sinceTick) < Self.tick * sr && !(idle && !audio.isEmpty) {
                try await Task.sleep(for: .milliseconds(20))
                continue
            }
            sinceTick = 0

            let dur = Double(audio.count) / sr
            var sentences: [[Word]] = []
            // The tap streams digital silence when nothing plays; don't wake the ANE for it.
            if audio.count >= Int(0.3 * sr), audio.contains(where: { abs($0) > 1e-4 }) {
                var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
                let result = try await asr.transcribe(audio, decoderState: &state)
                sentences = Self.sentences(from: result.tokenTimings ?? [])
            }

            guard let lastWord = sentences.last?.last else {
                // Nothing said yet. Keep enough tail that a sentence which is just
                // starting survives until the model can recognise its first word.
                audio = idle ? [] : Array(audio.suffix(Int(2 * sr)))
                if !lastPartial.isEmpty { emit(.partial("")); lastPartial = "" }
                continue
            }

            if idle || dur - lastWord.end >= Self.pause {
                emit(.final(Self.text(sentences)))
                cut(lastWord.end, margin: 0)
            } else if sentences.count > 1, let prev = sentences[sentences.count - 2].last, dur - prev.end >= Self.settle {
                emit(.final(Self.text(sentences.dropLast())))
                cut(sentences.last![0].start)
            } else if dur > Self.maxBuffer {
                let keep = sentences.flatMap { $0 }.filter { $0.end <= dur - Self.forceKeep }
                if let lastKept = keep.last {
                    emit(.final(keep.map(\.text).joined(separator: " ")))
                    cut(lastKept.end)
                }
            } else {
                let text = Self.text(sentences)
                if text != lastPartial { emit(.partial(text)); lastPartial = text }
                continue
            }
            lastPartial = ""
        }
    }

    /// SentencePiece tokens: a leading space starts a new word; . ? ! end a sentence.
    private static func sentences(from tokens: [TokenTiming]) -> [[Word]] {
        var sentences: [[Word]] = []
        var current: [Word] = []
        for token in tokens {
            if token.token.hasPrefix(" ") || current.isEmpty {
                if let last = current.last, let end = last.text.last, ".?!".contains(end) {
                    sentences.append(current)
                    current = []
                }
                current.append(Word(text: token.token.trimmingCharacters(in: .whitespaces), start: token.startTime, end: token.endTime))
            } else {
                current[current.count - 1].text += token.token
                current[current.count - 1].end = token.endTime
            }
        }
        if !current.isEmpty { sentences.append(current) }
        return sentences.filter { !$0.allSatisfy { $0.text.isEmpty } }
    }

    private static func text<S: Sequence>(_ sentences: S) -> String where S.Element == [Word] {
        sentences.map { $0.map(\.text).filter { !$0.isEmpty }.joined(separator: " ") }.joined(separator: " ")
    }
}
