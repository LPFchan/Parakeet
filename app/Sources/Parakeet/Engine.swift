import Foundation

enum EngineEvent { case ready, partial(String), final(String), exited(String) }

protocol Transcriber: AnyObject {
    func send(_ pcm: Data)
    func stop()
}

/// Runs engine/engine.py in the repo's .venv and talks JSON lines with it.
final class Engine: Transcriber {
    typealias Event = EngineEvent

    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private var pending = Data()
    static let log = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Parakeet/engine.log")

    init(root: URL, onEvent: @escaping (Event) -> Void) throws {
        process.executableURL = root.appending(path: ".venv/bin/python")
        process.arguments = [root.appending(path: "engine/engine.py").path]
        process.standardInput = stdin
        process.standardOutput = stdout
        try FileManager.default.createDirectory(at: Self.log.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: Self.log.path, contents: nil)
        process.standardError = try FileHandle(forWritingTo: Self.log)
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            pending.append(handle.availableData)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[..<newline]
                pending.removeSubrange(...newline)
                guard let msg = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                let event: Event? =
                    msg["ready"] != nil ? .ready :
                    (msg["final"] as? String).map { .final($0) } ??
                    (msg["partial"] as? String).map { .partial($0) }
                if let event { DispatchQueue.main.async { onEvent(event) } }
            }
        }
        process.terminationHandler = { _ in
            let log = (try? String(contentsOf: Self.log, encoding: .utf8)) ?? ""
            let tail = log.split(separator: "\n").last.map(String.init) ?? ""
            DispatchQueue.main.async { onEvent(.exited(tail)) }
        }
        try process.run()
    }

    func send(_ pcm: Data) {
        guard process.isRunning else { return }
        try? stdin.fileHandleForWriting.write(contentsOf: pcm)
    }

    func stop() {
        try? stdin.fileHandleForWriting.close()
        process.terminate()
    }
}
