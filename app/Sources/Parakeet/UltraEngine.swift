import AVFoundation
import FluidAudio
import Foundation

/// Parakeet Ultra (AsrModelVersion.ultra) through FluidAudio's
/// SlidingWindowAsrManager: overlapping 15 s windows of the offline TDT
/// model instead of Nemotron's cache-aware streaming. Confirmed window text
/// arrives whole, so this shows window text so far as a partial and locks
/// each confirmed window as one final/fragment. Used by the "--engine ultra"
/// debug build.
final class UltraEngine: Engine {
    private var task: Task<Void, Never>?
    private let feed = Feed()

    /// rehearsesFirstLaunch plays a fake model download and the first-time
    /// preparation pause before loading the real (cached) model.
    init(rehearseFirstLaunch: Bool = false, onEvent: @escaping (EngineEvent) -> Void) {
        let emit = { (event: EngineEvent) in DispatchQueue.main.async { onEvent(event) } }
        task = Task.detached(priority: .userInitiated) { [feed] in
            do {
                if rehearseFirstLaunch {
                    for percent in 0...100 {
                        emit(.downloading(Double(percent) / 100))
                        try await Task.sleep(for: .milliseconds(100))
                    }
                }
                let models = try await AsrModels.downloadAndLoad(
                    version: .ultra,
                    progressHandler: { emit(.downloading($0.fractionCompleted)) })
                emit(.preparing)
                if rehearseFirstLaunch { try await Task.sleep(for: .seconds(10)) }
                // 2+6+2 s windows: chunks confirm twice as often as the 11 s
                // default while each decode still sees 10 s of audio.
                let asr = SlidingWindowAsrManager(config: SlidingWindowAsrConfig(chunkSeconds: 6.0))
                try await asr.loadModels(models)
                try await asr.startStreaming(source: .system)
                feed.asr = asr
                emit(.ready)

                var shown = ""
                for await update in await asr.transcriptionUpdates {
                    if Task.isCancelled { return }
                    if update.isConfirmed {
                        let text = update.text.trimmingCharacters(in: .whitespaces)
                        shown = ""
                        guard !text.isEmpty else { continue }
                        emit(Self.locked(text))
                    } else {
                        // A window's text is only its own few seconds; the running
                        // unconfirmed tail reads as one continuous partial.
                        let tail = await asr.volatileTranscript.trimmingCharacters(in: .whitespaces)
                        if tail != shown {
                            shown = tail
                            emit(.partial(tail))
                        }
                    }
                }
            } catch is CancellationError {
            } catch {
                emit(.exited(error.localizedDescription))
            }
        }
    }

    func send(_ pcm: Data) {
        let count = pcm.count / MemoryLayout<Float>.size
        guard count > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        pcm.withUnsafeBytes { raw in
            buffer.floatChannelData?[0].update(from: raw.bindMemory(to: Float.self).baseAddress!, count: count)
        }
        feed.send(buffer)
    }

    func stop() { task?.cancel() }

    /// Flushes audio still buffered by the sliding window (up to a full chunk,
    /// 11 s) so the bench hears the end of the clip.
    func finish() async {
        guard let asr = feed.asr else { return }
        _ = try? await asr.finish()
    }

    private static func locked(_ text: String) -> EngineEvent {
        text.last.map { ".?!。？！".contains($0) } == true ? .final(text) : .fragment(text)
    }

    /// Hands audio buffers to the sliding-window manager from any thread;
    /// the manager is an actor, so sends hop onto it.
    private final class Feed: @unchecked Sendable {
        private let lock = NSLock()
        private var _asr: SlidingWindowAsrManager?
        var asr: SlidingWindowAsrManager? {
            get { lock.withLock { _asr } }
            set { lock.withLock { _asr = newValue } }
        }
        func send(_ buffer: AVAudioPCMBuffer) {
            guard let asr else { return }  // dropped before the model is ready
            Task { await asr.streamAudio(buffer) }
        }
    }
}
