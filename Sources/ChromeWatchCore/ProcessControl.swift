import Darwin
import Foundation

/// What a "Quit" row action targets: one exact process, pinned by its start time.
public struct ProcessIdentity: Sendable, Equatable {
    public let pid: Int32
    public let startSeconds: Int
    public let startMicroseconds: Int32
    public let executablePath: String

    public init(_ instance: ChromeInstance) {
        pid = instance.main.pid
        startSeconds = instance.main.startSeconds
        startMicroseconds = instance.main.startMicroseconds
        executablePath = instance.main.path
    }
}

public enum TerminationOutcome: Sendable, Equatable {
    case exitedAfterTerm(seconds: Double)
    case killed
    /// The PID is gone, or now belongs to some other process. Nothing was signalled.
    case notRunning
    case failed(String)
}

/// Signals exactly one PID. Never by name or pattern.
public enum ProcessControl {
    /// Still the same process (same PID and start time, not a zombie)?
    public static func isAlive(_ identity: ProcessIdentity) -> Bool {
        guard let info = SystemProcessReader.bsdInfo(pid: identity.pid) else { return false }
        return !info.isZombie
            && info.startSeconds == identity.startSeconds
            && info.startMicroseconds == identity.startMicroseconds
    }

    /// Same process as shown in the row, and still a browser main process.
    public static func isSameBrowserMain(_ identity: ProcessIdentity) -> Bool {
        guard isAlive(identity),
              let path = SystemProcessReader.executablePath(pid: identity.pid),
              path == identity.executablePath,
              let args = SystemProcessReader().arguments(pid: identity.pid)
        else { return false }
        let record = ProcessRecord(pid: identity.pid, ppid: 0, executablePath: path, arguments: args)
        return ChromeDetector.isMainProcess(record)
    }

    /// SIGTERM, wait up to `grace` seconds, then SIGKILL if the same process is still there.
    public static func terminate(_ identity: ProcessIdentity, grace: TimeInterval = 5) async -> TerminationOutcome {
        guard isSameBrowserMain(identity) else { return .notRunning }
        guard kill(identity.pid, SIGTERM) == 0 else {
            return errno == ESRCH ? .notRunning : .failed(String(cString: strerror(errno)))
        }
        let started = Date()
        while Date().timeIntervalSince(started) < grace {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if !isAlive(identity) {
                return .exitedAfterTerm(seconds: Date().timeIntervalSince(started))
            }
        }
        // Re-check identity right before the hard kill: the PID must not have been reused.
        guard isSameBrowserMain(identity) else { return .exitedAfterTerm(seconds: grace) }
        guard kill(identity.pid, SIGKILL) == 0 else {
            return errno == ESRCH ? .exitedAfterTerm(seconds: grace) : .failed(String(cString: strerror(errno)))
        }
        for _ in 0..<10 where isAlive(identity) {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return isAlive(identity) ? .failed("still running after SIGKILL") : .killed
    }
}
