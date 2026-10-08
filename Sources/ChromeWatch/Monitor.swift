import AppKit
import ChromeWatchCore
import Foundation

/// What the menu bar label shows. Changes only when the count or the stale tint changes,
/// so the label does not re-render on every poll.
@MainActor
final class MenuBarStatus: ObservableObject {
    @Published private(set) var count = 0
    @Published private(set) var hasStaleAutomated = false

    func update(_ instances: [ChromeInstance], now: Date) {
        let stale = instances.contains { $0.isStale(now: now) }
        if count != instances.count { count = instances.count }
        if hasStaleAutomated != stale { hasStaleAutomated = stale }
    }
}

/// Polls the process table on a background queue and publishes Chrome instances.
@MainActor
final class Monitor: ObservableObject {
    static let intervalKey = "refreshInterval"
    static let intervalChoices: [TimeInterval] = [2, 5, 10, 30, 60]

    @Published private(set) var instances: [ChromeInstance] = []
    @Published private(set) var lastRefresh = Date()
    /// Row IDs with a quit in flight, and the last outcome message per row.
    @Published private(set) var quitting: Set<String> = []
    @Published var notice: String?

    @Published var interval: TimeInterval {
        didSet {
            UserDefaults.standard.set(interval, forKey: Self.intervalKey)
            schedule()
        }
    }

    let status = MenuBarStatus()
    /// Rows are only published while the panel is open; otherwise just the label status.
    var isPanelVisible = false {
        didSet { if isPanelVisible { refreshNow() } }
    }

    private let queue = DispatchQueue(label: "ChromeWatch.poll", qos: .utility)
    private let reader = SystemProcessReader()
    private var timer: DispatchSourceTimer?

    init() {
        let saved = UserDefaults.standard.double(forKey: Self.intervalKey)
        interval = saved > 0 ? saved : 5
        schedule()
    }

    private func schedule() {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Generous leeway lets macOS coalesce wakeups.
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(Int(interval * 200)))
        timer.setEventHandler { [weak self, reader] in
            let found = Self.scan(reader)
            Task { @MainActor in self?.publish(found) }
        }
        timer.resume()
        self.timer = timer
    }

    func refreshNow() {
        queue.async { [weak self, reader] in
            let found = Self.scan(reader)
            Task { @MainActor in self?.publish(found) }
        }
    }

    nonisolated private static func scan(_ reader: SystemProcessReader) -> [ChromeInstance] {
        let table = reader.snapshot()
        return ChromeDetector.detect(in: table, footprint: SystemProcessReader.physicalFootprint(pid:))
    }

    private func publish(_ found: [ChromeInstance]) {
        let now = Date()
        status.update(found, now: now)
        guard isPanelVisible else { return }
        lastRefresh = now
        if found != instances { instances = found }
        let live = quitting.intersection(found.map(\.id))
        if live != quitting { quitting = live }
    }

    // MARK: Actions

    func quit(_ instance: ChromeInstance) {
        if instance.kind == .mine, !confirmQuitMine(instance) { return }
        let identity = ProcessIdentity(instance)
        quitting.insert(instance.id)
        Task {
            let outcome = await ProcessControl.terminate(identity)
            switch outcome {
            case .exitedAfterTerm(let seconds):
                notice = "PID \(identity.pid) exited after SIGTERM (\(String(format: "%.1f", seconds)) s)."
            case .killed:
                notice = "PID \(identity.pid) ignored SIGTERM for 5 s; sent SIGKILL."
            case .notRunning:
                notice = "PID \(identity.pid) is no longer that Chrome; nothing was sent."
            case .failed(let reason):
                notice = "Could not quit PID \(identity.pid): \(reason)"
            }
            quitting.remove(instance.id)
            refreshNow()
        }
    }

    private func confirmQuitMine(_ instance: ChromeInstance) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Quit your own Chrome?"
        alert.informativeText = "PID \(instance.pid) looks like the Chrome you use yourself. Open tabs may be lost if Chrome is not set to restore them."
        alert.addButton(withTitle: "Quit Chrome")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    func copyDetails(_ instance: ChromeInstance) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Format.details(instance), forType: .string)
        notice = "Copied details for PID \(instance.pid)."
    }

    /// `open -n` starts a new Chrome even while an automated copy makes macOS think it's running.
    func openMyChrome() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", "-a", "Google Chrome"]
        do {
            try process.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.refreshNow() }
        } catch {
            notice = "Could not open Chrome: \(error.localizedDescription)"
        }
    }
}
