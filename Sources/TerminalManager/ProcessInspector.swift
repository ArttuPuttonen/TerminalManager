import Darwin
import Foundation

/// Low-level helpers that look at what is running inside a terminal's pty.
enum ProcessInspector {
    /// The process group that currently owns the terminal (the "foreground job").
    static func foregroundGroup(ptyFD: Int32) -> pid_t {
        guard ptyFD >= 0 else { return -1 }
        return tcgetpgrp(ptyFD)
    }

    static func name(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 1024)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
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

    static func pids(inGroup pgid: pid_t) -> [pid_t] {
        guard pgid > 0 else { return [] }
        let needed = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pgid), nil, 0)
        guard needed > 0 else { return [pgid] }
        let stride = MemoryLayout<pid_t>.stride
        var pids = [pid_t](repeating: 0, count: Int(needed) / stride + 16)
        let bytes = pids.withUnsafeMutableBytes { raw in
            proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pgid), raw.baseAddress, Int32(raw.count))
        }
        guard bytes > 0 else { return [pgid] }
        return pids.prefix(Int(bytes) / stride).filter { $0 > 0 }
    }

    /// Total CPU time (user + system) consumed by every process in the group, in seconds.
    static func cpuSeconds(group pgid: pid_t) -> Double {
        pids(inGroup: pgid).reduce(0) { $0 + cpuSeconds(pid: $1) }
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
