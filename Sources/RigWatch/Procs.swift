import Darwin
import Foundation

struct Proc: Identifiable, Hashable {
    let pid: Int32
    var ppid: Int32
    var uid: UInt32
    var path: String
    var name: String
    var cpu: Double          // % of one core
    var mem: UInt64          // physical footprint (own processes) or RSS (others)
    var diskRead: Double     // bytes/s, own processes only
    var diskWrite: Double
    var group: String
    var session: String?     // CLAUDE_CODE_SESSION_ID inherited by this process, if any
    var hostSession: String? // CLAUDE_CODE_HOST_SESSION_ID (desktop app's local_… id), if any
    var args: [String]
    var id: Int32 { pid }
    var isOwn: Bool { uid == getuid() }
}

/// Process sampler. One `ps` for the full list (ps is setuid, so it sees root processes too),
/// then `proc_pid_rusage` on our own processes for exact CPU, footprint and disk I/O.
final class ProcSampler {
    private struct Prev { var cpuTicks: UInt64; var read: UInt64; var write: UInt64; var start: UInt64 }
    private struct Meta { var start: UInt64; var args: [String]; var session: String?; var hostSession: String? }
    private var prev: [Int32: Prev] = [:]
    private var meta: [Int32: Meta] = [:]
    private var prevWall: UInt64 = 0
    private let tb: Double = { var i = mach_timebase_info(); mach_timebase_info(&i); return Double(i.numer) / Double(i.denom) }()
    private lazy var argmax: Int = { var m: Int32 = 0; var s = MemoryLayout<Int32>.size; sysctlbyname("kern.argmax", &m, &s, nil, 0); return Int(m) }()
    private lazy var buf = [UInt8](repeating: 0, count: argmax)

    /// Host session id (desktop `local_…`) of a Claude process, read from its environment.
    func hostSession(_ pid: Int32) -> String? { meta[pid]?.hostSession }

    func sample() -> [Proc] {
        let r = Sh.run("/bin/ps", ["-axww", "-o", "pid=,ppid=,uid=,%cpu=,rss=,comm="], timeout: 5)
        let wall = mach_absolute_time()
        let dt = prevWall == 0 ? 0 : Double(wall - prevWall) * tb / 1e9
        prevWall = wall
        let me = getuid()
        var out: [Proc] = []
        var seen = Set<Int32>()
        for line in r.out.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard f.count == 6, let pid = Int32(f[0]), let ppid = Int32(f[1]), let uid = UInt32(f[2]) else { continue }
            let path = String(f[5])
            var p = Proc(pid: pid, ppid: ppid, uid: uid, path: path, name: (path as NSString).lastPathComponent,
                         cpu: Double(f[3]) ?? 0, mem: (UInt64(f[4]) ?? 0) * 1024, diskRead: 0, diskWrite: 0,
                         group: "", session: nil, hostSession: nil, args: [])
            seen.insert(pid)
            if uid == me, let ri = rusage(pid) {
                let ticks = ri.ri_user_time + ri.ri_system_time
                if let pv = prev[pid], pv.start == ri.ri_proc_start_abstime, dt > 0 {
                    p.cpu = Double(ticks &- pv.cpuTicks) * tb / 1e9 / dt * 100
                    p.diskRead = Double(ri.ri_diskio_bytesread &- pv.read) / dt
                    p.diskWrite = Double(ri.ri_diskio_byteswritten &- pv.write) / dt
                }
                p.mem = ri.ri_phys_footprint
                prev[pid] = Prev(cpuTicks: ticks, read: ri.ri_diskio_bytesread, write: ri.ri_diskio_byteswritten, start: ri.ri_proc_start_abstime)
                let start = ri.ri_proc_start_abstime
                if meta[pid]?.start != start { meta[pid] = readMeta(pid, start: start) }
                p.args = meta[pid]?.args ?? []
                p.session = meta[pid]?.session
                p.hostSession = meta[pid]?.hostSession
            }
            p.group = Self.group(p)
            out.append(p)
        }
        prev = prev.filter { seen.contains($0.key) }
        meta = meta.filter { seen.contains($0.key) }
        return out
    }

    private func rusage(_ pid: Int32) -> rusage_info_v4? {
        var ri = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &ri) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return rc == 0 ? ri : nil
    }

    /// Reads argv and the two session variables from KERN_PROCARGS2. The rest of the environment
    /// (tokens live there) is never kept.
    private func readMeta(_ pid: Int32, start: UInt64) -> Meta {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = buf.count
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return Meta(start: start, args: []) }
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = 4
        while i < size && buf[i] != 0 { i += 1 }          // exec path
        while i < size && buf[i] == 0 { i += 1 }          // padding
        var strings: [String] = []
        var s = i
        while i < size {
            if buf[i] == 0 {
                if i == s { break }
                strings.append(String(decoding: buf[s..<i], as: UTF8.self))
                s = i + 1
            }
            i += 1
        }
        let args = Array(strings.prefix(argc))
        var session: String?, host: String?
        for e in strings.dropFirst(argc) {
            if e.hasPrefix("CLAUDE_CODE_SESSION_ID=") { session = String(e.dropFirst(23)) }
            else if e.hasPrefix("CLAUDE_CODE_HOST_SESSION_ID=") { host = String(e.dropFirst(28)) }
        }
        return Meta(start: start, args: args.map { $0.count > 300 ? String($0.prefix(300)) + "…" : $0 }, session: session, hostSession: host)
    }

    static func group(_ p: Proc) -> String {
        let path = p.path, name = p.name
        if name.hasPrefix("qemu-system") { return "Android emulators" }
        if path.contains("/CoreSimulator/") || name == "launchd_sim" || name == "Simulator" { return "iOS simulators" }
        if name == "java" || path.hasSuffix("/bin/java") {
            let a = p.args.joined(separator: " ")
            if a.contains("GradleDaemon") || a.contains("gradle-launcher") || a.contains("GradleWrapperMain") { return "Gradle" }
            if a.contains("KotlinCompileDaemon") || a.contains("kotlin-daemon") { return "Kotlin daemon" }
            if path.contains("Android Studio") { return "Android Studio" }
            return "Java"
        }
        if name == "claude" || path.contains("/claude-code/") { return "Claude Code sessions" }
        if name == "opencode" { return "OpenCode" }
        if name == "codex" { return "Codex" }
        if path.contains("Xcode.app") || ["xcodebuild", "swift-frontend", "clang", "ld", "SourceKitService"].contains(name) { return "Xcode / Swift" }
        if let r = path.range(of: ".app/") {
            let app = String(path[..<r.lowerBound])
            return (app as NSString).lastPathComponent
        }
        if name == "node" { return "Node" }
        if p.uid == 0 { return "System (root)" }
        if path.hasPrefix("/System/") || path.hasPrefix("/usr/libexec/") || path.hasPrefix("/usr/sbin/") { return "macOS services" }
        return name
    }

    /// Current directory of one of our processes (for "is this worktree in use?").
    static func cwd(_ pid: Int32) -> String? {
        var v = proc_vnodepathinfo()
        let n = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &v, Int32(MemoryLayout<proc_vnodepathinfo>.size))
        guard n > 0 else { return nil }
        return withUnsafePointer(to: &v.pvi_cdir.vip_path) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
    }
}
