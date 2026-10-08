import Foundation

/// One row of the process table, as read from the kernel (or built by hand in tests).
public struct ProcessRecord: Sendable, Equatable {
    public var pid: Int32
    public var ppid: Int32
    public var uid: UInt32
    /// Short kernel name (`p_comm`, at most 16 characters).
    public var name: String
    /// Process start time. Kept as the raw timeval so identity checks compare exactly.
    public var startSeconds: Int
    public var startMicroseconds: Int32
    /// Absolute executable path (`proc_pidpath`), if readable.
    public var executablePath: String?
    /// argv, including argv[0]. Empty if unreadable (other users' processes).
    public var arguments: [String]
    public var isZombie: Bool

    public init(
        pid: Int32,
        ppid: Int32,
        uid: UInt32 = 501,
        name: String? = nil,
        startSeconds: Int = 0,
        startMicroseconds: Int32 = 0,
        executablePath: String?,
        arguments: [String],
        isZombie: Bool = false
    ) {
        self.pid = pid
        self.ppid = ppid
        self.uid = uid
        let path = executablePath ?? arguments.first ?? ""
        self.name = name ?? String((path as NSString).lastPathComponent.prefix(16))
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
        self.executablePath = executablePath
        self.arguments = arguments
        self.isZombie = isZombie
    }

    public var startDate: Date {
        Date(timeIntervalSince1970: TimeInterval(startSeconds) + TimeInterval(startMicroseconds) / 1_000_000)
    }

    /// Best available path for matching: the resolved executable, else argv[0].
    public var path: String { executablePath ?? arguments.first ?? name }

    /// "pid 123  node …/cliDaemon.js session --headed", used in "Copy details".
    public var chainDescription: String {
        let command = arguments.isEmpty ? path : arguments.joined(separator: " ")
        return "pid \(pid)  \(command)"
    }
}

/// A snapshot of all processes, keyed by PID.
public struct ProcessTable: Sendable {
    public let records: [Int32: ProcessRecord]
    public let children: [Int32: [Int32]]

    public init(_ list: [ProcessRecord]) {
        var records: [Int32: ProcessRecord] = [:]
        var children: [Int32: [Int32]] = [:]
        for record in list {
            records[record.pid] = record
            if record.pid != record.ppid {
                children[record.ppid, default: []].append(record.pid)
            }
        }
        self.records = records
        self.children = children.mapValues { $0.sorted() }
    }

    public subscript(pid: Int32) -> ProcessRecord? { records[pid] }

    /// Parent, grandparent, … up to (not including) launchd / kernel_task.
    public func ancestors(of record: ProcessRecord) -> [ProcessRecord] {
        var chain: [ProcessRecord] = []
        var seen: Set<Int32> = [record.pid]
        var next = record.ppid
        while next > 1, !seen.contains(next), let parent = records[next] {
            chain.append(parent)
            seen.insert(next)
            next = parent.ppid
        }
        return chain
    }

    /// Every process below `pid`, breadth first.
    public func descendants(of pid: Int32) -> [ProcessRecord] {
        var result: [ProcessRecord] = []
        var queue = children[pid] ?? []
        var seen: Set<Int32> = [pid]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            guard seen.insert(current).inserted, let record = records[current] else { continue }
            result.append(record)
            queue.append(contentsOf: children[current] ?? [])
        }
        return result
    }
}
