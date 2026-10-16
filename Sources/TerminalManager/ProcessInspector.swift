import Darwin
import Foundation

/// Low-level helpers that look at what is running inside a terminal.
enum ProcessInspector {
    static func name(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 1024)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    static func executablePath(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4096) // PROC_PIDPATHINFO_MAXSIZE
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// A readable program name. Some tools name their binary after their version
    /// (Claude Code runs as ".../claude/versions/2.1.301"), so fall back to the path.
    static func displayName(pid: pid_t, processName: String) -> String {
        let looksLikeVersion = !processName.isEmpty && processName.allSatisfy { $0.isNumber || $0 == "." }
        guard looksLikeVersion, let path = executablePath(of: pid) else { return processName }
        let parts = path.split(separator: "/").map(String.init)
        if let named = parts.first(where: { $0.lowercased() == "claude" || $0.lowercased() == ".claude" }) {
            return named.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        // e.g. /opt/tool/versions/1.2.3 -> "tool"
        let meaningful = parts.dropLast().reversed().first { !["versions", "bin", "libexec", "local", "share"].contains($0.lowercased()) }
        return meaningful ?? processName
    }

    /// Current working directory of a process.
    static func workingDirectory(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }

    static func cpuSeconds(pid: pid_t) -> Double {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return 0 }
        // pti_total_* are in Mach absolute time units (nanoseconds on Intel, ticks on Apple Silicon).
        let ticks = Double(info.pti_total_user + info.pti_total_system)
        return ticks * timebaseToNanoseconds / 1_000_000_000
    }

    private static let timebaseToNanoseconds: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return timebase.denom == 0 ? 1 : Double(timebase.numer) / Double(timebase.denom)
    }()
}

/// A process attached to a terminal device, from the kernel's process table.
struct TTYProcess {
    let pid: pid_t
    let parentPid: pid_t
    let groupID: pid_t
    /// The terminal's foreground process group.
    let terminalGroupID: pid_t
    let name: String
}

extension ProcessInspector {
    /// Every process whose controlling terminal is `ttyPath` (e.g. /dev/ttys003).
    static func processes(onTTY ttyPath: String) -> [TTYProcess] {
        var info = stat()
        guard stat(ttyPath, &info) == 0 else { return [] }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_TTY, Int32(info.st_rdev)]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 8)
        size = procs.count * stride
        guard sysctl(&mib, UInt32(mib.count), &procs, &size, nil, 0) == 0 else { return [] }
        return procs.prefix(size / stride).map { kp in
            let name = withUnsafeBytes(of: kp.kp_proc.p_comm) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            return TTYProcess(pid: kp.kp_proc.p_pid, parentPid: kp.kp_eproc.e_ppid, groupID: kp.kp_eproc.e_pgid,
                              terminalGroupID: kp.kp_eproc.e_tpgid, name: name)
        }
    }

    /// The kernel stamps a terminal device on every write (program output) and read (your input),
    /// with about one second of precision. That lets us see activity in another app's terminals.
    static func ttyActivity(_ ttyPath: String) -> (lastOutput: Date, lastInput: Date)? {
        var info = stat()
        guard stat(ttyPath, &info) == 0 else { return nil }
        func date(_ ts: timespec) -> Date {
            Date(timeIntervalSince1970: Double(ts.tv_sec) + Double(ts.tv_nsec) / 1_000_000_000)
        }
        return (date(info.st_mtimespec), date(info.st_atimespec))
    }
}
