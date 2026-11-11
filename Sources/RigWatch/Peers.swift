import Darwin
import Foundation
import IOKit
import CryptoKit

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
    var home: String?              // its home folder (where copies of other Macs' worktrees live), from RigWatch 1.11
    var cpuNow: Double?            // share of all cores in use when asked, from RigWatch 1.11
    var memFree: Int?              // free memory %, from RigWatch 1.11
    var busy: Double { Peers.busy(cpu: max(cpuNow ?? 0, load / Double(max(1, cores))), gpu: gpu ?? 0, memFree: memFree ?? 100, pressure: pressure) }
}
struct PeerDevice: Codable, Equatable { var id: String, name: String, free: Bool }

enum Peers {
    static let file = Rules.dir + "/peers.json"

    // MARK: how busy a Mac is

    /// 0 when idle, about 1 when flat out. CPU is the higher of the share of all cores in use right now and the
    /// 1-minute load per core (it lags, but counts work waiting for a core). The GPU counts only when it is nearly
    /// flat out (90% or more). Memory adds 0.5 when free memory is under the limit or macOS warns of pressure, and 1
    /// when pressure is critical. Offloading in balanced mode needs another Mac at least `margin` less busy, so a
    /// near tie doesn't send work back and forth.
    static func busy(cpu: Double, gpu: Int, memFree: Int, pressure: Int32) -> Double {
        max(cpu, gpu >= 90 ? Double(gpu) / 100 : 0) + (pressure >= 4 ? 1 : pressure >= 2 || memFree < limits.memFreeMin ? 0.5 : 0)
    }
    static let margin = 0.25
    /// The Rules page's limits, read once per process.
    static let limits = RuleSettings.load()
    /// This Mac is busy enough that its work should go to another Mac if one can take it.
    static var busyAt: Double { limits.busyAt }

    /// Share of all cores in use, over a quarter of a second.
    static func cpuNow() -> Double {
        func ticks() -> (busy: Double, all: Double) {
            var info = host_cpu_load_info()
            var n = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
            _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &n) } }
            let t = info.cpu_ticks, user = Double(t.0), sys = Double(t.1), idle = Double(t.2), nice = Double(t.3)
            return (user + sys + nice, user + sys + idle + nice)
        }
        let a = ticks(); usleep(250_000); let b = ticks()
        let all = b.all - a.all
        return all > 0 ? (b.busy - a.busy) / all : 0
    }
    /// Free memory %, as macOS counts it for memory pressure.
    static func memFreeNow() -> Int {
        var v: Int32 = 100, n = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_level", &v, &n, nil, 0)
        return Int(v)
    }

    static func gpuNow() -> Int {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
        defer { IOObjectRelease(svc) }
        let st = IORegistryEntryCreateCFProperty(svc, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any]
        return st?["Device Utilization %"] as? Int ?? 0
    }

    struct Load { var busy: Double, pressure: Int32, cpu: Int, gpu: Int, memFree: Int }
    static func here() -> Load {
        var l = [Double](repeating: 0, count: 3); getloadavg(&l, 3)
        let cores = ProcessInfo.processInfo.activeProcessorCount, p = Rules.pressure(), g = gpuNow(), m = memFreeNow()
        let cpu = max(cpuNow(), l[0] / Double(max(1, cores)))
        // RIGWATCH_BUSY_HERE stands in for this Mac's load (used to test offloading on one Mac).
        let forced = ProcessInfo.processInfo.environment["RIGWATCH_BUSY_HERE"].flatMap(Double.init)
        return Load(busy: forced ?? busy(cpu: cpu, gpu: g, memFree: m, pressure: p), pressure: p, cpu: Int(100 * cpu), gpu: g, memFree: m)
    }
    /// Overloaded: CPU (or a flat-out GPU) at the Rules page's limit, free memory under its limit, or memory pressure.
    static func hereIsBusy(_ h: Load) -> Bool { h.pressure >= 2 || h.memFree < limits.memFreeMin || h.busy >= busyAt }

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
        var lines = ["load here: busy \(String(format: "%.2f", h.busy)) (CPU \(h.cpu)% of cores, \(h.memFree)% memory free, GPU \(h.gpu)%, memory pressure \(Views.pressureName(h.pressure).lowercased()))\(hereIsBusy(h) ? " - overloaded: builds go to another Mac that can take them" : "")"]
        for p in load() where p.allowed {
            guard let s = seen[p.host], Date().timeIntervalSince(s.at) < 600 else { lines.append("\(p.host): not checked lately"); continue }
            let i = s.info
            lines.append("\(p.host) (\(i.name)): busy \(String(format: "%.2f", i.busy))\(i.memFree.map { ", \($0)% memory free" } ?? ""), \(i.sharing ? "sharing" : "not sharing"), \(i.emulators.filter(\.free).count) free emulators, \(i.avds.count) AVDs\(i.xcode ? ", Xcode" : ""), checked \(Int(Date().timeIntervalSince(s.at) / 60)) min ago")
        }
        if lines.count == 1 { lines.append("other Macs: none allowed") }
        return lines.joined(separator: "\n")
    }

    /// Said to a session about to run a heavy build here while this Mac is busy and an allowed Mac is clearly less
    /// busy (as last seen), at most every 15 minutes per session.
    static func offloadHint(_ cmd: String, kind: String, session: String?) -> String? {
        guard let session, !session.isEmpty, kind == "gradle" || kind == "xcodebuild" else { return nil }
        let st = RuleSettings.load()
        if st.offloadBuilds && st.queueBuilds { return nil }   // builds go to a less busy Mac by themselves
        let h = here()
        guard hereIsBusy(h) else { return nil }
        let ios = kind == "xcodebuild"
        let allowed = load().filter(\.allowed)
        guard !allowed.isEmpty else { return nil }
        let fresh = seen()
        if !allowed.contains(where: { fresh[$0.host].map { Date().timeIntervalSince($0.at) < 300 } ?? false }) {
            // Nothing recent to go on: ask the other Macs in the background (no wait here); the hint comes with a later build.
            startRefresh(); return nil
        }
        let best = allowed.compactMap { p -> (String, PeerInfo)? in
            guard let s = fresh[p.host], Date().timeIntervalSince(s.at) < 300, s.info.sharing, s.info.busy <= h.busy - margin, !ios || s.info.xcode else { return nil }
            return (p.host, s.info)
        }.min { $0.1.busy < $1.1.busy }
        guard let (host, info) = best else { return nil }
        let file = Rules.dir + "/offload-hints.json"
        var said = FileManager.default.contents(atPath: file).flatMap { try? Leases.decoder.decode([String: Date].self, from: $0) } ?? [:]
        if let last = said[session], Date().timeIntervalSince(last) < 900 { return nil }
        said = said.filter { Date().timeIntervalSince($0.value) < 86400 }; said[session] = Date()
        Rules.write(try? Leases.encoder.encode(said), to: file)
        return "RigWatch: this Mac is busy (CPU \(h.cpu)% of cores, \(h.memFree)% memory free, GPU \(h.gpu)%, memory pressure \(Views.pressureName(h.pressure).lowercased())), and \(info.name) (\(host)) is much less busy. "
            + "This command still runs here. For the next heavy \(ios ? "xcodebuild" : "Gradle") build or device test, consider the rigwatch MCP tool run_on_mac with host \(host): "
            + "it runs the command there with \(ios ? "a simulator ($RIGWATCH_SIM_UDID)" : "an emulator (ANDROID_SERIAL)") of its own and copies back the result files you list in artifacts."
    }

    /// The last failed attempt to use each Mac's emulators (shown on the Device Manager page; skipped for 10 minutes).
    struct Failure: Codable { var at: Date; var why: String }
    static let failuresFile = Rules.dir + "/peer-failures.json"
    static func failures() -> [String: Failure] {
        FileManager.default.contents(atPath: failuresFile).flatMap { try? Leases.decoder.decode([String: Failure].self, from: $0) } ?? [:]
    }
    static func noteFailure(_ host: String, _ why: String?) {
        var all = failures()
        guard all[host] != nil || why != nil else { return }
        all[host] = why.map { Failure(at: Date(), why: $0) }
        Rules.write(try? Leases.encoder.encode(all), to: failuresFile)
    }

    // MARK: work this Mac has on other Macs

    /// A run_on_mac in progress, written by the MCP server running it, so the app shows where the work is
    /// without asking any Mac over SSH.
    struct RemoteRun: Codable, Equatable, Identifiable {
        var host: String, mac: String, session: String, command: String, cwd: String
        var phase: String              // copying, running, copying back
        var since: Date
        var pid: Int32, pidStart: UInt64
        var id: String { "\(pid)-\(Int(since.timeIntervalSince1970))" }   // whole seconds: the file keeps no fractions
    }
    static let runsFile = Rules.dir + "/remote-runs.json"
    private static let runsLock = NSLock()

    /// Runs still in progress: one whose MCP server has gone is dropped.
    static func activeRuns() -> [RemoteRun] {
        (FileManager.default.contents(atPath: runsFile).flatMap { try? Leases.decoder.decode([RemoteRun].self, from: $0) } ?? [])
            .filter { ProcSampler.startTime($0.pid) == $0.pidStart }
    }
    static func noteRun(_ r: RemoteRun?, removing id: String? = nil) {
        runsLock.lock(); defer { runsLock.unlock() }
        var all = activeRuns().filter { $0.id != (r?.id ?? id) }
        if let r { all.append(r) }
        Rules.write(try? Leases.encoder.encode(all), to: runsFile)
    }

    /// Asks every allowed Mac how it is, at once, and remembers the answers.
    static func refreshAllowed() {
        let g = DispatchGroup()
        for p in load() where p.allowed { g.enter(); DispatchQueue.global().async { _ = probe(p.host); g.leave() } }
        g.wait()
    }

    /// `RigWatch peer refresh` in the background, at most once every 5 minutes.
    static func startRefresh() {
        let stamp = Rules.dir + "/peer-refresh.stamp"
        if let d = (try? FileManager.default.attributesOfItem(atPath: stamp))?[.modificationDate] as? Date, Date().timeIntervalSince(d) < 300 { return }
        Rules.write(Data(), to: stamp)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0].hasPrefix("/") ? CommandLine.arguments[0] : Bundle.main.executablePath ?? "")
        p.arguments = ["peer", "refresh"]
        p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run()
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
        case "refresh": refreshAllowed(); return 0
        case "sync": return Offload.sync(Array(a.dropFirst()))
        case "exec": return Offload.exec(Array(a.dropFirst()))
        case "plan":
            // `peer plan [--cwd D] -- CMD`: whether and how a build would run on another Mac (for checking the rules).
            guard let sep = a.firstIndex(of: "--") else { return 2 }
            let cwd = a.firstIndex(of: "--cwd").map { a[$0 + 1] } ?? FileManager.default.currentDirectoryPath
            let cmd = a[(sep + 1)...].joined(separator: " "), kind = Rules.classify(cmd) ?? "?"
            print("command: \(Offload.wrap(cmd) ?? "no build to move")")
            var why = ""
            if let sh = Offload.shape(["/bin/zsh", "-c", cmd], kind: kind, cwd: cwd, why: &why) {
                print("moves: \(kind) root=\(sh.root) rel=\(sh.rel)\(sh.simulator ? " simulator" : "")\(sh.emulator ? " emulator" : "")\(sh.device.map { " name=" + $0 } ?? "")")
                print("  there: \(sh.cmd)")
                for b in sh.back { print("  back: \(b.from) -> \(b.to)") }
                if sh.gradleResults { print("  back: build/outputs, reports, test-results") }
                if !sh.keep.isEmpty { print("  keep: \(sh.keep.joined(separator: ", "))") }
            } else { print("stays here: \(why)") }
            return 0
        case "authorize": return authorize(Array(a.dropFirst()))
        case "share" where a.count == 2 && ["on", "off"].contains(a[1]):
            var s = RuleSettings.load(); s.shareDevices = a[1] == "on"; s.save()
            Rules.log("peers: sharing turned \(a[1]) from another Mac"); print("sharing \(a[1])"); return 0
        default: Rules.say("usage: RigWatch peer info | peer refresh | peer install HOST [--share] | peer share on|off | peer hold --platform android [--name N] [--session S] [--purpose P] [--minutes M] [--from HOST]"); return 2
        }
    }

    static func info() -> PeerInfo {
        let s = RuleSettings.load(), devs = DeviceManager.running(), leases = Leases.live()
        func row(_ d: Device) -> PeerDevice { PeerDevice(id: d.id, name: d.name, free: d.claim == nil && !leases.contains { $0.covers(d) }) }
        var l = [Double](repeating: 0, count: 3); getloadavg(&l, 3)
        return PeerInfo(name: localName, version: AppCopy.ownVersion, sharing: s.shareDevices, cores: ProcessInfo.processInfo.activeProcessorCount,
                        memGB: Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824, pressure: Rules.pressure(), load: l[0],
                        emulators: devs.filter { $0.kind == .emulator }.map(row), simulators: devs.filter { $0.kind == .simulator }.map(row),
                        avds: DeviceManager.avds(), xcode: FileManager.default.fileExists(atPath: "/Applications/Xcode.app"), gpu: gpuNow(), home: Sh.home, cpuNow: cpuNow(), memFree: memFreeNow())
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
        let kind = arg("--kind") ?? Rules.classify(cmd) ?? "xcodebuild"
        if kind == "gradle" { fixJava() } else { fixXcode() }
        // The Mac that sent it hangs up when its command is stopped: stop the build here too.
        if a.contains("--watch-stdin") {
            Thread.detachNewThread { _ = FileHandle.standardInput.readDataToEndOfFile(); kill(getpid(), SIGTERM) }
        }
        // Through this Mac's own queue (never on to a third Mac), with this Mac's thread count.
        let s = RuleSettings.load()
        return Rules.run(["--here", "--kind", kind, "--", "/bin/zsh", "-lc", Rules.withThreads(cmd, kind: kind, n: Rules.threads(s))])
    }

    // MARK: letting the other Mac's adb in

    /// The fingerprint Android shows for an adb public key ("QAAAA… user@host"): MD5 of the key, as AB:CD:….
    static func adbFingerprint(_ pub: String) -> String? {
        guard let b64 = pub.split(separator: " ").first, let raw = Data(base64Encoded: String(b64)) else { return nil }
        return Insecure.MD5.hash(data: raw).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// `peer authorize --serial S --key PUB --from MAC`: an emulator here trusts only this Mac's adb key, so the
    /// other Mac's adb gets "unauthorized" and Android asks "Allow USB debugging?" inside the emulator. This answers
    /// it (Always allow) — only for an emulator leased here to that Mac, only while this Mac shares its devices, and
    /// only when the fingerprint Android shows is the other Mac's key.
    static func authorize(_ a: [String]) -> Int32 {
        func arg(_ k: String) -> String? { a.firstIndex(of: k).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil } }
        func fail(_ m: String) -> Int32 { Rules.say("RigWatch on \(localName): \(m)"); Rules.log("peers: did not let \(arg("--from") ?? "?") in: \(m)"); return 1 }
        guard RuleSettings.load().shareDevices else { return fail("this Mac doesn't share its devices") }
        guard let serial = arg("--serial"), serial.hasPrefix("emulator-"), let key = arg("--key"), let from = arg("--from"), let want = adbFingerprint(key) else {
            return fail("usage: peer authorize --serial emulator-N --key PUBKEY --from MAC")
        }
        guard Leases.live().contains(where: { $0.device == serial && $0.session.hasPrefix(from + "/") }) else { return fail("\(serial) is not leased to \(from)") }
        let adb = Sh.adb
        for _ in 0..<10 {
            _ = Sh.run(adb, ["-s", serial, "shell", "uiautomator", "dump", "/sdcard/rigwatch-ui.xml"], timeout: 20)
            let xml = Sh.run(adb, ["-s", serial, "shell", "cat", "/sdcard/rigwatch-ui.xml"], timeout: 10).out
            _ = Sh.run(adb, ["-s", serial, "shell", "rm", "-f", "/sdcard/rigwatch-ui.xml"], timeout: 10)
            guard xml.contains("android:id/button1"), let shown = Rules.matches(fingerprint, xml).first else { usleep(1_000_000); continue }
            guard shown == want else { return fail("the emulator asks about key \(shown), not \(from)'s (\(want)); left unanswered") }
            if let box = node(xml, "android:id/alwaysUse"), !box.checked { _ = Sh.run(adb, ["-s", serial, "shell", "input", "tap", "\(box.x)", "\(box.y)"], timeout: 10) }
            guard let ok = node(xml, "android:id/button1") else { return fail("no Allow button") }
            _ = Sh.run(adb, ["-s", serial, "shell", "input", "tap", "\(ok.x)", "\(ok.y)"], timeout: 10)
            Rules.log("peers: let \(from)'s adb (key \(want)) into \(serial)")
            print("authorized"); return 0
        }
        return fail("no \"Allow USB debugging?\" prompt showed up on \(serial)")
    }
    static let fingerprint = try! NSRegularExpression(pattern: #"(?:[0-9A-F]{2}:){15}[0-9A-F]{2}"#)

    /// The centre of a uiautomator node by resource id, and whether it is checked.
    static func node(_ xml: String, _ id: String) -> (x: Int, y: Int, checked: Bool)? {
        guard let r = xml.range(of: "resource-id=\"\(id)\"") else { return nil }
        let start = xml[..<r.lowerBound].range(of: "<node", options: .backwards)?.lowerBound ?? r.lowerBound
        let tag = xml[start...].prefix { $0 != ">" }
        guard let b = tag.range(of: #"bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]""#, options: .regularExpression) else { return nil }
        let n = tag[b].split { !$0.isNumber }.compactMap { Int($0) }
        guard n.count == 4 else { return nil }
        return ((n[0] + n[2]) / 2, (n[1] + n[3]) / 2, tag.contains("checked=\"true\""))
    }

    /// A login shell over SSH often has no Java (Android Studio brings its own): point Gradle at that one.
    static func fixJava() {
        guard ProcessInfo.processInfo.environment["JAVA_HOME"] == nil, Sh.run("/usr/libexec/java_home", [], timeout: 10).code != 0 else { return }
        for j in ["/Applications/Android Studio.app/Contents/jbr/Contents/Home", "/Applications/Android Studio.app/Contents/jre/Contents/Home"]
        where FileManager.default.fileExists(atPath: j + "/bin/java") { setenv("JAVA_HOME", j, 1); return }
    }

    /// xcode-select pointing at the Command Line Tools has no xcodebuild for apps: use Xcode itself.
    static func fixXcode() {
        guard ProcessInfo.processInfo.environment["DEVELOPER_DIR"] == nil, FileManager.default.fileExists(atPath: "/Applications/Xcode.app"),
              Sh.run("/usr/bin/xcode-select", ["-p"], timeout: 10).out.contains("CommandLineTools") else { return }
        setenv("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer", 1)
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
        let dest = Offload.copyDir(path)
        let ssh = (["/usr/bin/ssh"] + sshOpts).joined(separator: " ")
        let t0 = Date()
        var run = RemoteRun(host: host, mac: info.name, session: session, command: command, cwd: path, phase: "copying", since: t0,
                            pid: getpid(), pidStart: ProcSampler.startTime(getpid()) ?? 0)
        noteRun(run)
        defer { noteRun(nil, removing: run.id) }
        // Build outputs stay behind; everything else, node_modules and Pods included, goes (only changes, after the first time).
        let sync = Offload.copy(path, to: host, keep: artifacts)
        guard sync.code == 0 else { throw DeviceManager.Failure(message: "Could not copy the worktree to \(host): \(sync.err.prefix(240))") }
        Offload.noteCopy(host, path)
        let copied = Date().timeIntervalSince(t0)
        // Result files come fresh from this run: a stale result bundle there would fail xcodebuild or come back as new.
        if !artifacts.isEmpty {
            _ = Sh.run("/usr/bin/ssh", sshOpts + [host, "cd " + Rules.quote(dest) + " && rm -rf " + artifacts.map(Rules.quote).joined(separator: " ")], timeout: 60)
        }
        var args = ["run", "--dir", "~/" + dest, "--session", session, "--from", localName]
        if simulator { args.append("--simulator") }
        if emulator { args.append("--emulator") }
        run.phase = "running"; noteRun(run)
        let started = Date()
        let r = Sh.run("/usr/bin/ssh", sshOpts + ["-T", host, remote(args + ["--", command])], timeout: 4 * 3600)
        run.phase = "copying back"; noteRun(run)
        var back: [String] = []
        for rel in artifacts {
            let local = path + "/" + rel
            try? FileManager.default.removeItem(atPath: local)
            try? FileManager.default.createDirectory(atPath: (local as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            if Sh.run("/usr/bin/rsync", ["-az", "-e", ssh, host + ":" + dest + "/" + rel, (local as NSString).deletingLastPathComponent + "/"], timeout: 900).code == 0 { back.append(rel) }
        }
        Rules.log("peers: ran on \(host) for session \(session) (exit \(r.code)): \(command.prefix(120))")
        let kind = Rules.classify(command) ?? (simulator ? "xcodebuild" : "gradle")
        BuildHistory.add(BuildRecord(kind: kind, pool: Rules.pool(kind: kind, cmd: command), cwd: path, cmd: command, session: session,
                                     queuedAt: t0, startedAt: started, endedAt: Date(), waited: started.timeIntervalSince(t0),
                                     overflow: false, forced: false, releasedEarly: false, exit: r.code, host: "\(info.name) (\(host))"))
        let out = (r.out + (r.err.isEmpty ? "" : "\n" + r.err)).split(separator: "\n", omittingEmptySubsequences: false).suffix(150).joined(separator: "\n")
        return ["mac": "\(info.name) (\(host))", "busy_there_before": String(format: "%.2f", info.busy), "exit_code": r.code, "copied_worktree_in_s": Int(copied), "ran_in_s": Int(Date().timeIntervalSince(t0) - copied),
                "artifacts_back": back, "output_tail": out]
    }

    /// The SSH connection that holds a remote emulator (its stdin is the hold) and its control socket.
    private static var holds: [String: (proc: Process, stdin: Pipe, control: String)] = [:]
    static var holding: Bool { holdsLock.lock(); defer { holdsLock.unlock() }; return !holds.isEmpty }
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
            if let f = failures()[p.host], Date().timeIntervalSince(f.at) < 600 { tried.append("\(p.host): skipped, it failed \(Int(Date().timeIntervalSince(f.at) / 60)) min ago (\(f.why))"); continue }
            do { let r = try hold(on: p.host, want: want, minutes: minutes, purpose: purpose, session: session); noteFailure(p.host, nil); return r }
            catch let f as DeviceManager.Failure {
                tried.append("\(p.host): \(f.message)")
                Rules.log("peers: could not use an emulator on \(p.host) for session \(session): \(f.message)")
                // A Mac that can't lend (tunnel, adb, SSH) is skipped for 10 minutes; one that just has nothing free isn't.
                if !f.message.contains("free") && !f.message.contains("leased") && !f.message.contains("doesn't share") { noteFailure(p.host, f.message) }
            }
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
        var ready = false, asked = false, why = "adb could not reach \(id) through the tunnel"
        for _ in 0..<30 {
            if Sh.run(Sh.adb, ["-s", serial, "get-state"], timeout: 5).out.trimmingCharacters(in: .whitespacesAndNewlines) == "device" { ready = true; break }
            // The emulator there trusts only that Mac's adb key: have that Mac let this one's key in, once (Android remembers it).
            if !asked, adbState(serial) == "unauthorized" {
                asked = true
                guard let key = ownAdbKey() else { why = "\(id) there doesn't trust this Mac's adb, and this Mac has no adb key (~/.android/adbkey.pub)"; break }
                let r = Sh.run("/usr/bin/ssh", ["-o", "ControlPath=\(control)", "-T", host, remote(["authorize", "--serial", id, "--key", key, "--from", localName])], timeout: 120)
                guard r.code == 0 else { why = "\(id) there doesn't trust this Mac's adb: \((r.out + r.err).trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))"; break }
                _ = Sh.run(Sh.adb, ["disconnect", serial], timeout: 5); _ = Sh.run(Sh.adb, ["connect", serial], timeout: 15)
            }
            usleep(1_000_000)
        }
        guard ready else { _ = Sh.run(Sh.adb, ["disconnect", serial], timeout: 5); p.terminate(); throw DeviceManager.Failure(message: why) }
        holdsLock.lock(); holds[serial] = (p, inPipe, control); holdsLock.unlock()
        Rules.log("peers: \(id) on \(host) as \(serial) for session \(session)")
        return (serial, "\(j["name"] as? String ?? id) on \(host)", host, j["booted"] as? Bool ?? false)
    }

    /// adb's state for a device: device, unauthorized, offline, or nil when it isn't listed.
    static func adbState(_ serial: String) -> String? {
        for line in Sh.run(Sh.adb, ["devices"], timeout: 10).out.split(separator: "\n") {
            let f = line.split(separator: "\t")
            if f.count == 2, f[0] == serial { return String(f[1]) }
        }
        return nil
    }
    /// This Mac's adb public key (the base64 part), which an emulator on another Mac is asked to trust.
    static func ownAdbKey() -> String? {
        let dir = ProcessInfo.processInfo.environment["ANDROID_USER_HOME"] ?? Sh.home + "/.android"
        return (try? String(contentsOfFile: dir + "/adbkey.pub", encoding: .utf8))?.split(separator: " ").first.map(String.init)
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
