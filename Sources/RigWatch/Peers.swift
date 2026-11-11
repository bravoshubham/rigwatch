import Darwin
import Foundation
import IOKit

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
    var gpu: Int?                  // GPU busy %, from RigWatch 1.10
    var busy: Double { Peers.busy(pressure: pressure, load: load, cores: cores, gpu: gpu ?? 0) }
}
struct PeerDevice: Codable, Equatable { var id: String, name: String, free: Bool }

enum Peers {
    static let file = Rules.dir + "/peers.json"

    // MARK: how busy a Mac is

    /// 0 when idle, about 1 when the CPU (1-minute load per core) or the GPU is flat out; memory pressure adds
    /// 0.5 (warning) or 1 (critical). Offloading needs another Mac at least `margin` less busy, so a near tie
    /// doesn't send work back and forth.
    static func busy(pressure: Int32, load: Double, cores: Int, gpu: Int) -> Double {
        max(load / Double(max(1, cores)), Double(gpu) / 100) + (pressure >= 4 ? 1 : pressure >= 2 ? 0.5 : 0)
    }
    static let margin = 0.25
    /// This Mac is busy enough that its work should go to a clearly less busy Mac if one can take it.
    static let busyAt = 0.85

    static func gpuNow() -> Int {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
        defer { IOObjectRelease(svc) }
        let st = IORegistryEntryCreateCFProperty(svc, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any]
        return st?["Device Utilization %"] as? Int ?? 0
    }

    static func here() -> (busy: Double, pressure: Int32, cpu: Int, gpu: Int) {
        var l = [Double](repeating: 0, count: 3); getloadavg(&l, 3)
        let cores = ProcessInfo.processInfo.activeProcessorCount, p = Rules.pressure(), g = gpuNow()
        // RIGWATCH_BUSY_HERE stands in for this Mac's load (used to test offloading on one Mac).
        let forced = ProcessInfo.processInfo.environment["RIGWATCH_BUSY_HERE"].flatMap(Double.init)
        return (forced ?? busy(pressure: p, load: l[0], cores: cores, gpu: g), p, Int(100 * l[0] / Double(max(1, cores))), g)
    }
    static func hereIsBusy(_ h: (busy: Double, pressure: Int32, cpu: Int, gpu: Int)) -> Bool { h.pressure >= 2 || h.busy >= busyAt }

    /// What the last check of each Mac found, so the hook can tell without asking over SSH.
    struct Seen: Codable { var at: Date; var info: PeerInfo }
    static let seenFile = Rules.dir + "/peer-status.json"
    static func seen() -> [String: Seen] {
        FileManager.default.contents(atPath: seenFile).flatMap { try? Leases.decoder.decode([String: Seen].self, from: $0) } ?? [:]
    }
    private static let seenLock = NSLock()
    static func remember(_ host: String, _ info: PeerInfo?) {
        seenLock.lock(); defer { seenLock.unlock() }
        var all = seen()
        all[host] = info.map { Seen(at: Date(), info: $0) }
        Rules.write(try? Leases.encoder.encode(all), to: seenFile)
    }

    /// Load here and on the allowed Macs, as last seen (for build_queue).
    static func loadReport() -> String {
        let h = here(), seen = seen()
        var lines = ["load here: busy \(String(format: "%.2f", h.busy)) (CPU \(h.cpu)% of cores, GPU \(h.gpu)%, memory pressure \(Views.pressureName(h.pressure).lowercased()))\(hereIsBusy(h) ? " - busy: prefer run_on_mac for heavy builds and tests" : "")"]
        for p in load() where p.allowed {
            guard let s = seen[p.host], Date().timeIntervalSince(s.at) < 600 else { lines.append("\(p.host): not checked lately"); continue }
            let i = s.info
            lines.append("\(p.host) (\(i.name)): busy \(String(format: "%.2f", i.busy)), \(i.sharing ? "sharing" : "not sharing"), \(i.emulators.filter(\.free).count) free emulators, \(i.avds.count) AVDs\(i.xcode ? ", Xcode" : ""), checked \(Int(Date().timeIntervalSince(s.at) / 60)) min ago")
        }
        if lines.count == 1 { lines.append("other Macs: none allowed") }
        return lines.joined(separator: "\n")
    }

    /// Said to a session about to run a heavy build here while this Mac is busy and an allowed Mac is clearly less
    /// busy (as last seen), at most every 15 minutes per session.
    static func offloadHint(_ cmd: String, kind: String, session: String?) -> String? {
        guard let session, !session.isEmpty, kind == "gradle" || kind == "xcodebuild" else { return nil }
        let h = here()
        guard hereIsBusy(h) else { return nil }
        let ios = kind == "xcodebuild"
        let best = load().filter(\.allowed).compactMap { p -> (String, PeerInfo)? in
            guard let s = seen()[p.host], Date().timeIntervalSince(s.at) < 300, s.info.sharing, s.info.busy <= h.busy - margin, !ios || s.info.xcode else { return nil }
            return (p.host, s.info)
        }.min { $0.1.busy < $1.1.busy }
        guard let (host, info) = best else { return nil }
        let file = Rules.dir + "/offload-hints.json"
        var said = FileManager.default.contents(atPath: file).flatMap { try? Leases.decoder.decode([String: Date].self, from: $0) } ?? [:]
        if let last = said[session], Date().timeIntervalSince(last) < 900 { return nil }
        said = said.filter { Date().timeIntervalSince($0.value) < 86400 }; said[session] = Date()
        Rules.write(try? Leases.encoder.encode(said), to: file)
        return "RigWatch: this Mac is busy (CPU \(h.cpu)% of cores, GPU \(h.gpu)%, memory pressure \(Views.pressureName(h.pressure).lowercased())), and \(info.name) (\(host)) is much less busy. "
            + "This command still runs here. For the next heavy \(ios ? "xcodebuild" : "Gradle") build or device test, consider the rigwatch MCP tool run_on_mac with host \(host): "
            + "it runs the command there with \(ios ? "a simulator ($RIGWATCH_SIM_UDID)" : "an emulator (ANDROID_SERIAL)") of its own and copies back the result files you list in artifacts."
    }

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
        remember(host, info)
        return .online(info)
    }

    // MARK: putting RigWatch on another Mac

    /// The build number in a version like "1.9.0 (22)"; 0 when there is none.
    static func build(_ version: String) -> Int {
        guard let open = version.lastIndex(of: "("), let close = version.lastIndex(of: ")"), open < close else { return 0 }
        return Int(version[version.index(after: open)..<close]) ?? 0
    }

    /// RigWatch there is missing, too old to answer, or older than this one.
    static func needsInstall(_ st: Status?) -> Bool {
        switch st {
        case .noRigWatch: return true
        case .online(let i): return AppCopy.ownBuild > 0 && build(i.version) < AppCopy.ownBuild
        default: return false
        }
    }

    /// The app bundle copied to other Macs: the one this process runs from, or the copy in ~/Applications.
    static var ownApp: String? {
        let me = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        if me.hasSuffix(".app") { return me }
        return FileManager.default.fileExists(atPath: AppCopy.copy + "/Contents/MacOS/RigWatch") ? AppCopy.copy : nil
    }

    /// Copies this Mac's RigWatch to ~/Applications there over SSH, so it needs no Homebrew, compiler or network
    /// of its own. A RigWatch open there is restarted on the new one. With `share`, sharing is turned on there.
    /// Returns what RigWatch there reports afterwards.
    static func install(on host: String, share: Bool) throws -> PeerInfo {
        guard let app = ownApp else { throw DeviceManager.Failure(message: "This RigWatch doesn't run from an app bundle, so there is nothing to copy.") }
        let check = Sh.run("/usr/bin/ssh", sshOpts + [host, "uname -m; sw_vers -productVersion"], timeout: 15)
        guard check.code == 0 else { throw DeviceManager.Failure(message: "Could not reach \(host) over SSH: \(check.err.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))") }
        let f = check.out.split(separator: "\n").map(String.init)
        guard f.first == "arm64" else { throw DeviceManager.Failure(message: "\(host) is an \(f.first ?? "unknown") Mac; this RigWatch runs on Apple silicon only.") }
        guard let major = f.dropFirst().first.flatMap({ Int($0.split(separator: ".").first ?? "") }), major >= 14 else {
            throw DeviceManager.Failure(message: "\(host) runs macOS \(f.dropFirst().first ?? "?"); RigWatch needs macOS 14 or later.")
        }
        // Unpacked beside the old one, then swapped in, so a broken copy never replaces a working RigWatch.
        let gui = "'RigWatch.app/Contents/MacOS/RigWatch$'"
        let script = "set -e; D=\"$HOME/Applications\"; mkdir -p \"$D\"; T=$(mktemp -d \"$D/.rigwatch-XXXXXX\"); mkdir \"$T/RigWatch.app\"; "
            + "tar -C \"$T/RigWatch.app\" -xf -; open=0; pgrep -f \(gui) >/dev/null && open=1; "
            + "if [ $open = 1 ]; then pkill -f \(gui) || true; sleep 1; fi; "
            + "rm -rf \"$D/RigWatch.app\"; mv \"$T/RigWatch.app\" \"$D/RigWatch.app\"; rmdir \"$T\"; "
            + "if [ $open = 1 ]; then open \"$D/RigWatch.app\" || true; fi; echo RIGWATCH_INSTALLED"
        let ssh = (["/usr/bin/ssh"] + sshOpts + [host]).map(Rules.quote).joined(separator: " ")
        let copy = Sh.run("/bin/zsh", ["-c", "COPYFILE_DISABLE=1 /usr/bin/tar --no-mac-metadata -C \(Rules.quote(app)) -cf - . | \(ssh) \(Rules.quote(script))"], timeout: 300)
        guard copy.code == 0, copy.out.contains("RIGWATCH_INSTALLED") else {
            throw DeviceManager.Failure(message: "Could not copy RigWatch to \(host): \((copy.err.isEmpty ? copy.out : copy.err).trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))")
        }
        if share {
            let s = Sh.run("/usr/bin/ssh", sshOpts + [host, remote(["share", "on"])], timeout: 20)
            guard s.code == 0 else { throw DeviceManager.Failure(message: "RigWatch is on \(host) now, but turning sharing on there failed: \((s.err.isEmpty ? s.out : s.err).prefix(200))") }
        }
        guard case .online(let info) = probe(host) else { throw DeviceManager.Failure(message: "RigWatch was copied to \(host) but doesn't answer there.") }
        Rules.log("peers: installed RigWatch \(info.version) on \(host)\(share ? ", sharing on" : "")")
        return info
    }

    /// An allowed Mac, made ready to use: a missing or older RigWatch there is installed from this Mac first (a
    /// missing one with sharing turned on, since allowing that Mac was the go-ahead). A failed install is not
    /// tried again for ten minutes.
    static func ready(_ host: String) -> Status {
        let st = probe(host)
        guard needsInstall(st) else { return st }
        installLock.lock()
        let recent = installFailed[host].map { Date().timeIntervalSince($0) < 600 } ?? false
        installLock.unlock()
        if recent { return st }
        do { return .online(try install(on: host, share: st == .noRigWatch)) } catch let f as DeviceManager.Failure {
            Rules.log("peers: could not install RigWatch on \(host): \(f.message)")
            installLock.lock(); installFailed[host] = Date(); installLock.unlock()
        } catch {}
        return st
    }
    private static var installFailed: [String: Date] = [:]
    private static let installLock = NSLock()

    // MARK: on the Mac being used

    /// `RigWatch peer info|hold ...`, run by another Mac over SSH.
    static func main(_ a: [String]) -> Int32 {
        switch a.first {
        case "info": print(String(decoding: (try? JSONEncoder().encode(info())) ?? Data(), as: UTF8.self)); return 0
        case "hold": return hold(Array(a.dropFirst()))
        case "run": return run(Array(a.dropFirst()))
        case "install" where a.count >= 2:
            do { let i = try install(on: a[1], share: a.contains("--share")); print("RigWatch \(i.version) on \(i.name), sharing \(i.sharing ? "on" : "off")"); return 0 }
            catch let f as DeviceManager.Failure { Rules.say(f.message); return 1 } catch { Rules.say("\(error)"); return 1 }
        case "share" where a.count == 2 && ["on", "off"].contains(a[1]):
            var s = RuleSettings.load(); s.shareDevices = a[1] == "on"; s.save()
            Rules.log("peers: sharing turned \(a[1]) from another Mac"); print("sharing \(a[1])"); return 0
        default: Rules.say("usage: RigWatch peer info | peer install HOST [--share] | peer share on|off | peer hold --platform android [--name N] [--session S] [--purpose P] [--minutes M] [--from HOST]"); return 2
        }
    }

    static func info() -> PeerInfo {
        let s = RuleSettings.load(), devs = DeviceManager.running(), leases = Leases.live()
        func row(_ d: Device) -> PeerDevice { PeerDevice(id: d.id, name: d.name, free: d.claim == nil && !leases.contains { $0.covers(d) }) }
        var l = [Double](repeating: 0, count: 3); getloadavg(&l, 3)
        return PeerInfo(name: localName, version: AppCopy.ownVersion, sharing: s.shareDevices, cores: ProcessInfo.processInfo.activeProcessorCount,
                        memGB: Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824, pressure: Rules.pressure(), load: l[0],
                        emulators: devs.filter { $0.kind == .emulator }.map(row), simulators: devs.filter { $0.kind == .simulator }.map(row),
                        avds: DeviceManager.avds(), xcode: FileManager.default.fileExists(atPath: "/Applications/Xcode.app"), gpu: gpuNow())
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
        // A simulator (iOS) or an emulator (Android) of this Mac's own for the run, shut down afterwards if booted for it.
        var leased: [String] = []
        defer { for id in leased { _ = try? DeviceManager.release(id, shutdown: nil) } }
        for (flag, platform, kind, env) in [("--simulator", "ios", "simulator", "RIGWATCH_SIM_UDID"), ("--emulator", "android", "emulator", "ANDROID_SERIAL")] where a.contains(flag) {
            do {
                let g = try DeviceManager.acquire(platform: platform, want: arg("--name"), minutes: 120, purpose: "build from \(from)", headless: true, virtualOnly: true, where: "local")
                guard let id = g["id"] as? String else { return 1 }
                leased.append(id); setenv(env, id, 1)
                Rules.say("RigWatch on \(localName): \(kind) \(g["name"] ?? "") \(id) for this run (\(env))")
            } catch let f as DeviceManager.Failure { Rules.say("RigWatch on \(localName): no \(kind): \(f.message)"); return 1 } catch { return 1 }
        }
        guard FileManager.default.changeCurrentDirectoryPath(dir) else { Rules.say("RigWatch on \(localName): no folder \(dir)"); return 1 }
        fixSdkDir(dir)
        // Through this Mac's own queue, so a build from another Mac waits its turn like any other.
        let kind = Rules.classify(cmd) ?? "xcodebuild"
        return Rules.run(["--kind", kind, "--", "/bin/zsh", "-lc", cmd])
    }

    /// local.properties came from the other Mac: its sdk.dir points at that Mac's Android SDK. Point it at this one's.
    static func fixSdkDir(_ dir: String) {
        let f = dir + "/local.properties"
        guard let text = try? String(contentsOfFile: f, encoding: .utf8), let sdk = DeviceManager.sdkRoot else { return }
        var changed = false
        let lines = text.components(separatedBy: "\n").map { line -> String in
            guard line.hasPrefix("sdk.dir="), !FileManager.default.fileExists(atPath: String(line.dropFirst(8))) else { return line }
            changed = true; return "sdk.dir=" + sdk
        }
        if changed { try? lines.joined(separator: "\n").write(toFile: f, atomically: true, encoding: .utf8) }
    }

    // MARK: on the Mac using it

    /// Copies a worktree to an allowed Mac, runs a command there (with a simulator of its own if asked) and copies
    /// result files back. Returns the exit code, the end of the output and what came back.
    static func runRemote(path: String, command: String, host want: String?, simulator: Bool, emulator: Bool = false, artifacts: [String], session: String) throws -> [String: Any] {
        let allowed = load().filter(\.allowed).filter { want == nil || $0.host == want }
        guard !allowed.isEmpty else { throw DeviceManager.Failure(message: want.map { "\($0) is not an allowed Mac (Device Manager page)." } ?? "No other Mac is allowed (Device Manager page).") }
        var ranked: [(Peer, PeerInfo)] = []
        for p in allowed { if case .online(let i) = ready(p.host), i.sharing, i.xcode || !simulator, !emulator || !i.avds.isEmpty || i.emulators.contains(where: \.free) { ranked.append((p, i)) } }
        ranked.sort { $0.1.busy < $1.1.busy }
        guard let (peer, info) = ranked.first else { throw DeviceManager.Failure(message: "No allowed Mac is online, sharing\(simulator ? " and has Xcode" : "")\(emulator ? " and has an Android emulator" : "") right now.") }
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
        if emulator { args.append("--emulator") }
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
        return ["mac": "\(info.name) (\(host))", "busy_there_before": String(format: "%.2f", info.busy), "exit_code": r.code, "copied_worktree_in_s": Int(copied), "ran_in_s": Int(Date().timeIntervalSince(t0) - copied),
                "artifacts_back": back, "output_tail": out]
    }

    /// The SSH connection that holds a remote emulator (its stdin is the hold) and its control socket.
    private static var holds: [String: (proc: Process, stdin: Pipe, control: String)] = [:]
    private static let holdsLock = NSLock()

    /// Leases an emulator on the least busy allowed Mac and tunnels its adb port here. The returned device id is
    /// an adb serial on this Mac ("127.0.0.1:PORT").
    /// With `below`, only a Mac at least `margin` less busy than that counts (offloading from a busy Mac).
    static func acquireRemote(want: String?, minutes: Int, purpose: String, session: String, below: Double? = nil) throws -> (id: String, name: String, host: String, booted: Bool) {
        let allowed = load().filter(\.allowed)
        guard !allowed.isEmpty else { throw DeviceManager.Failure(message: "No other Mac is allowed (Device Manager page).") }
        var ranked: [(Peer, PeerInfo)] = []
        for p in allowed { if case .online(let i) = ready(p.host), i.sharing, !i.avds.isEmpty || i.emulators.contains(where: \.free), below.map({ i.busy <= $0 - margin }) ?? true { ranked.append((p, i)) } }
        ranked.sort { $0.1.busy < $1.1.busy }
        guard !ranked.isEmpty else { throw DeviceManager.Failure(message: below == nil ? "No allowed Mac is online and sharing its emulators right now." : "No allowed Mac sharing its emulators is clearly less busy than this one right now.") }
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
