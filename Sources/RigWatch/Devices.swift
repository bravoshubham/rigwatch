import Foundation

enum DeviceKind: String { case emulator = "Android emulator", phone = "Android device", simulator = "iOS simulator" }

struct Device: Identifiable {
    let id: String                 // adb serial, "pid:N" for an emulator adb can't see, or simulator UDID
    var kind: DeviceKind
    var name: String               // AVD name, model, or simulator name
    var detail = ""                // runtime / product
    var state = ""                 // device, offline, Booted, …
    var pid: Int32?                // qemu or launchd_sim
    var headless = false
    var cpu = 0.0
    var mem: UInt64 = 0
    var started: Date?
    var launchedBy: String?        // session id from the emulator's environment
    var recentUsers: [String: Date] = [:]
    var lastAction: (session: String, command: String, at: Date)?
    var foreground = ""            // top activity / running apps
    var screen = ""
    var guestLoad = ""
    var serial: String? { kind == .simulator || id.hasPrefix("pid:") ? nil : id }
}

final class DeviceSampler {
    private var avdBySerial: [String: (pid: Int32?, avd: String)] = [:]
    private var details: [String: (fg: String, screen: String, load: String)] = [:]
    private var detailsAt = Date.distantPast

    /// Every emulator process and adb device, plus every booted simulator, with CPU/memory summed
    /// over the process tree. `deep` also asks each device what it is showing (one adb/simctl call each).
    func sample(procs: [Proc], deep: Bool) -> [Device] {
        let byPid = Dictionary(uniqueKeysWithValues: procs.map { ($0.pid, $0) })
        var kids: [Int32: [Int32]] = [:]
        for p in procs { kids[p.ppid, default: []].append(p.pid) }
        func tree(_ pid: Int32) -> (Double, UInt64, [Proc]) {
            var cpu = 0.0, mem: UInt64 = 0, all: [Proc] = []
            var stack = [pid]
            while let x = stack.popLast() {
                if let p = byPid[x] { cpu += p.cpu; mem += p.mem; all.append(p) }
                stack += kids[x] ?? []
            }
            return (cpu, mem, all)
        }

        var out: [Device] = []
        // Android: adb's view first.
        let adb = Sh.run(Sh.adb, ["devices", "-l"], timeout: 5).out
        let qemus = procs.filter { $0.name.hasPrefix("qemu-system") }
        var claimed = Set<Int32>()
        for line in adb.split(separator: "\n").dropFirst() {
            let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard f.count >= 2 else { continue }
            let serial = f[0]
            var d = Device(id: serial, kind: serial.hasPrefix("emulator-") ? .emulator : .phone, name: serial)
            d.state = f[1]
            let kv = Dictionary(f.dropFirst(2).compactMap { s -> (String, String)? in
                let p = s.split(separator: ":", maxSplits: 1); return p.count == 2 ? (String(p[0]), String(p[1])) : nil }, uniquingKeysWith: { a, _ in a })
            d.detail = kv["model"] ?? ""
            if d.kind == .emulator {
                let port = Int(serial.dropFirst(9)) ?? 0
                var q = qemus.first { Self.arg($0, "-port").flatMap(Int.init) == port }
                if q == nil {
                    // No -port flag: ask the emulator console for its AVD name, once per process.
                    if avdBySerial[serial] == nil || avdBySerial[serial]!.avd.isEmpty {
                        let n = Sh.run(Sh.adb, ["-s", serial, "emu", "avd", "name"], timeout: 10).out.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        avdBySerial[serial] = (nil, n)
                    }
                    let avd = avdBySerial[serial]!.avd
                    q = qemus.first { !claimed.contains($0.pid) && Self.avd($0) == avd }
                }
                if let q { claimed.insert(q.pid); fill(&d, q, tree) }
                if d.name == serial, let a = avdBySerial[serial]?.avd, !a.isEmpty { d.name = a }
            } else {
                d.name = kv["model"]?.replacingOccurrences(of: "_", with: " ") ?? serial
            }
            out.append(d)
        }
        // One adb emulator and one emulator process left unpaired: they are each other.
        let loneSerials = out.indices.filter { out[$0].kind == .emulator && out[$0].pid == nil }
        let loneQemus = qemus.filter { !claimed.contains($0.pid) && Self.arg($0, "-port") == nil }
        if loneSerials.count == 1, loneQemus.count == 1 {
            claimed.insert(loneQemus[0].pid); out[loneSerials[0]].name = ""; fill(&out[loneSerials[0]], loneQemus[0], tree)
        }
        for q in qemus where !claimed.contains(q.pid) {   // running but not (yet) visible to adb
            var d = Device(id: "pid:\(q.pid)", kind: .emulator, name: "")
            d.state = "not in adb"
            fill(&d, q, tree)
            out.append(d)
        }

        // iOS simulators: one launchd_sim per booted device; its argv names the device directory.
        let sims = procs.filter { $0.name == "launchd_sim" }
        if !sims.isEmpty || deep {
            let names = simNames()
            for s in sims {
                let udid = s.args.joined(separator: " ").firstMatch(#"Devices/([0-9A-F-]{36})"#) ?? "pid:\(s.pid)"
                var d = Device(id: udid, kind: .simulator, name: names[udid]?.name ?? "Simulator")
                d.detail = names[udid]?.runtime ?? ""
                d.state = "Booted"
                d.pid = s.pid
                let (c, m, all) = tree(s.pid)
                d.cpu = c; d.mem = m
                d.started = Self.startDate(s.pid)
                let apps = all.compactMap { p -> String? in
                    guard p.path.contains("/Containers/Bundle/Application/") || p.path.contains("/data/Containers/") else { return nil }
                    return p.path.firstMatch(#"/([^/]+)\.app/"#)
                }
                d.foreground = Array(Set(apps)).sorted().joined(separator: ", ")
                out.append(d)
            }
        }

        if deep && Date().timeIntervalSince(detailsAt) > 10 {
            detailsAt = Date()
            for d in out where d.serial != nil && d.state == "device" { details[d.id] = probe(d.id) }
        }
        for i in out.indices { if let x = details[out[i].id] { out[i].foreground = out[i].foreground.isEmpty ? x.fg : out[i].foreground; out[i].screen = x.screen; out[i].guestLoad = x.load } }
        return out
    }

    private func fill(_ d: inout Device, _ q: Proc, _ tree: (Int32) -> (Double, UInt64, [Proc])) {
        d.pid = q.pid
        if d.name.isEmpty || d.name == d.id { d.name = Self.avd(q) ?? "emulator" }
        d.headless = q.name.hasSuffix("headless") || q.args.contains("-no-window")
        let (c, m, _) = tree(q.pid); d.cpu = c; d.mem = m
        d.launchedBy = q.session
        d.started = Self.startDate(q.pid)
    }

    private func probe(_ serial: String) -> (fg: String, screen: String, load: String) {
        let cmd = "dumpsys activity activities | grep -m1 topResumedActivity; dumpsys power | grep -m1 mWakefulness=; cat /proc/loadavg"
        let lines = Sh.run(Sh.adb, ["-s", serial, "shell", cmd], timeout: 6).out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var fg = "", screen = "", load = ""
        for l in lines {
            if l.contains("topResumedActivity") { fg = l.firstMatch(#"u0 ([^ }]+)"#) ?? "" }
            else if l.hasPrefix("mWakefulness=") { screen = String(l.dropFirst(13)) }
            else if l.first?.isNumber == true { load = l.split(separator: " ").prefix(3).joined(separator: " ") }
        }
        return (fg, screen, load)
    }

    private var simNameCache: (at: Date, map: [String: (name: String, runtime: String)]) = (.distantPast, [:])
    private func simNames() -> [String: (name: String, runtime: String)] {
        if Date().timeIntervalSince(simNameCache.at) < 30 { return simNameCache.map }
        var map: [String: (String, String)] = [:]
        let r = Sh.run("/usr/bin/xcrun", ["simctl", "list", "devices", "booted", "-j"], timeout: 10)
        if let j = try? JSONSerialization.jsonObject(with: r.data) as? [String: Any], let devs = j["devices"] as? [String: [[String: Any]]] {
            for (rt, list) in devs {
                let runtime = (rt.split(separator: ".").last.map(String.init) ?? rt).replacingOccurrences(of: "-", with: " ")
                    .replacingOccurrences(of: #"(\d+) (\d+)"#, with: "$1.$2", options: .regularExpression)
                for x in list { if let u = x["udid"] as? String { map[u] = ((x["name"] as? String) ?? "Simulator", runtime) } }
            }
        }
        simNameCache = (Date(), map)
        return map
    }

    static func arg(_ p: Proc, _ flag: String) -> String? {
        guard let i = p.args.firstIndex(of: flag), i + 1 < p.args.count else { return nil }
        return p.args[i + 1]
    }
    static func avd(_ p: Proc) -> String? {
        if let a = arg(p, "-avd") { return a }
        return p.args.first { $0.hasPrefix("@") }.map { String($0.dropFirst()) }
    }
    static func startDate(_ pid: Int32) -> Date? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))
    }

    // MARK: actions

    static func screenshot(_ d: Device) -> Data? {
        if d.kind == .simulator {
            let f = NSTemporaryDirectory() + "rigwatch-\(d.id).png"
            _ = Sh.run("/usr/bin/xcrun", ["simctl", "io", d.id, "screenshot", "--type=png", f], timeout: 15)
            defer { try? FileManager.default.removeItem(atPath: f) }
            return try? Data(contentsOf: URL(fileURLWithPath: f))
        }
        guard let s = d.serial else { return nil }
        let r = Sh.run(Sh.adb, ["-s", s, "exec-out", "screencap", "-p"], timeout: 15)
        return r.data.count > 1000 ? r.data : nil
    }

    /// Graceful shutdown: emulator console `kill` / `simctl shutdown`, then SIGTERM if it is still up.
    static func shutDown(_ d: Device) -> String {
        if d.kind == .simulator {
            let r = Sh.run("/usr/bin/xcrun", ["simctl", "shutdown", d.id], timeout: 60)
            return r.code == 0 ? "Shut down \(d.name)." : "simctl shutdown failed: \(r.err.prefix(200))"
        }
        if let s = d.serial { _ = Sh.run(Sh.adb, ["-s", s, "emu", "kill"], timeout: 10) }
        guard let pid = d.pid else { return "Sent kill to \(d.name)." }
        for _ in 0..<30 { if kill(pid, 0) != 0 { return "Shut down \(d.name)." }; usleep(500_000) }
        kill(pid, SIGTERM)
        for _ in 0..<20 { if kill(pid, 0) != 0 { return "\(d.name) did not answer the console; stopped it with SIGTERM." }; usleep(500_000) }
        return "\(d.name) is still running after SIGTERM (pid \(pid)). Use Force Quit in Processes if you are sure."
    }
}

extension String {
    func firstMatch(_ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: self, range: NSRange(startIndex..., in: self)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: self) else { return nil }
        return String(self[r])
    }
}
