import Foundation

public enum Format {
    /// "6d 22h", "3h 12m", "4m", "<1m".
    public static func uptime(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let (days, hours, mins) = (minutes / 1440, (minutes / 60) % 24, minutes % 60)
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(mins)m" }
        if mins > 0 { return "\(mins)m" }
        return "<1m"
    }

    /// Binary units, like Activity Monitor: "1.23 GB", "456.7 MB".
    public static func memory(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1024 { return String(format: "%.2f GB", mb / 1024) }
        return String(format: "%.1f MB", mb)
    }

    /// Quote an argument the way a shell would need it.
    public static func shellQuote(_ arg: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./=:,@%+"))
        if !arg.isEmpty, arg.unicodeScalars.allSatisfy(safe.contains) { return arg }
        return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The text placed on the clipboard by "Copy details".
    public static func details(_ instance: ChromeInstance, now: Date = Date()) -> String {
        let started = ISO8601DateFormatter.string(from: instance.main.startDate, timeZone: .current, formatOptions: [.withInternetDateTime])
        var lines = [
            "\(instance.kind.rawValue) — \(instance.flavor.rawValue)",
            "PID: \(instance.pid)",
            "Launched by: \(instance.launchedBy)",
            "Started: \(started) (up \(uptime(instance.uptime(now: now))))",
            "RAM: \(memory(instance.memoryFootprint)) across \(instance.processCount) processes",
            "Executable: \(instance.main.path)",
            "Command line: \(instance.main.arguments.map(shellQuote).joined(separator: " "))",
        ]
        if !instance.automationSignals.isEmpty {
            lines.append("Automation signals: \(instance.automationSignals.joined(separator: ", "))")
        }
        lines.append("Launcher chain:")
        if instance.launcherChain.isEmpty {
            lines.append("  pid 1  launchd")
        } else {
            lines += instance.launcherChain.map { "  " + $0.chainDescription }
            if let top = instance.launcherChain.last, top.ppid == 1 { lines.append("  pid 1  launchd") }
        }
        return lines.joined(separator: "\n")
    }
}
