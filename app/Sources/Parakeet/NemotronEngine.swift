import AVFoundation
import FluidAudio
import Foundation

/// Cache-aware streaming ASR via FluidAudio: NVIDIA Nemotron Speech Streaming
/// 0.6B (English), or Nemotron 3.5 ASR (multilingual) when a language is given.
/// Each 560 ms chunk is encoded once and emitted tokens are never revised, so
/// there is no re-transcription loop at all.
final class NemotronEngine: Transcriber {
    private static let chunk = 8_960     // 560 ms
    private static let pauseChunks = 2   // chunks without new tokens that end an utterance

    /// The calls the loop needs, so both FluidAudio managers can drive it.
    private struct Stream {
        var process: ([Float]) async throws -> Void
        var transcript: () async -> String
        var reset: () async -> Void
    }

    private let lock = NSLock()
    private var incoming: [Float] = []
    private var task: Task<Void, Never>?

    /// `language` nil runs the English model; "auto", "ko-KR", "ja-JP"… run the multilingual one.
    init(language: String? = nil, onEvent: @escaping (EngineEvent) -> Void) {
        let emit = { (event: EngineEvent) in DispatchQueue.main.async { onEvent(event) } }
        task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let stream = try await language == nil ? Self.english() : Self.multilingual(language!)
                emit(.ready)
                try await self?.run(stream, emit: emit)
            } catch is CancellationError {
            } catch {
                emit(.exited(error.localizedDescription))
            }
        }
    }

    private static func english() async throws -> Stream {
        let asr = StreamingNemotronAsrManager(requestedChunkSize: .ms560)
        try await asr.loadModels()
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        return Stream(
            process: { samples in
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
                buffer.frameLength = AVAudioFrameCount(samples.count)
                samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
                _ = try await asr.process(audioBuffer: buffer)
            },
            transcript: { await asr.getPartialTranscript() },
            reset: { await asr.reset() })
    }

    private static func multilingual(_ language: String) async throws -> Stream {
        let dir = try await StreamingNemotronMultilingualAsrManager.downloadVariant(languageCode: language, chunkMs: 560)
        let asr = StreamingNemotronMultilingualAsrManager()
        try await asr.loadModels(from: dir)
        await asr.setLanguage(language == "auto" ? nil : language)
        return Stream(
            process: { _ = try await asr.process(samples: $0) },
            transcript: { await asr.getPartialTranscript() },
            reset: { await asr.reset() })
    }

    func send(_ pcm: Data) {
        let samples = pcm.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        lock.withLock { incoming.append(contentsOf: samples.map { $0.isFinite ? min(1, max(-1, $0)) : 0 }) }
    }

    func stop() { task?.cancel() }

    private func run(_ asr: Stream, emit: @escaping (EngineEvent) -> Void) async throws {
        let chunk = Self.chunk
        var pending: [Float] = []
        var committed = 0   // characters of the running transcript already locked in
        var shown = ""
        var quietChunks = 0

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

            try await asr.process(samples)

            // Tokens are never revised, so everything past `committed` is simply new.
            let all = await asr.transcript()
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
}
