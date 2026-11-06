import Darwin
import WebKit

/// Measures memory the way Activity Monitor's "Memory" column does (physical footprint),
/// summed over the app and every helper process macOS attributes to it. WebKit's WebContent,
/// Networking and GPU processes do the real work and hold most of the memory, so counting
/// only the app process would badly under-report.
enum MemoryMeter {
    struct Sample {
        var total: UInt64
        var processCount: Int
        var byPID: [pid_t: UInt64]
    }

    static func sample(including known: [pid_t] = []) -> Sample {
        let me = getpid()
        var pids = Set(known)
        pids.insert(me)
        pids.formUnion(processesAttributed(to: me))
        var byPID: [pid_t: UInt64] = [:]
        for pid in pids {
            let bytes = footprint(of: pid)
            if bytes > 0 { byPID[pid] = bytes }
        }
        return Sample(total: byPID.values.reduce(0, +), processCount: byPID.count, byPID: byPID)
    }

    static func footprint(of pid: pid_t) -> UInt64 {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? info.ri_phys_footprint : 0
    }

    private typealias ResponsiblePID = @convention(c) (pid_t) -> pid_t

    /// libsystem function Activity Monitor uses to group helper processes under their app.
    private static let responsiblePID: ResponsiblePID? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsiblePID.self)
    }()

    private static func processesAttributed(to me: pid_t) -> [pid_t] {
        guard let responsiblePID else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
        let count = pids.withUnsafeMutableBytes { Int(proc_listallpids($0.baseAddress, Int32($0.count))) }
        let owner = responsiblePID(me)
        if owner == me || owner <= 0 {
            return pids.prefix(max(0, count)).filter { $0 > 0 && $0 != me && responsiblePID($0) == me }
        }
        // Started from a terminal, macOS charges our helpers to the terminal. Count the
        // terminal's WebKit processes that started after we did.
        let myStart = startTime(of: me)
        return pids.prefix(max(0, count)).filter { pid in
            pid > 0 && pid != me && responsiblePID(pid) == owner && startTime(of: pid) >= myStart
                && path(of: pid).contains("/com.apple.WebKit.")
        }
    }

    private static func startTime(of pid: pid_t) -> UInt64 {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return 0 }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }

    static func path(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return "" }
        return String(cString: buffer)
    }
}

extension WKWebView {
    /// PID of the WebContent process rendering this view.
    var processIdentifier: pid_t? { pid(from: "_webProcessIdentifier") }
    /// PIDs of the Networking and GPU processes shared by all web views.
    var sharedProcessIdentifiers: [pid_t] {
        ["_networkProcessIdentifier", "_gpuProcessIdentifier"].compactMap(pid(from:))
    }

    /// Reads a WebKit SPI process identifier; nil if this WebKit doesn't have it.
    private func pid(from key: String) -> pid_t? {
        guard responds(to: NSSelectorFromString(key)),
              let pid = (value(forKey: key) as? NSNumber)?.int32Value, pid > 0 else { return nil }
        return pid
    }
}
