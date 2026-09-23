import AppKit

/// The "system audio recording" permission. macOS has no public API to check
/// or request it, so this uses the TCC functions other audio apps use too
/// (after FineTune's AudioRecordingPermission).
enum AudioPermission {
    enum Status { case unknown, allowed, denied }

    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static var status: Status {
        typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
        guard let sym = dlsym(tcc, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(sym, to: Preflight.self)(service, nil) {
        case 0: return .allowed
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Shows the system prompt (only the first time; afterwards it just reports).
    static func request(_ done: @escaping (Bool) -> Void) {
        typealias Request = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void
        guard let sym = dlsym(tcc, "TCCAccessRequest") else { return done(false) }
        unsafeBitCast(sym, to: Request.self)(service, nil) { granted in DispatchQueue.main.async { done(granted) } }
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
    }
}
