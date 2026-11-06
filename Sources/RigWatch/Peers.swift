import Darwin
import Foundation

/// Other Macs whose emulators this Mac's agents may use, to spread the load. Each runs RigWatch; this Mac talks
/// to it over SSH (`RigWatch peer info`, `RigWatch peer hold`). Using another Mac takes consent on both sides:
/// it is allowed here (Device Manager page) and it shares its devices there (its own Device Manager page).
struct Peer: Codable, Equatable, Identifiable {
    var host: String               // what `ssh` is given: an SSH config alias, a Tailscale name or an address
    var allowed = false
    var id: String { host }
}

/// What a Mac reports about itself to the Macs that may use it.
struct PeerInfo: Codable, Equatable {
    var name: String
    var version: String
    var sharing: Bool              // it lets other Macs use its devices
    var cores: Int
    var memGB: Double
    var pressure: Int32
    var load: Double
    var emulators: [PeerDevice]
    var simulators: [PeerDevice]
    var avds: [String]
    var xcode: Bool
}
struct PeerDevice: Codable, Equatable { var id: String, name: String, free: Bool }

enum Peers {
    static let file = Rules.dir + "/peers.json"

    static func load() -> [Peer] { FileManager.default.contents(atPath: file).flatMap { try? JSONDecoder().decode([Peer].self, from: $0) } ?? [] }
    static func save(_ p: [Peer]) { Rules.write(try? JSONEncoder().encode(p), to: file) }
    static func setAllowed(_ host: String, _ on: Bool) {
        var all = load()
        if let i = all.firstIndex(where: { $0.host == host }) { all[i].allowed = on } else { all.append(Peer(host: host, allowed: on)) }
        save(all)
        Rules.log("peers: \(on ? "allowed" : "disallowed") \(host)")
    }

    static var localName: String { Host.current().localizedName ?? ProcessInfo.processInfo.hostName }

    /// Macs worth asking: SSH config aliases and Tailscale's online macOS peers, other than this Mac, plus saved ones.
    static func candidates() -> [String] {
        var out = load().map(\.host)
        let cfg = (try? String(contentsOfFile: Sh.home + "/.ssh/config", encoding: .utf8)) ?? ""
        for line in cfg.split(separator: "\n") {
            let f = line.trimmingCharacters(in: .whitespaces).split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 2, f[0].lowercased() == "host" else { continue }
            let h = String(f[1])
            if h.contains("*") || h.contains("?") || h.lowercased().contains("github") || h.lowercased().contains("gitlab") { continue }
            out.append(h)
        }
        let ts = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
        if FileManager.default.isExecutableFile(atPath: ts), let j = try? JSONSerialization.jsonObject(with: Sh.run(ts, ["status", "--json"], timeout: 5).data) as? [String: Any] {
            for (_, v) in (j["Peer"] as? [String: Any]) ?? [:] {
                guard let p = v as? [String: Any], p["OS"] as? String == "macOS", p["Online"] as? Bool == true,
                      let dns = p["DNSName"] as? String, let name = dns.split(separator: ".").first else { continue }
                out.append(String(name))
            }
        }
        let me = Set([localName.lowercased(), ProcessInfo.processInfo.hostName.lowercased().split(separator: ".").first.map(String.init) ?? ""])
        var seen = Set<String>()
        return out.filter { !me.contains($0.lowercased()) && seen.insert($0.lowercased()).inserted }
    }

    /// The remote RigWatch, run through the login shell's PATH-free environment.
    /// Only once that RigWatch knows `peer`: an older one would take the unknown command for "open the app".
    static func remote(_ args: [String]) -> String {
        "R=\"$HOME/Applications/RigWatch.app/Contents/MacOS/RigWatch\"; [ -x \"$R\" ] || R=/opt/homebrew/bin/rigwatch; "
            + "\"$R\" help 2>/dev/null | grep -q 'RigWatch peer' || { echo RIGWATCH_NO_PEER; exit 3; }; exec \"$R\" peer "
            + args.map(Rules.quote).joined(separator: " ")
    }
    static let sshOpts = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3"]

    enum Status: Equatable { case online(PeerInfo), noRigWatch, unreachable(String) }

    static func probe(_ host: String) -> Status {
        let r = Sh.run("/usr/bin/ssh", sshOpts + [host, remote(["info"])], timeout: 12)
        if r.code == 3 || r.out.contains("RIGWATCH_NO_PEER") { return .noRigWatch }
        if r.code == 255 { return .unreachable(r.err.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init) ?? "SSH failed") }
        guard r.code == 0, let line = r.out.split(separator: "\n").last, let info = try? JSONDecoder().decode(PeerInfo.self, from: Data(line.utf8)) else {
            return r.out.contains("peer") || r.err.contains("not found") || r.code == 127 ? .noRigWatch : .unreachable((r.err.isEmpty ? r.out : r.err).prefix(160).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return .online(info)
    }

    // MARK: on the Mac being used

    /// `RigWatch peer info|hold ...`, run by another Mac over SSH.
    static func main(_ a: [String]) -> Int32 {
        switch a.first {
        case "info": print(String(decoding: (try? JSONEncoder().encode(info())) ?? Data(), as: UTF8.self)); return 0
        case "hold": return hold(Array(a.dropFirst()))
        case "run": return run(Array(a.dropFirst()))
        default: Rules.say("usage: RigWatch peer info | peer hold --platform android [--name N] [--session S] [--purpose P] [--minutes M] [--from HOST]"); return 2
        }
    }

    static func info() -> PeerInfo {
        let s = RuleSettings.load(), devs = DeviceManager.running(), leases = Leases.live()
        func row(_ d: Device) -> PeerDevice { PeerDevice(id: d.id, name: d.name, free: d.claim == nil && !leases.contains { $0.covers(d) }) }
        var l = [Double](repeating: 0, count: 3); getloadavg(&l, 3)
        return PeerInfo(name: localName, version: AppCopy.ownVersion, sharing: s.shareDevices, cores: ProcessInfo.processInfo.activeProcessorCount,
                        memGB: Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824, pressure: Rules.pressure(), load: l[0],
                        emulators: devs.filter { $0.kind == .emulator }.map(row), simulators: devs.filter { $0.kind == .simulator }.map(row),
                        avds: DeviceManager.avds(), xcode: FileManager.default.fileExists(atPath: "/Applications/Xcode.app"))
    }

    /// Leases an emulator here for an agent on another Mac and keeps it until that Mac hangs up (stdin closes).
    /// Prints one JSON line: the device and its adb port, which the other Mac tunnels to.
    static func hold(_ a: [String]) -> Int32 {
        func arg(_ k: String) -> String? { a.firstIndex(of: k).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil } }
        func reply(_ o: [String: Any]) { print(String(decoding: (try? JSONSerialization.data(withJSONObject: o)) ?? Data(), as: UTF8.self)); fflush(stdout) }
        guard RuleSettings.load().shareDevices else { reply(["ok": false, "error": "\(localName) doesn't share its devices (Device Manager page there)."]); return 1 }
        guard arg("--platform") == "android" else { reply(["ok": false, "error": "only Android emulators can be used from another Mac this way"]); return 2 }
        let from = arg("--from") ?? "another Mac"
        setenv("CLAUDE_CODE_SESSION_ID", "\(from)/\(arg("--session") ?? "agent")", 1)
        do {
            let g = try DeviceManager.acquire(platform: "android", want: arg("--name"), minutes: Int(arg("--minutes") ?? "") ?? Leases.defaultMinutes,
                                              purpose: (arg("--purpose") ?? "") + " (from \(from))", headless: true, virtualOnly: true)
            guard let id = g["id"] as? String, id.hasPrefix("emulator-"), let n = Int(id.dropFirst(9)) else {
                reply(["ok": false, "error": "got \(g["id"] ?? "nothing"), not an emulator"]); return 1
            }
            reply(["ok": true, "id": id, "name": g["name"] ?? id, "port": n + 1, "booted": g["booted_for_you"] ?? false])
            let release = { _ = try? DeviceManager.release(id, shutdown: nil); exit(0) }
            var sources: [DispatchSourceSignal] = []
            for sig in [SIGTERM, SIGHUP, SIGINT] {
                signal(sig, SIG_IGN)
                let src = DispatchSource.makeSignalSource(signal: sig, queue: .global()); src.setEventHandler(handler: release); src.resume(); sources.append(src)
            }
            // Renew while the other Mac holds on; it hangs up by closing stdin.
            let renew = DispatchSource.makeTimerSource(queue: .global())
            renew.schedule(deadline: .now() + 300, repeating: 300)
            renew.setEventHandler { _ = try? DeviceManager.renew(id, minutes: Leases.defaultMinutes) }
            renew.resume()
            _ = FileHandle.standardInput.readDataToEndOfFile()
            withExtendedLifetime((sources, renew)) {}
            release()
            return 0
        } catch let f as DeviceManager.Failure {
            reply(["ok": false, "error": f.message]); return 1
        } catch {
            reply(["ok": false, "error": "\(error)"]); return 1
        }
    }

    /// `peer run --dir D [--session S] [--from HOST] [--simulator] -- CMD`: runs a build or test for another Mac
    /// in the copy of its worktree here, through this Mac's build queue, with one of this Mac's simulators leased
    /// for it (its UDID in RIGWATCH_SIM_UDID) and shut down afterwards.
    static func run(_ a: [String]) -> Int32 {
        func arg(_ k: String) -> String? { a.firstIndex(of: k).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil } }
        guard RuleSettings.load().shareDevices else { Rules.say("RigWatch: \(localName) doesn't share its devices (Device Manager page there)."); return 1 }
        guard let sep = a.firstIndex(of: "--"), sep + 1 < a.count, let dirArg = arg("--dir") else { Rules.say("usage: RigWatch peer run --dir D [--simulator] -- CMD"); return 2 }
        let dir = (dirArg as NSString).expandingTildeInPath, cmd = a[(sep + 1)...].joined(separator: " ")
        let from = arg("--from") ?? "another Mac"
        setenv("CLAUDE_CODE_SESSION_ID", "\(from)/\(arg("--session") ?? "agent")", 1)
        var sim: String?
        if a.contains("--simulator") {
            do {
                let g = try DeviceManager.acquire(platform: "ios", want: arg("--name"), minutes: 120, purpose: "build from \(from)", headless: true, virtualOnly: true, where: "local")
                sim = g["id"] as? String
                Rules.say("RigWatch on \(localName): simulator \(g["name"] ?? "") \(sim ?? "") for this run")
            } catch let f as DeviceManager.Failure { Rules.say("RigWatch on \(localName): no simulator: \(f.message)"); return 1 } catch { return 1 }
        }
        defer { if let sim { _ = try? DeviceManager.release(sim, shutdown: nil) } }
        if let sim { setenv("RIGWATCH_SIM_UDID", sim, 1) }
        guard FileManager.default.changeCurrentDirectoryPath(dir) else { Rules.say("RigWatch on \(localName): no folder \(dir)"); return 1 }
        // Through this Mac's own queue, so a build from another Mac waits its turn like any other.
        let kind = Rules.classify(cmd) ?? "xcodebuild"
        return Rules.run(["--kind", kind, "--", "/bin/zsh", "-lc", cmd])
    }

    // MARK: on the Mac using it

    /// Copies a worktree to an allowed Mac, runs a command there (with a simulator of its own if asked) and copies
    /// result files back. Returns the exit code, the end of the output and what came back.
    static func runRemote(path: String, command: String, host want: String?, simulator: Bool, artifacts: [String], session: String) throws -> [String: Any] {
        let allowed = load().filter(\.allowed).filter { want == nil || $0.host == want }
        guard !allowed.isEmpty else { throw DeviceManager.Failure(message: want.map { "\($0) is not an allowed Mac (Device Manager page)." } ?? "No other Mac is allowed (Device Manager page).") }
        var ranked: [(Peer, PeerInfo)] = []
        for p in allowed { if case .online(let i) = probe(p.host), i.sharing, i.xcode || !simulator { ranked.append((p, i)) } }
        ranked.sort { ($0.1.pressure, $0.1.load / Double(max(1, $0.1.cores))) < ($1.1.pressure, $1.1.load / Double(max(1, $1.1.cores))) }
        guard let (peer, info) = ranked.first else { throw DeviceManager.Failure(message: "No allowed Mac is online, sharing\(simulator ? " and has Xcode" : "") right now.") }
        let host = peer.host
        let me = localName.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression)
        let dest = "Library/Caches/RigWatch/remote/\(me)/\((path as NSString).lastPathComponent)"
        let ssh = (["/usr/bin/ssh"] + sshOpts).joined(separator: " ")
        let t0 = Date()
        _ = Sh.run("/usr/bin/ssh", sshOpts + [host, "mkdir -p " + Rules.quote(dest)], timeout: 20)
        // Build outputs stay behind; everything else, node_modules and Pods included, goes (only changes, after the first time).
        let sync = Sh.run("/usr/bin/rsync", ["-az", "--delete", "-e", ssh, "--exclude", "/build/", "--exclude", "DerivedData/", "--exclude", ".gradle/",
                                             "--exclude", "/app/build/", path + "/", host + ":" + dest + "/"], timeout: 1800)
        guard sync.code == 0 else { throw DeviceManager.Failure(message: "Could not copy the worktree to \(host): \(sync.err.prefix(240))") }
        let copied = Date().timeIntervalSince(t0)
        // Result files come fresh from this run: a stale result bundle there would fail xcodebuild or come back as new.
        if !artifacts.isEmpty {
            _ = Sh.run("/usr/bin/ssh", sshOpts + [host, "cd " + Rules.quote(dest) + " && rm -rf " + artifacts.map(Rules.quote).joined(separator: " ")], timeout: 60)
        }
        var args = ["run", "--dir", "~/" + dest, "--session", session, "--from", localName]
        if simulator { args.append("--simulator") }
        let r = Sh.run("/usr/bin/ssh", sshOpts + ["-T", host, remote(args + ["--", command])], timeout: 4 * 3600)
        var back: [String] = []
        for rel in artifacts {
            let local = path + "/" + rel
            try? FileManager.default.removeItem(atPath: local)
            try? FileManager.default.createDirectory(atPath: (local as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            if Sh.run("/usr/bin/rsync", ["-az", "-e", ssh, host + ":" + dest + "/" + rel, (local as NSString).deletingLastPathComponent + "/"], timeout: 900).code == 0 { back.append(rel) }
        }
        Rules.log("peers: ran on \(host) for session \(session) (exit \(r.code)): \(command.prefix(120))")
        let out = (r.out + (r.err.isEmpty ? "" : "\n" + r.err)).split(separator: "\n", omittingEmptySubsequences: false).suffix(150).joined(separator: "\n")
        return ["mac": "\(info.name) (\(host))", "exit_code": r.code, "copied_worktree_in_s": Int(copied), "ran_in_s": Int(Date().timeIntervalSince(t0) - copied),
                "artifacts_back": back, "output_tail": out]
    }

    /// The SSH connection that holds a remote emulator (its stdin is the hold) and its control socket.
    private static var holds: [String: (proc: Process, stdin: Pipe, control: String)] = [:]
    private static let holdsLock = NSLock()

    /// Leases an emulator on the least busy allowed Mac and tunnels its adb port here. The returned device id is
    /// an adb serial on this Mac ("127.0.0.1:PORT").
    static func acquireRemote(want: String?, minutes: Int, purpose: String, session: String) throws -> (id: String, name: String, host: String, booted: Bool) {
        let allowed = load().filter(\.allowed)
        guard !allowed.isEmpty else { throw DeviceManager.Failure(message: "No other Mac is allowed (Device Manager page).") }
        var ranked: [(Peer, PeerInfo)] = []
        for p in allowed { if case .online(let i) = probe(p.host), i.sharing, !i.avds.isEmpty || i.emulators.contains(where: \.free) { ranked.append((p, i)) } }
        ranked.sort { ($0.1.pressure, $0.1.load / Double(max(1, $0.1.cores))) < ($1.1.pressure, $1.1.load / Double(max(1, $1.1.cores))) }
        guard !ranked.isEmpty else { throw DeviceManager.Failure(message: "No allowed Mac is online and sharing its emulators right now.") }
        var tried: [String] = []
        for (p, _) in ranked {
            do { return try hold(on: p.host, want: want, minutes: minutes, purpose: purpose, session: session) }
            catch let f as DeviceManager.Failure { tried.append("\(p.host): \(f.message)") }
        }
        throw DeviceManager.Failure(message: "No allowed Mac could lend an emulator. " + tried.joined(separator: "; "))
    }

    private static func hold(on host: String, want: String?, minutes: Int, purpose: String, session: String) throws -> (id: String, name: String, host: String, booted: Bool) {
        let control = "/tmp/rwcm-" + UUID().uuidString.prefix(8)
        let p = Process(), inPipe = Pipe(), outPipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var args = ["--platform", "android", "--session", session, "--purpose", purpose, "--minutes", String(minutes), "--from", localName]
        if let want { args += ["--name", want] }
        p.arguments = sshOpts + ["-o", "ControlMaster=yes", "-o", "ControlPath=\(control)", "-o", "ControlPersist=no", "-T", host, remote(["hold"] + args)]
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { throw DeviceManager.Failure(message: "could not start ssh: \(error)") }
        // The first line answers; booting an emulator there can take minutes.
        var line = Data()
        let got = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            while let c = try? outPipe.fileHandleForReading.read(upToCount: 1), !c.isEmpty, c != Data([0x0A]) { line.append(c) }
            got.signal()
        }
        let answered = got.wait(timeout: .now() + 300) == .success
        guard answered, let j = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            p.terminate()
            let text = String(decoding: line, as: UTF8.self)
            throw DeviceManager.Failure(message: text.contains("RIGWATCH_NO_PEER") ? "its RigWatch is missing or older than 1.9"
                                        : answered ? "unexpected answer: \(text.prefix(120))" : "no answer in 5 minutes")
        }
        guard j["ok"] as? Bool == true, let id = j["id"] as? String, let port = j["port"] as? Int else {
            p.terminate(); throw DeviceManager.Failure(message: line.isEmpty || String(decoding: line, as: UTF8.self).contains("RIGWATCH_NO_PEER") ? "its RigWatch is missing or too old" : j["error"] as? String ?? "refused")
        }
        // Forward a free local port to the emulator's adb port over the same connection: it closes with it.
        let local = freePort()
        let fwd = Sh.run("/usr/bin/ssh", ["-o", "ControlPath=\(control)", "-O", "forward", "-L", "\(local):127.0.0.1:\(port)", host], timeout: 15)
        let serial = "127.0.0.1:\(local)"
        guard fwd.code == 0 else { p.terminate(); throw DeviceManager.Failure(message: "could not forward its adb port: \(fwd.err.prefix(160))") }
        _ = Sh.run(Sh.adb, ["connect", serial], timeout: 15)
        var ready = false
        for _ in 0..<30 {
            if Sh.run(Sh.adb, ["-s", serial, "get-state"], timeout: 5).out.trimmingCharacters(in: .whitespacesAndNewlines) == "device" { ready = true; break }
            usleep(1_000_000)
        }
        guard ready else { _ = Sh.run(Sh.adb, ["disconnect", serial], timeout: 5); p.terminate(); throw DeviceManager.Failure(message: "adb could not reach \(id) through the tunnel") }
        holdsLock.lock(); holds[serial] = (p, inPipe, control); holdsLock.unlock()
        Rules.log("peers: \(id) on \(host) as \(serial) for session \(session)")
        return (serial, "\(j["name"] as? String ?? id) on \(host)", host, j["booted"] as? Bool ?? false)
    }

    /// Hangs up a remote hold: the other Mac releases the emulator (and shuts it down if it booted it).
    static func release(_ serial: String) {
        holdsLock.lock(); let h = holds.removeValue(forKey: serial); holdsLock.unlock()
        _ = Sh.run(Sh.adb, ["disconnect", serial], timeout: 5)
        guard let h else { return }
        try? h.stdin.fileHandleForWriting.close()
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) { if h.proc.isRunning { h.proc.terminate() } }
    }

    static func sweep() {
        holdsLock.lock(); let held = Array(holds.keys); holdsLock.unlock()
        let live = Set(Leases.live().map(\.device))
        for s in held where !live.contains(s) { release(s); Rules.log("peers: lease on \(s) ended; handed it back") }
    }

    static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_port = 0; a.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return Int(UInt16(bigEndian: a.sin_port))
    }
}
