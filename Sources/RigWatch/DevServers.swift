import Darwin
import Foundation

/// One of our processes with a TCP port open for listening: a dev server, an API, a preview.
struct DevServer: Identifiable, Hashable {
    let pid: Int32
    let start: UInt64            // proc start time (mach abs): pid + start names the process across reuse
    var ppid: Int32
    var name: String             // process name
    var kind: String             // framework guess: "Vite", "uvicorn", "Python · app.py", …
    var ports: [Int]
    var cwd: String?
    var started: Date?
    var cpu = 0.0
    var mem: UInt64 = 0
    var session: String?         // the agent session that started it, now or remembered
    var sessionTitle: String?    // its title when first seen, for once the session is gone
    var parent: String?          // "zsh (4120)" when no session is known
    var id: String { "\(pid):\(start)" }
    var orphaned: Bool { ppid == 1 }
    var label: String { "\(kind) :\(ports.map(String.init).joined(separator: ",:"))" }
}

/// Finds listening TCP sockets with libproc (no lsof) and remembers which session each server
/// was first seen under, so the link survives the session exiting.
final class DevServerScanner {
    private struct Seen { let start: UInt64; var ports: [Int] }
    struct Owner: Codable { let session: String; let title: String }
    private var seen: [Int32: Seen] = [:]
    private var lastScan = Date.distantPast
    private var lastFull = Date.distantPast
    private var owners: [String: Owner]
    private var last: [DevServer] = []
    private static let key = "devServerOwners"

    init() {
        owners = (UserDefaults.standard.data(forKey: Self.key)).flatMap { try? JSONDecoder().decode([String: Owner].self, from: $0) } ?? [:]
    }

    /// Socket listing is skipped for macOS's own daemons and app bundles (Python.app is just python).
    static func candidate(_ p: Proc) -> Bool {
        let path = p.path
        if path.hasPrefix("/System/") || path.hasPrefix("/usr/libexec/") || path.hasPrefix("/usr/sbin/") || path.hasPrefix("/sbin/") { return false }
        if path.contains(".app/") && !path.contains("/Python.app/") { return false }
        return !["ssh", "adb", "launchd"].contains(p.name)
    }

    /// Sockets are re-listed at most every 3 s, and then only for processes that are new, already
    /// listening, or due for the 30 s sweep that catches a process opening a port later.
    func scan(_ ps: [Proc], sessions: [Session], agentOwner: [Int32: String]) -> [DevServer] {
        let now = Date()
        guard now.timeIntervalSince(lastScan) >= 3 else { return refresh(last, ps) }
        lastScan = now
        let full = now.timeIntervalSince(lastFull) >= 30
        if full { lastFull = now }
        let me = getuid(), selfPid = getpid()
        let byPid = Dictionary(uniqueKeysWithValues: ps.map { ($0.pid, $0) })
        var alive = Set<Int32>()
        for p in ps where p.uid == me && p.pid != selfPid && p.start != 0 && Self.candidate(p) {
            alive.insert(p.pid)
            let old = seen[p.pid]
            if old?.start != p.start || full || !(old?.ports.isEmpty ?? true) {
                seen[p.pid] = Seen(start: p.start, ports: Self.listeningPorts(p.pid))
            }
        }
        seen = seen.filter { alive.contains($0.key) }

        var out: [DevServer] = []
        var changed = false
        for (pid, s) in seen where !s.ports.isEmpty {
            guard let p = byPid[pid] else { continue }
            var d = DevServer(pid: pid, start: s.start, ppid: p.ppid, name: p.name, kind: Self.kind(p), ports: s.ports)
            d.cpu = p.cpu; d.mem = p.mem
            d.cwd = ProcSampler.cwd(pid); d.started = DeviceSampler.startDate(pid)
            if let now = p.session ?? agentOwner[pid] {
                d.session = now
                if owners[d.id]?.session != now {
                    owners[d.id] = Owner(session: now, title: sessions.first { $0.id == now }?.title ?? String(now.prefix(8)))
                    changed = true
                }
            } else {
                d.session = owners[d.id]?.session
            }
            d.sessionTitle = owners[d.id]?.title
            if d.session == nil, p.ppid > 1, let q = byPid[p.ppid] { d.parent = "\(q.name) (\(q.pid))" }
            out.append(d)
        }
        // A pre-forked server (gunicorn, puma workers) shares its parent's socket: show the parent only.
        let byServerPid = Dictionary(uniqueKeysWithValues: out.map { ($0.pid, $0) })
        out.removeAll { d in byServerPid[d.ppid].map { !Set($0.ports).isDisjoint(with: d.ports) } ?? false }
        let liveKeys = Set(seen.map { "\($0.key):\($0.value.start)" })
        if owners.keys.contains(where: { !liveKeys.contains($0) }) { owners = owners.filter { liveKeys.contains($0.key) }; changed = true }
        if changed, let data = try? JSONEncoder().encode(owners) { UserDefaults.standard.set(data, forKey: Self.key) }
        last = out.sorted { ($0.ports.first ?? 0) < ($1.ports.first ?? 0) }
        return last
    }

    /// Between socket scans: the same servers with fresh CPU and memory.
    private func refresh(_ list: [DevServer], _ ps: [Proc]) -> [DevServer] {
        let byPid = Dictionary(uniqueKeysWithValues: ps.map { ($0.pid, $0) })
        return list.compactMap { d in
            guard let p = byPid[d.pid], p.start == d.start else { return nil }
            var d = d; d.cpu = p.cpu; d.mem = p.mem; d.ppid = p.ppid
            if d.ppid == 1 { d.parent = nil }
            return d
        }
    }

    /// TCP ports in LISTEN state among one process's file descriptors.
    static func listeningPorts(_ pid: Int32) -> [Int] {
        let need = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard need > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        let cap = Int(need) / stride + 8
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: cap)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(cap * stride))
        guard got > 0 else { return [] }
        var ports = Set<Int>()
        for f in fds.prefix(Int(got) / stride) where f.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var si = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, f.proc_fd, PROC_PIDFDSOCKETINFO, &si, size) == size, si.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = si.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            ports.insert(Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))))
        }
        return ports.sorted()
    }

    /// A framework guess from the process name and argv.
    static func kind(_ p: Proc) -> String {
        let n = p.name, args = Array(p.args.dropFirst())
        let a = args.joined(separator: " ")
        func has(_ s: String) -> Bool { a.contains(s) }
        if has("/vite/") || has("vite.js") || args.first == "vite" { return "Vite" }
        if n.hasPrefix("next-server") || has("/next/dist/") || has("/.bin/next") || args.first == "next" { return "Next.js" }
        if has("webpack-dev-server") || has("webpack serve") || (has("/webpack/") && has("serve")) { return "webpack-dev-server" }
        if has("/nuxt/") || has("/nuxi") || args.first == "nuxt" || args.first == "nuxi" { return "Nuxt" }
        if has("/astro/") || has("/.bin/astro") || args.first == "astro" { return "Astro" }
        if has("@remix-run") || has("/.bin/remix") || args.first == "remix" { return "Remix" }
        if has("storybook") { return "Storybook" }
        if n == "puma" || has("puma ") || a.hasPrefix("puma") || has("rails server") || has("rails s") || has("bin/rails") { return "Rails / puma" }
        if has("manage.py runserver") || has("runserver") { return "Django" }
        if n == "uvicorn" || has("uvicorn") { return "uvicorn" }
        if n == "gunicorn" || has("gunicorn") { return "gunicorn" }
        if n == "flask" || has("flask run") || has("-m flask") { return "Flask" }
        if has("http.server") || has("SimpleHTTPServer") { return "python http.server" }
        if n == "hugo" { return "Hugo" }
        if has("jekyll") { return "Jekyll" }
        if n == "node" { return "Node" + script(args) }
        if n == "bun" { return "Bun" + script(args) }
        if n == "deno" { return "Deno" + script(args) }
        if n.lowercased().hasPrefix("python") || n == "Python" { return "Python" + script(args) }
        return n
    }

    /// " · server.js" from the first argument that looks like a script, else "".
    private static func script(_ args: [String]) -> String {
        guard let s = args.first(where: { !$0.hasPrefix("-") }) else { return "" }
        let last = (s as NSString).lastPathComponent
        return last.isEmpty || last.count > 40 ? "" : " · " + last
    }
}
