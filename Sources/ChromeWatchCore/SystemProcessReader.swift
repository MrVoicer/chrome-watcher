import Darwin
import Foundation

/// Reads the live process table straight from the kernel: no `ps`, no subprocesses.
///
/// Not thread safe: use one instance from one queue.
public final class SystemProcessReader {
    private struct Key: Hashable {
        let pid: Int32, seconds: Int, micros: Int32
    }

    private struct Details {
        let path: String?
        let arguments: [String]
    }

    /// Executable path and argv never change for a given (pid, start time), so read them once.
    private var detailsCache: [Key: Details] = [:]
    private var argumentBuffer: [UInt8]
    private let uid = getuid()

    public init() {
        argumentBuffer = [UInt8](repeating: 0, count: Self.argumentMax())
    }

    /// All processes. Paths and arguments are filled in for the current user's processes only;
    /// other users' arguments are not readable without root, and nothing we look for lives there.
    public func snapshot() -> ProcessTable {
        var seen: Set<Key> = []
        var records: [ProcessRecord] = []
        for info in Self.allKinfo() {
            var record = Self.record(from: info)
            if record.uid == uid, !record.isZombie {
                let key = Key(pid: record.pid, seconds: record.startSeconds, micros: record.startMicroseconds)
                seen.insert(key)
                let details = detailsCache[key] ?? {
                    let fresh = Details(path: Self.executablePath(pid: record.pid), arguments: arguments(pid: record.pid) ?? [])
                    detailsCache[key] = fresh
                    return fresh
                }()
                record.executablePath = details.path
                record.arguments = details.arguments
            }
            records.append(record)
        }
        detailsCache = detailsCache.filter { seen.contains($0.key) }
        return ProcessTable(records)
    }

    // MARK: sysctl

    private static func argumentMax() -> Int {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &value, &size, nil, 0) == 0, value > 0 else { return 1 << 20 }
        return Int(value)
    }

    /// `sysctl` `KERN_PROC_ALL`.
    static func allKinfo() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        for _ in 0..<4 {
            var size = 0
            guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }
            // Room for processes started between the two calls.
            size += size / 8
            var list = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
            let result = list.withUnsafeMutableBytes { buffer in
                sysctl(&mib, 4, buffer.baseAddress, &size, nil, 0)
            }
            if result == 0 {
                return Array(list.prefix(size / MemoryLayout<kinfo_proc>.stride))
            }
            if errno != ENOMEM { return [] }
        }
        return []
    }

    /// `sysctl` `KERN_PROC_PID` for one process.
    static func kinfo(pid: Int32) -> kinfo_proc? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        return info
    }

    static func record(from info: kinfo_proc) -> ProcessRecord {
        let name = withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        let start = info.kp_proc.p_un.__p_starttime
        return ProcessRecord(
            pid: info.kp_proc.p_pid,
            ppid: info.kp_eproc.e_ppid,
            uid: info.kp_eproc.e_ucred.cr_uid,
            name: name,
            startSeconds: start.tv_sec,
            startMicroseconds: start.tv_usec,
            executablePath: nil,
            arguments: [],
            isZombie: info.kp_proc.p_stat == SZOMB
        )
    }

    /// `KERN_PROCARGS2`: argc, exec path, padding, then argv strings, then the environment.
    func arguments(pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = argumentBuffer.count
        let ok = argumentBuffer.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) } == 0
        guard ok, size > MemoryLayout<Int32>.size else { return nil }
        return Self.parseProcArgs(argumentBuffer[0..<size])
    }

    static func parseProcArgs(_ bytes: ArraySlice<UInt8>) -> [String]? {
        guard bytes.count > 4 else { return nil }
        let base = bytes.startIndex
        let argc = Int(bytes[base]) | Int(bytes[base + 1]) << 8 | Int(bytes[base + 2]) << 16 | Int(bytes[base + 3]) << 24
        var index = base + 4
        // Skip the exec path and the NUL padding after it.
        while index < bytes.endIndex, bytes[index] != 0 { index += 1 }
        while index < bytes.endIndex, bytes[index] == 0 { index += 1 }
        var args: [String] = []
        while args.count < argc, index < bytes.endIndex {
            let start = index
            while index < bytes.endIndex, bytes[index] != 0 { index += 1 }
            args.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        return args
    }

    // MARK: libproc

    public static func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// `proc_pid_rusage` `ri_phys_footprint`: the "Memory" column in Activity Monitor.
    public static func physicalFootprint(pid: Int32) -> UInt64? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? info.ri_phys_footprint : nil
    }

    /// `proc_pidinfo` `PROC_PIDTBSDINFO`: parent PID and start time of one process.
    public static func bsdInfo(pid: Int32) -> (ppid: Int32, startSeconds: Int, startMicroseconds: Int32, isZombie: Bool)? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return (Int32(info.pbi_ppid), Int(info.pbi_start_tvsec), Int32(info.pbi_start_tvusec), info.pbi_status == SZOMB)
    }
}
