import Foundation

/// Runs engine/engine.py in the repo's .venv and talks JSON lines with it.
final class Engine {
    enum Event { case ready, partial(String), final(String), exited(String) }

    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private var pending = Data()
    private var errorTail = ""

    init(root: URL, onEvent: @escaping (Event) -> Void) throws {
        process.executableURL = root.appending(path: ".venv/bin/python")
        process.arguments = [root.appending(path: "engine/engine.py").path]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self, let text = String(data: handle.availableData, encoding: .utf8) else { return }
            errorTail = String((errorTail + text).suffix(2000))
        }
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
        process.terminationHandler = { [weak self] _ in
            let tail = self?.errorTail.split(separator: "\n").last.map(String.init) ?? ""
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
