import CryptoKit
import Darwin
import Foundation

/// What the Rules page sets. JSON, so the hook, the build queue and the clean-up agent (separate
/// processes) read the same values the page writes.
struct RuleSettings: Codable, Equatable {
    var paused = false
    var queueBuilds = true
    var androidBuilds = 2        // builds at once in each pool: an Android build never waits behind an iOS one
    var iosBuilds = 1
    var maxWaitMinutes = 10      // a build never waits longer: then it starts anyway, at background priority
    var lowerOutside = true      // builds outside the queue, and Gradle's daemons, run at lower priority
    var buildThreads = max(2, ProcessInfo.processInfo.activeProcessorCount / 3)
    var physicalFirst = true
    var limitVirtual = true      // at most this many emulators and simulators running at once
    var maxEmulators = 2
    var maxSimulators = 2
    var reapDevices = true
    var deviceIdleMinutes = 30
    var deviceIdleWithPhoneMinutes = 10
    var reapWorktrees = true
    var worktreeIdleHours = 24
    var reapDerivedData = true
    /// Folders the clean-up never touches: no worktree, build output or DerivedData of a project in them.
    var neverClean: [String] = []

    /// True for a path inside one of the never-clean folders (`~` allowed).
    func protects(_ path: String) -> Bool {
        neverClean.contains { f in
            let f = (f.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
            return !f.isEmpty && (path == f || path.hasPrefix(f.hasSuffix("/") ? f : f + "/"))
        }
    }

    /// Keys missing from the file keep their defaults, so a file from an older version still loads.
    static func load() -> RuleSettings {
        let def = RuleSettings()
        guard let d = FileManager.default.contents(atPath: Rules.settingsFile),
              let saved = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let enc = try? JSONEncoder().encode(def),
              var base = (try? JSONSerialization.jsonObject(with: enc)) as? [String: Any] else { return def }
        base.merge(saved) { _, new in new }
        if saved["androidBuilds"] == nil, let n = saved["parallelBuilds"] { base["androidBuilds"] = n }   // before the split: one shared count
        return (try? JSONSerialization.data(withJSONObject: base)).flatMap { try? JSONDecoder().decode(RuleSettings.self, from: $0) } ?? def
    }
    func save() { Rules.write(try? JSONEncoder().encode(self), to: Rules.settingsFile) }
}

/// One command holding or waiting for a build slot.
struct BuildJob: Codable, Identifiable {
    let pid: Int32
    let start: UInt64            // with pid, names one process run
    let kind: String             // gradle, xcodebuild, install
    let weight: Int
    let cwd: String
    let cmd: String
    var state: String            // waiting, running
    var since: Date
    var session: String?         // the agent session that started it
    var queuedAt: Date?
    var overflow: Bool?          // started after waiting the longest allowed, at background priority
    var force: Bool?             // "Start now" from the Builds page
    var id: Int32 { pid }
    var alive: Bool { ProcSampler.startTime(pid) == start }
}

struct ReapAction: Codable, Identifiable, Hashable {
    var kind: String             // Shut down, Remove worktree, Strip build output, Prune, Delete DerivedData
    var target: String
    var key: String              // device id or path
    var detail: String
    var bytes: Int64? = nil      // memory for a device, disk for the rest
    var result: String? = nil    // set once applied
    var outcome: String? = nil   // done, kept (a safety check stopped it) or failed; nil in reports from older versions
    var id: String { kind + key }
    var failed: Bool { outcome == "failed" }
}

struct ReapReport: Codable {
    var at = Date()
    var applied = false
    var notes: [String] = []
    var actions: [ReapAction] = []
    var kept: [String] = []      // checked and left alone, with why

    var text: String {
        var out = [(applied ? "APPLIED" : "DRY RUN (reap --apply acts)") + " · " + Rules.stamp.string(from: at)]
        out += notes.map { "  note: " + $0 }
        for a in actions {
            var line = "  \(a.kind): \(a.target) · \(a.detail)"
            if let b = a.bytes { line += " (\(Fmt.bytes(b)))" }
            if let res = a.result { line += " -> " + res }
            out.append(line)
        }
        if actions.isEmpty { out.append("  nothing to do") }
        out += kept.map { "  kept: " + $0 }
        return out.joined(separator: "\n")
    }
}

/// Keeps one Mac usable while many agent sessions build on it. A Claude Code hook sends heavy
/// commands through `RigWatch run`, a machine-wide build queue; booting an emulator or simulator
/// is refused while a physical device is connected; and a LaunchAgent (`RigWatch reap --apply`)
/// shuts down idle emulators and simulators and cleans up idle worktrees and orphaned DerivedData.
enum Rules {
    static let dir = Sh.home + "/Library/Application Support/RigWatch"
    static let settingsFile = dir + "/rules.json", jobsFile = dir + "/jobs.json", pinsFile = dir + "/pins.json"
    static let reportFile = dir + "/last-reap.json", logFile = dir + "/actions.log"
    static let touchDir = dir + "/touch"
    static let weights = ["gradle": 2, "xcodebuild": 2, "install": 1]   // a slot is 2: one heavy build or two installs
    static let agentLabel = "dev.rigwatch.reaper"
    static let agentPlist = Sh.home + "/Library/LaunchAgents/\(agentLabel).plist"
    static let claudeSettings = Sh.home + "/.claude/settings.json"
    static let stamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f }()

    static func write(_ data: Data?, to path: String) {
        guard let data else { return }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
    static func mtime(_ p: String) -> Date? { (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date }
    static func isDir(_ p: String) -> Bool { var d: ObjCBool = false; return FileManager.default.fileExists(atPath: p, isDirectory: &d) && d.boolValue }
    static func say(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }

    static func log(_ line: String) {
        let s = stamp.string(from: Date()) + " " + line + "\n"
        guard let h = FileHandle(forWritingAtPath: logFile) else { write(Data(s.utf8), to: logFile); return }
        h.seekToEndOfFile(); h.write(Data(s.utf8)); try? h.close()
    }
    static func logTail(_ n: Int) -> [String] {
        (SessionIndex.tail(logFile, bytes: 40_000) ?? "").split(separator: "\n").suffix(n).reversed().map(String.init)
    }

    // MARK: commands

    private static func rx(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
    static func has(_ r: NSRegularExpression, _ s: String) -> Bool { r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
    static func matches(_ r: NSRegularExpression, _ s: String, group: Int = 0) -> [String] {
        r.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range(at: group), in: s).map { String(s[$0]) } }
    }

    /// Command position: start of a line or after ; & | ( `, optionally behind VAR=x and the runners people
    /// put in front of a build (time, nice, xcrun, env, bundle exec, devbox run, npx, pnpm/yarn exec,
    /// arch -arm64, caffeinate, timeout N). A build tool named inside an argument (grep xcodebuild, echo
    /// gradlew) is not a build.
    static let cmdPos = #"(?:^|[;&|(`\n])\s*(?:(?:[A-Za-z_]\w*=\S*|time|xcrun|env|bundle\s+exec|devbox\s+run|npx|pnpm\s+exec|yarn\s+exec|arch\s+-\w+|caffeinate(?:\s+-\w+)*|timeout\s+\S+|nice(?:\s+-n\s*-?\d+)?)\s+)*"#
    static let heavy: [(kind: String, tool: NSRegularExpression, skip: NSRegularExpression?)] = [
        ("gradle", rx(cmdPos + #"((?:\S*/)?gradlew?)(?=\s|$)"#), rx(#"--stop|--status|--version|\btasks\b|\bdependencies\b"#)),
        ("xcodebuild", rx(cmdPos + #"(xcodebuild)(?=\s|$)"#), rx(#"-list\b|-showBuildSettings|-version\b|-showsdks|-showdestinations"#)),
        ("install", rx(cmdPos + #"(npm\s+(?:ci|install|i)\b|pnpm\s+(?:install|i)\b|pod\s+install\b|yarn(?:\s+install)?(?:\s+--?[\w-]+(?:=\S+)?)*\s*(?=$|[;&|)]))"#), nil),
    ]
    static let boot: [(plat: String, rx: NSRegularExpression)] = [
        ("android", rx(#"(^|[\s;&|/])emulator\s[^;&|]*(-avd\s|@\w)"#)),
        ("ios", rx(#"simctl\s+boot\b|open\s+(-\w+\s+)*-a\s+"?Simulator"#)),
    ]
    static let uses: [(plat: String, rx: NSRegularExpression)] = [
        ("android", rx(#"\badb\b|\bmaestro\b|gradlew\s[^;&|]*install"#)),
        ("ios", rx(#"\bsimctl\b|\bxcodebuild\b|\bmaestro\b|\bdevicectl\b"#)),
    ]
    static let deviceIds = rx(#"emulator-\d+|[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}"#)
    static let deviceTool = rx(#"(?i)mobile|device|emulator|simulator|maestro|adb|android|ios"#)

    static func classify(_ cmd: String) -> String? {
        heavy.first { has($0.tool, cmd) && !($0.skip.map { has($0, cmd) } ?? false) }?.kind
    }

    /// Threads for the next build: the Rules' number at least, more when few builds run, so a build alone on the
    /// Mac isn't held to a third of its cores. Two cores always stay free for everything else.
    static func threads(_ s: RuleSettings) -> Int {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let running = jobs().filter { $0.state == "running" && $0.kind != "install" }.count
        return max(1, min(cores - 2, max(s.buildThreads, (cores - 2) / (running + 1))))
    }

    /// Caps a build's threads: `--max-workers` for Gradle, `-jobs` for xcodebuild, unless the command sets its own.
    static func withThreads(_ cmd: String, kind: String, n: Int) -> String {
        let (flag, present) = kind == "gradle" ? (" --max-workers=\(n)", "--max-workers") : (" -jobs \(n)", "-jobs")
        guard kind != "install", !cmd.contains(present), let t = heavy.first(where: { $0.kind == kind })?.tool,
              let m = t.firstMatch(in: cmd, range: NSRange(cmd.startIndex..., in: cmd)), let r = Range(m.range(at: 1), in: cmd) else { return cmd }
        var c = cmd; c.insert(contentsOf: flag, at: r.upperBound); return c
    }

    static var exe: String { Bundle.main.executablePath ?? CommandLine.arguments[0] }

    enum Wrap { case leave, deny(String), wrap(String, String) }

    static func wrap(_ cmd: String, _ s: RuleSettings) -> Wrap {
        noteUse(cmd)
        if s.limitVirtual, let why = capBlock(cmd, s) { return .deny(why) }
        if s.physicalFirst, let why = bootBlock(cmd) { return .deny(why) }
        noteBoot(cmd)
        guard s.queueBuilds, !cmd.contains(" run --kind "), let kind = classify(cmd) else { return .leave }
        return .wrap("\(quote(exe)) run --kind \(kind) -- /bin/zsh -c \(quote(withThreads(cmd, kind: kind, n: threads(s))))", kind)
    }

    /// Records that a command used a platform's devices, and which ones it named, for the idle check.
    static func noteUse(_ cmd: String) {
        for u in uses where has(u.rx, cmd) { touch(u.plat) }
        matches(deviceIds, cmd).forEach(touch)
    }

    /// The AVD or simulator an agent's boot command names, recorded so the clean-up knows an agent started it.
    static let bootNames = rx(#"-avd\s+["']?([^"'\s;&|]+)|(?:^|\s)@([\w.-]+)|simctl\s+boot\s+(?:"([^"]+)"|'([^']+)'|([^\s;&|]+))"#)
    static func noteBoot(_ cmd: String) {
        for b in boot where has(b.rx, cmd) {
            for m in bootNames.matches(in: cmd, range: NSRange(cmd.startIndex..., in: cmd)) {
                for g in 1..<m.numberOfRanges { if let r = Range(m.range(at: g), in: cmd) { touch("boot-" + cmd[r]) } }
            }
        }
    }
    /// True when an agent's boot command named this device within five minutes of it starting.
    static func agentBooted(_ d: Device) -> Bool {
        guard let started = d.started else { return false }
        return [d.id, d.name].contains { k in touched("boot-" + k).map { abs(started.timeIntervalSince($0)) < 300 } ?? false }
    }

    /// The cap on running virtual devices of a platform, or nil when there is none.
    static func virtualCap(_ plat: String, _ s: RuleSettings) -> Int? {
        s.limitVirtual ? max(1, plat == "ios" ? s.maxSimulators : s.maxEmulators) : nil
    }

    /// Refuses a boot command once as many emulators or simulators run as the Rules allow. Unlike
    /// "physical devices first" there is no override: the cap is the most the Mac should carry.
    static func capBlock(_ cmd: String, _ s: RuleSettings) -> String? {
        for b in boot where has(b.rx, cmd) {
            guard let cap = virtualCap(b.plat, s) else { continue }
            let (_, virt) = devices(b.plat)
            if virt.count >= cap {
                let kind = b.plat == "ios" ? "simulator" : "emulator"
                return "\(virt.count == 1 ? "A \(kind) already runs" : "\(virt.count) \(kind)s already run") on this machine (\(virt.map { "\($0.name) \($0.id)" }.joined(separator: ", "))), the most RigWatch's rules allow. " +
                    "Use one of them (the rigwatch MCP tool acquire_device gives you a free one), or wait until one is released; don't boot another."
            }
        }
        return nil
    }

    static func bootBlock(_ cmd: String) -> String? {
        guard !cmd.contains("RIGWATCH_VIRTUAL=1") else { return nil }
        for b in boot where has(b.rx, cmd) {
            let (phys, virt) = devices(b.plat)
            if !phys.isEmpty {
                return "A physical \(b.plat == "ios" ? "iPhone or iPad" : "Android device") is connected (\(phys.joined(separator: ", "))). Use it instead of booting a virtual one. If a virtual device is really required, put RIGWATCH_VIRTUAL=1 in front of the command, or ask RigWatch for one with the rigwatch MCP tool acquire_device."
            }
            if !virt.isEmpty {
                return "\(virt.map { "\($0.name) (\($0.id))" }.joined(separator: ", ")) is already running on this machine. Reuse it instead of booting another, or ask for a free device with the rigwatch MCP tool acquire_device, which leases it to you; put RIGWATCH_VIRTUAL=1 in front of the command only if a second one is essential."
            }
        }
        return nil
    }

    /// Physical devices (names) and running virtual devices of one platform.
    static func devices(_ plat: String, procs: [Proc]? = nil) -> (phys: [String], virt: [Device]) {
        let ds = DeviceSampler().sample(procs: procs ?? ProcSampler().sample(), deep: false)
        if plat == "ios" { return (iPhones(), ds.filter { $0.kind == .simulator }) }
        return (ds.filter { $0.kind == .phone && $0.state == "device" }.map(\.name), ds.filter { $0.kind == .emulator })
    }

    /// Connected iPhones and iPads, from devicectl (Xcode 15 and later).
    static func iPhones() -> [String] {
        let f = NSTemporaryDirectory() + "rigwatch-devicectl-\(getpid()).json"
        defer { try? FileManager.default.removeItem(atPath: f) }
        _ = Sh.run("/usr/bin/xcrun", ["devicectl", "list", "devices", "-j", f], timeout: 30)
        guard let d = FileManager.default.contents(atPath: f), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let devs = (j["result"] as? [String: Any])?["devices"] as? [[String: Any]] else { return [] }
        return devs.compactMap { x in
            let hw = x["hardwareProperties"] as? [String: Any] ?? [:], cp = x["connectionProperties"] as? [String: Any] ?? [:]
            guard hw["platform"] as? String == "iOS", hw["reality"] as? String != "virtual",
                  cp["tunnelState"] as? String == "connected" || cp["transportType"] as? String == "wired" else { return nil }
            return (x["deviceProperties"] as? [String: Any])?["name"] as? String ?? hw["udid"] as? String ?? "iPhone"
        }
    }

    // MARK: builds outside the queue

    /// A build RigWatch can see running that did not go through `RigWatch run`, and the likely reason.
    struct OutsideBuild: Identifiable {
        let pid: Int32, kind: String, cwd: String?, session: String?, since: Date?, cpu: Double, reason: String
        var id: Int32 { pid }
    }

    /// xcodebuild and Gradle builds (the wrapper's client, not its long-lived daemon) with no
    /// `RigWatch run` above them, from this user's processes.
    static func outsideQueue(_ procs: [Proc]) -> [OutsideBuild] {
        let byPid = Dictionary(uniqueKeysWithValues: procs.map { ($0.pid, $0) })
        let installed = mtime(dir + "/installed"), hook = hookInstalled()
        func ancestors(_ p: Proc) -> [Proc] {
            var out: [Proc] = [], x = p.ppid
            while x > 1, out.count < 40, let q = byPid[x] { out.append(q); x = q.ppid }
            return out
        }
        return procs.compactMap { p -> OutsideBuild? in
            guard p.isOwn else { return nil }
            let a = p.args.joined(separator: " ")
            let kind = p.name == "xcodebuild" ? "xcodebuild" : p.name == "java" && a.contains("GradleWrapperMain") ? "gradle" : nil
            guard let kind else { return nil }
            let up = ancestors(p)
            if up.contains(where: { $0.name == "RigWatch" && $0.args.dropFirst().first == "run" }) { return nil }
            // Two xcodebuilds in one chain are one build: only the outermost is listed.
            if kind == "xcodebuild", up.contains(where: { $0.name == "xcodebuild" }) { return nil }
            let agent = up.first { Agent.of($0) != nil }
            let session = p.session ?? up.lazy.compactMap(\.session).first
            let agentStart = agent.flatMap { DeviceSampler.startDate($0.pid) }
            let reason: String
            if !hook { reason = "the Rules hook is not installed" }
            else if let st = agentStart, let inst = installed, st < inst { reason = "its agent session started before Rules was turned on: restart that session to queue its builds" }
            else if agent == nil { reason = "not started from an agent session" }
            else { reason = "started inside a script or tool the hook can't see into" }
            return OutsideBuild(pid: p.pid, kind: kind, cwd: ProcSampler.cwd(p.pid), session: session, since: DeviceSampler.startDate(p.pid), cpu: p.cpu, reason: reason)
        }.sorted { ($0.since ?? .distantPast) < ($1.since ?? .distantPast) }
    }

    // MARK: hook

    /// Claude Code PreToolUse hook: reads the tool call on stdin, prints a rewrite or a refusal, or nothing.
    /// A question the user asked this session from a device card rides along as context, even while the rules are paused.
    static func hook() {
        guard let data = try? FileHandle.standardInput.readToEnd(), let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let s = RuleSettings.load()
        var out = s.paused ? nil : decide(j, s)
        // Not on a refused call: the question waits for one that goes ahead, so it is not lost beside the refusal.
        if out?["permissionDecision"] == nil, let ask = Asks.deliver(session: j["session_id"] as? String) {
            var o = out ?? ["hookEventName": "PreToolUse"]
            o["additionalContext"] = [o["additionalContext"] as? String, ask].compactMap { $0 }.joined(separator: "\n\n")
            out = o
        }
        // Leases: a session naming its own leased device keeps the lease going; one naming another's is warned.
        let tool = j["tool_name"] as? String ?? "", ti = j["tool_input"] as? [String: Any] ?? [:]
        let text = tool == "Bash" ? ti["command"] as? String ?? "" : (try? JSONSerialization.data(withJSONObject: ti)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        if out?["permissionDecision"] == nil, !tool.hasPrefix("mcp__rigwatch__"), let note = Leases.noteCommand(text, session: j["session_id"] as? String) {
            var o = out ?? ["hookEventName": "PreToolUse"]
            o["additionalContext"] = [o["additionalContext"] as? String, note].compactMap { $0 }.joined(separator: "\n\n")
            out = o
        }
        if let out { emit(["hookSpecificOutput": out]) }
    }

    /// What the rules do to one tool call: the hookSpecificOutput to print, or nil to leave it alone.
    static func decide(_ j: [String: Any], _ s: RuleSettings) -> [String: Any]? {
        let tool = j["tool_name"] as? String ?? ""
        var ti = j["tool_input"] as? [String: Any] ?? [:]
        var out: [String: Any] = ["hookEventName": "PreToolUse"]
        switch tool {
        case "Bash":
            switch wrap(ti["command"] as? String ?? "", s) {
            case .leave: return nil
            case .deny(let why): return denial(why)
            case .wrap(let cmd, let kind):
                ti["command"] = cmd
                if ti["run_in_background"] as? Bool != true, wouldWait(kind, cmd, s) {
                    ti["run_in_background"] = true
                    out["additionalContext"] = "RigWatch: every \(pool(kind: kind, cmd: cmd) == "ios" ? "iOS" : "Android") build slot on this machine is busy, so this command was queued and moved to the background. You will be notified when it finishes; carry on with other work meanwhile."
                }
            }
        case _ where tool.hasSuffix("__ctx_execute") && ti["language"] as? String == "shell":
            // Tools that run shell code in a sandbox of their own still take a slot.
            switch wrap(ti["code"] as? String ?? "", s) {
            case .leave: return nil
            case .deny(let why): return denial(why)
            case .wrap(let cmd, _): ti["code"] = cmd
            }
        case _ where tool.hasSuffix("__ctx_batch_execute"):
            var cmds = ti["commands"] as? [[String: Any]] ?? [], changed = false
            for i in cmds.indices {
                switch wrap(cmds[i]["command"] as? String ?? "", s) {
                case .leave: continue
                case .deny(let why): return denial(why)
                case .wrap(let cmd, _): cmds[i]["command"] = cmd; changed = true
                }
            }
            guard changed else { return nil }
            ti["commands"] = cmds
        case _ where tool.hasPrefix("mcp__"):
            // Device tools drive emulators and simulators without a shell: note their use so the clean-up leaves the device alone.
            let text = (try? JSONSerialization.data(withJSONObject: ti)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            let ids = matches(deviceIds, text)
            ids.forEach(touch)
            if ids.isEmpty && has(deviceTool, tool) { touch("any-device") }
            return nil
        default: return nil
        }
        out["updatedInput"] = ti
        return out
    }

    static func denial(_ why: String) -> [String: Any] {
        ["hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "RigWatch: " + why]
    }
    static func emit(_ o: [String: Any]) {
        if let d = try? JSONSerialization.data(withJSONObject: o, options: [.withoutEscapingSlashes]) { FileHandle.standardOutput.write(d) }
    }

    // MARK: build queue

    /// The job list under an exclusive lock (released when the descriptor closes), dead jobs dropped.
    static func withJobs<T>(_ body: (inout [BuildJob]) -> T) -> T {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fd = open(dir + "/jobs.lock", O_RDWR | O_CREAT, 0o644)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { close(fd) } }
        var list = jobs()
        let out = body(&list)
        write(try? JSONEncoder().encode(list), to: jobsFile)
        return out
    }
    static func jobs() -> [BuildJob] {
        (FileManager.default.contents(atPath: jobsFile).flatMap { try? JSONDecoder().decode([BuildJob].self, from: $0) } ?? []).filter(\.alive)
    }

    static func pressure() -> Int32 {
        var l: Int32 = 1, n = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &l, &n, nil, 0)
        return l
    }
    /// The pool a build waits in: xcodebuild and pod installs are iOS; Gradle and npm or yarn installs are Android.
    static let podInstall = rx(#"\bpod\s+(install|update)"#)
    static func pool(kind: String, cmd: String) -> String {
        kind == "xcodebuild" || (kind == "install" && has(podInstall, cmd)) ? "ios" : "android"
    }
    static func pool(_ j: BuildJob) -> String { pool(kind: j.kind, cmd: j.cmd) }
    /// Slot units of one pool (a build takes 2).
    static func cap(_ pool: String, _ s: RuleSettings) -> Int { max(1, pool == "ios" ? s.iosBuilds : s.androidBuilds) * 2 }
    /// Slot units allowed now across both pools: all of them, half under a memory pressure warning, none when
    /// critical (a job still starts when nothing else is running).
    static func limit(_ s: RuleSettings) -> Int {
        let all = cap("android", s) + cap("ios", s), p = pressure()
        return p >= 4 ? 0 : p >= 2 ? all / 2 : all
    }
    static func load(_ jobs: [BuildJob], pool p: String? = nil) -> Int {
        jobs.filter { $0.state == "running" && (p == nil || pool($0) == p) }.reduce(0) { $0 + $1.weight }
    }
    /// Whether a job of this pool and weight can start beside the running ones.
    static func fits(_ p: String, _ w: Int, _ j: [BuildJob], _ s: RuleSettings) -> Bool {
        load(j) == 0 || (load(j, pool: p) + w <= cap(p, s) && load(j) + w <= limit(s))
    }
    static func wouldWait(_ kind: String, _ cmd: String, _ s: RuleSettings) -> Bool {
        let p = pool(kind: kind, cmd: cmd), w = weights[kind] ?? 2
        return withJobs { j in j.contains { $0.state == "waiting" && pool($0) == p } || !fits(p, w, j, s) }
    }

    static var child: pid_t = 0

    /// `RigWatch run [--kind K] -- CMD...`: waits for a slot (first come, first served), then runs CMD
    /// at utility priority and passes its exit status on.
    static func run(_ args: [String]) -> Int32 {
        var a = args, kind: String?
        if a.first == "--kind", a.count > 1 { kind = a[1]; a.removeFirst(2) }
        if a.first == "--" { a.removeFirst() }
        guard !a.isEmpty else { say("RigWatch run: no command"); return 2 }
        let s = RuleSettings.load(), line = a.joined(separator: " ")
        let k = kind ?? classify(line) ?? "gradle"
        let session = ProcessInfo.processInfo.environment["CLAUDE_CODE_SESSION_ID"]
        let me = BuildJob(pid: getpid(), start: ProcSampler.startTime(getpid()) ?? 0, kind: k, weight: weights[k] ?? 2,
                          cwd: FileManager.default.currentDirectoryPath, cmd: String(line.suffix(200)), state: "waiting", since: Date(),
                          session: session, queuedAt: Date())
        withJobs { $0.append(me) }
        let slot = NSLock()
        var held = true   // the slot is ours until the build tool exits or the command ends
        let release = { slot.lock(); defer { slot.unlock() }; if held { held = false; withJobs { j in j.removeAll { $0.pid == me.pid } } } }
        var sources: [DispatchSourceSignal] = []
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)   // the child gets default handlers back (POSIX_SPAWN_SETSIGDEF)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            src.setEventHandler { if child > 0 { kill(child, sig) } else { release(); exit(128 + sig) } }
            src.resume(); sources.append(src)
        }
        // A new worktree gets node_modules, Pods and Xcode caches matching its lockfiles before anything runs.
        let roots = roots(line, cwd: me.cwd)
        for r in roots { for n in DepCache.prepare(r) { say("RigWatch: " + n) } }
        if k == "xcodebuild" { for n in DepCache.prepareDerivedData(cmd: line, cwd: me.cwd) { say("RigWatch: " + n) } }
        let queue = s.queueBuilds && !s.paused, p = pool(me)
        let t0 = Date(), maxWait = TimeInterval(max(1, s.maxWaitMinutes) * 60)
        var last = "", overflow = false, forced = false
        while true {
            let waited = Date().timeIntervalSince(t0)
            let ahead: [BuildJob]? = withJobs { j in
                guard let i = j.firstIndex(where: { $0.pid == me.pid }) else { j.append(me); return [] }
                // First come, first served within the pool; the other pool's line does not hold this one up.
                let head = j.filter { $0.state == "waiting" && pool($0) == p }.min { $0.since < $1.since }
                if j[i].force == true { forced = true }
                else if queue, !(head?.pid == me.pid && fits(p, me.weight, j, s)) {
                    // Never wait for ever: past the limit it starts anyway, at background priority.
                    guard waited > maxWait else { return j.filter { pool($0) == p && ($0.state == "running" || ($0.state == "waiting" && $0.since < me.since)) } }
                    overflow = true; j[i].overflow = true
                }
                j[i].state = "running"; j[i].since = Date(); return nil
            }
            guard let ahead else { break }
            let msg = ahead.map { "\($0.kind) \($0.state) in \(($0.cwd as NSString).lastPathComponent)" }.joined(separator: "; ")
            if msg != last {
                let by = t0.addingTimeInterval(maxWait).formatted(date: .omitted, time: .shortened)
                say("RigWatch: queued for an \(p == "ios" ? "iOS" : "Android") slot behind: \(msg.ifEmpty("memory pressure, which halves all builds")). It starts by \(by) at the latest.")
                last = msg
            }
            Thread.sleep(forTimeInterval: 2)
        }
        let waited = Date().timeIntervalSince(t0)
        if overflow { say("RigWatch: waited \(Int(waited / 60)) min for a slot; starting now at background priority, so it can't slow the Mac down.") }
        else if forced { say("RigWatch: started from the Builds page after \(Int(waited)) s.") }
        else if waited > 3 { say("RigWatch: slot granted after \(Int(waited)) s") }
        // The slot is for the build tool itself: once it has run and exited, the rest of the command
        // (installs, logcat, waits) goes on without holding back the next build.
        var early = false
        if let tools = buildTools[k] {
            Thread.detachNewThread {
                var saw = false, absent = 0
                while true {
                    Thread.sleep(forTimeInterval: 3)
                    let c = child
                    guard c > 0 else { if saw { return } else { continue } }
                    let running = descendants(of: c).contains { tools.contains($0.name) }
                    if running { saw = true; absent = 0 } else if saw { absent += 1 }
                    if saw && absent >= 2 {
                        release(); early = true
                        say("RigWatch: the \(k) build finished; its slot is free while the rest of the command runs.")
                        return
                    }
                }
            }
        }
        let started = Date()
        let code = spawn((overflow ? ["/usr/sbin/taskpolicy", "-b"] : ["/usr/sbin/taskpolicy", "-c", "utility"]) + a)
        release()
        if code == 0 { for r in roots { DepCache.seed(r) } }   // the next worktree with these lockfiles starts from here
        BuildHistory.add(BuildRecord(kind: k, pool: p, cwd: me.cwd, cmd: me.cmd, session: session, queuedAt: t0, startedAt: started,
                                     endedAt: Date(), waited: waited, overflow: overflow, forced: forced, releasedEarly: early, exit: code))
        withExtendedLifetime(sources) {}
        return code
    }

    /// The process that does the work of each kind of build: the slot is held while one runs.
    static let buildTools: [String: Set<String>] = ["xcodebuild": ["xcodebuild"], "gradle": ["java"]]

    /// Every process under `pid`, from the kernel's process list (no ps).
    static func descendants(of pid: pid_t) -> [(pid: pid_t, name: String)] {
        var n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var kids: [pid_t: [(pid_t, String)]] = [:]
        for p in pids.prefix(Int(max(n, 0))) where p > 0 {
            var info = proc_bsdinfo()
            guard proc_pidinfo(p, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { continue }
            let name = withUnsafeBytes(of: &info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            kids[pid_t(info.pbi_ppid), default: []].append((p, name))
        }
        var out: [(pid: pid_t, name: String)] = [], stack = [pid]
        while let x = stack.popLast() { for (c, nm) in kids[x] ?? [] { out.append((c, nm)); stack.append(c) } }
        return out
    }

    static func spawn(_ argv: [String]) -> Int32 {
        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var all = ~sigset_t(0), none = sigset_t(0)
        posix_spawnattr_setsigdefault(&attr, &all)
        posix_spawnattr_setsigmask(&attr, &none)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        let c = argv.map { strdup($0) } + [nil]
        // The environment from Foundation: `_NSGetEnviron` is not visible to Swift in every macOS SDK.
        let env = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { c.forEach { free($0) }; env.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, argv[0], nil, &attr, c, env)
        guard rc == 0 else { say("RigWatch run: could not start \(argv[0]): \(String(cString: strerror(rc)))"); return 127 }
        child = pid
        var st: Int32 = 0
        while waitpid(pid, &st, 0) == -1 && errno == EINTR {}
        child = 0
        return st & 0x7f == 0 ? (st >> 8) & 0xff : 128 + (st & 0x7f)
    }

    /// Git checkouts a command works in: its folder and any it `cd`s into.
    static func roots(_ cmd: String, cwd: String) -> Set<String> {
        let cds = matches(rx(#"\bcd\s+("[^"]+"|'[^']+'|[^\s;&|]+)"#), cmd, group: 1)
            .map { ($0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) as NSString).expandingTildeInPath }
        let dirs = [cwd] + cds.map { $0.hasPrefix("/") ? $0 : cwd + "/" + $0 }
        return Set(dirs.compactMap { d in
            let t = Sh.git(["rev-parse", "--show-toplevel"], in: d).out.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        })
    }

    // MARK: device use

    static func touchPath(_ k: String) -> String { touchDir + "/" + k.replacingOccurrences(of: "/", with: "_") }
    static func touch(_ k: String) {
        try? FileManager.default.createDirectory(atPath: touchDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: touchPath(k), contents: nil)
    }
    static func touched(_ k: String) -> Date? { mtime(touchPath(k)) }

    static func pins() -> Set<String> { Set(FileManager.default.contents(atPath: pinsFile).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []) }
    static func setPin(_ id: String, _ on: Bool) {
        var p = pins()
        if on { p.insert(id) } else { p.remove(id) }
        write(try? JSONEncoder().encode(p.sorted()), to: pinsFile)
    }

    /// An app running in a simulator burns CPU; an idle home screen barely does. True when the
    /// simulator's processes used over 5 CPU-seconds since the last clean-up that acted.
    static func simBusy(_ d: Device, _ procs: [Proc], save: Bool) -> Bool {
        guard let root = d.pid else { return false }
        var kids: [Int32: [Int32]] = [:]
        for p in procs { kids[p.ppid, default: []].append(p.pid) }
        var total = 0.0, stack = kids[root] ?? []
        while let x = stack.popLast() { total += ProcSampler.cpuSeconds(x) ?? 0; stack += kids[x] ?? [] }
        let f = touchPath("simcpu-" + d.id)
        let prev = (try? String(contentsOfFile: f, encoding: .utf8)).flatMap(Double.init)
        if save { touch("simcpu-" + d.id); try? String(total).write(toFile: f, atomically: true, encoding: .utf8) }
        return prev.map { total - $0 > 5 } ?? false
    }

    // MARK: clean-up

    /// Runs every rule that is on. A dry run (apply false) only reports. `explicit` is a person asking
    /// from the page: no first-hour grace and no once-an-hour wait for the disk part.
    static func reap(apply wanted: Bool, explicit: Bool = false) -> ReapReport {
        var r = ReapReport()
        let s = RuleSettings.load()
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fd = open(dir + "/reap.lock", O_RDWR | O_CREAT, 0o644)
        defer { if fd >= 0 { close(fd) } }
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { r.notes.append("Another clean-up is running; skipped."); return r }
        var apply = wanted
        if apply && s.paused { apply = false; r.notes.append("Rules are paused: reporting only.") }
        if apply && !explicit, let t = mtime(dir + "/installed"), Date().timeIntervalSince(t) < 3600 {
            apply = false
            r.notes.append("First hour after turning the rules on: reporting only, so device use by sessions already running is noticed first.")
        }
        r.applied = apply
        trimLog()
        let procs = ProcSampler().sample()
        if apply { _ = BuildGovernor().apply(procs) }   // with the app closed, the clean-up governs builds outside the queue
        if s.reapDevices { reapDevices(&r, s, procs, apply: apply) }
        let diskStamp = dir + "/last-disk-reap"
        if explicit || !apply || (mtime(diskStamp).map { Date().timeIntervalSince($0) > 3600 } ?? true) {
            if s.reapWorktrees { reapWorktrees(&r, s, procs, apply: apply) }
            if s.reapDerivedData { reapDerivedData(&r, s, apply: apply) }
            if apply { FileManager.default.createFile(atPath: diskStamp, contents: nil) }
        } else {
            r.notes.append("Worktrees and DerivedData are checked once an hour; last checked \(Fmt.ago(mtime(diskStamp))).")
        }
        return r
    }

    static func saveReport(_ r: ReapReport) {
        let e = JSONEncoder(); e.outputFormatting = .prettyPrinted
        write(try? e.encode(r), to: reportFile)
    }
    static func lastReport() -> ReapReport? { FileManager.default.contents(atPath: reportFile).flatMap { try? JSONDecoder().decode(ReapReport.self, from: $0) } }

    /// The action log keeps its last half megabyte.
    static func trimLog() {
        guard let a = try? FileManager.default.attributesOfItem(atPath: logFile), ((a[.size] as? NSNumber)?.intValue ?? 0) > 1_000_000,
              let t = SessionIndex.tail(logFile, bytes: 500_000) else { return }
        write(Data(t.drop { $0 != "\n" }.dropFirst().utf8), to: logFile)
    }

    static func reapDevices(_ r: inout ReapReport, _ s: RuleSettings, _ procs: [Proc], apply: Bool) {
        let devs = DeviceSampler().sample(procs: procs, deep: false)
        let virt = devs.filter { $0.kind != .phone }
        guard !virt.isEmpty else { return }
        let androidPhys = devs.filter { $0.kind == .phone && $0.state == "device" }.map(\.name)
        let iosPhys = virt.contains { $0.kind == .simulator } ? iPhones() : []
        let pinned = pins(), now = Date()
        for d in virt {
            let ios = d.kind == .simulator
            let phys = ios ? iosPhys : androidPhys
            let busy = ios && simBusy(d, procs, save: apply)
            if busy && apply { touch(d.id) }
            let limit = TimeInterval((phys.isEmpty ? s.deviceIdleMinutes : s.deviceIdleWithPhoneMinutes) * 60)
            // With a physical device attached, adb and simctl calls that name no device are for it: only calls naming this one count.
            let last = [busy ? now : nil, phys.isEmpty ? touched(ios ? "ios" : "android") : nil, touched(d.id), touched("any-device"), d.started]
                .compactMap { $0 }.max() ?? .distantPast
            let idle = now.timeIntervalSince(last)
            let name = "\(d.name) (\(d.id))"
            if pinned.contains(d.id) || pinned.contains(d.name) { r.kept.append("\(name): pinned"); continue }
            if let l = d.lease { r.kept.append("\(name): \(l.isImplicit ? "in use by" : "leased to") session \(l.session)\(l.isImplicit ? "" : " until \(Leases.time(l.until))")"); continue }
            if let c = d.claim { r.kept.append("\(name): held by agent-device for session \(c.session)"); continue }
            // Only what an agent started: a device a person opened may be in use without any command naming it.
            guard d.launchedBy != nil || agentBooted(d) else { r.kept.append("\(name): not started by an agent session"); continue }
            guard idle > limit else { r.kept.append("\(name): used \(Fmt.ago(last))"); continue }
            var a = ReapAction(kind: "Shut down", target: d.name, key: d.id,
                               detail: "\(d.kind.rawValue), idle \(Fmt.ago(last).replacingOccurrences(of: " ago", with: ""))" + (phys.isEmpty ? "" : " · \(phys.joined(separator: ", ")) connected"),
                               bytes: Int64(d.mem))
            if apply {
                let res = DeviceSampler.shutDown(d)
                a.result = res; a.outcome = res.hasPrefix("simctl shutdown failed") || res.contains("still running") ? "failed" : "done"
                log("shut down \(name): \(a.detail). \(res)")
            }
            r.actions.append(a)
        }
    }

    /// Worktrees an agent app creates and tracks itself (Claude Code's own sessions): removing one would pull
    /// the folder out from under a session the app still lists.
    static let managedWorktreeMarkers = ["/.claude/worktrees/"]

    /// Untracked files a person put there by hand: a worktree holding them is never removed unattended.
    static let unattendedKeep = ["app/keystore", "Secrets.xcconfig"]

    static func reapWorktrees(_ r: inout ReapReport, _ s: RuleSettings, _ procs: [Proc], apply: Bool) {
        let me = getuid(), fm = FileManager.default
        let cwds = procs.filter { $0.uid == me }.compactMap { p in ProcSampler.cwd(p.pid).map { ("\(p.name) (\(p.pid))", $0) } }
        let limit = TimeInterval(s.worktreeIdleHours * 3600), now = Date()
        for w in Worktrees.list(cwds: cwds) where !w.isMain && !w.locked && w.usedBy.isEmpty {
            let name = Views.tilde(w.path)
            if s.protects(w.path) || s.protects(w.repoPath) { r.kept.append("\(name): in a never-clean folder"); continue }
            if managedWorktreeMarkers.contains(where: w.path.contains) { r.kept.append("\(name): managed by Claude Code"); continue }
            if !w.exists {
                var a = ReapAction(kind: "Prune", target: name, key: w.path, detail: "the folder is gone; drops git's stale entry for it")
                if apply {
                    let res = Worktrees.remove(w, force: false)
                    a.result = res; a.outcome = res.hasPrefix("Pruned") || res.hasPrefix("Removed") ? "done" : "failed"
                    log("prune \(w.path): \(res)")
                }
                r.actions.append(a)
                continue
            }
            let st = Sh.git(["status", "--porcelain", "--untracked-files=normal"], in: w.path).out.split(separator: "\n").map(String.init)
            let last = ([w.lastActivity] + st.map { mtime(w.path + "/" + $0.dropFirst(3)) }).compactMap { $0 }.max() ?? .distantPast
            guard now.timeIntervalSince(last) > limit else { continue }
            let idle = "idle " + Fmt.ago(last).replacingOccurrences(of: " ago", with: "")
            let c = Worktrees.check(w, sessionWorking: false)
            let secrets = st.contains { l in l.hasPrefix("??") && unattendedKeep.contains { l.dropFirst(3).hasPrefix($0) } }
            let nm = w.path + "/node_modules"
            let nmIgnored = isDir(nm) && !ignored(["node_modules"], in: w.path).isEmpty
            let cached = nmIgnored && DepCache.seed(w.path, apply: apply).contains { $0.hasPrefix("node-") }
            // Unattended removal also needs no untracked file git doesn't ignore, setup files included.
            let loose = st.contains { $0.hasPrefix("??") }
            if c.safe && !secrets && !loose {
                var a = ReapAction(kind: "Remove worktree", target: name, key: w.path, detail: "\(w.branch), clean, \(idle). The branch and its commits stay.",
                                   bytes: Worktrees.sizeKB(w.path).map { $0 * 1024 })
                if apply {
                    // The big regenerable folders first, with no time limit, so git's own remove is quick.
                    (buildOutputs(w.path) + (nmIgnored ? [nm] : [])).forEach { try? fm.removeItem(atPath: $0) }
                    let again = Worktrees.check(w, sessionWorking: false)
                    let looseNow = Sh.git(["status", "--porcelain", "--untracked-files=normal"], in: w.path).out.split(separator: "\n").contains { $0.hasPrefix("??") }
                    if again.safe && !looseNow {
                        let res = Worktrees.remove(w, force: again.force)
                        a.result = res; a.outcome = res.hasPrefix("Removed") ? "done" : "failed"
                    } else {
                        a.result = "Kept: " + (looseNow ? "untracked files appeared. " : "") + again.reasons.joined(separator: " "); a.outcome = "kept"
                    }
                    log("remove \(w.path): \(a.result ?? "")")
                }
                r.actions.append(a)
                continue
            }
            let drop = buildOutputs(w.path) + (cached ? [nm] : [])
            let why = secrets ? "untracked \(unattendedKeep.joined(separator: " or "))"
                : c.safe && loose ? "untracked files that git does not ignore" : c.reasons.joined(separator: " ")
            let bytes = drop.compactMap(Worktrees.sizeKB).reduce(0, +) * 1024
            guard bytes >= 50 << 20 else { r.kept.append("\(name): \(why) (\(idle))"); continue }   // not worth an action
            var a = ReapAction(kind: "Strip build output", target: name, key: w.path,
                               detail: "source kept (\(why)); \(idle); deletes \(drop.map { String($0.dropFirst(w.path.count + 1)) }.joined(separator: ", "))",
                               bytes: bytes)
            if apply {
                let gone = drop.filter { (try? fm.removeItem(atPath: $0)) != nil }.count
                a.result = gone == drop.count ? "Deleted \(gone) folder(s)." : "Deleted \(gone) of \(drop.count) folders; the rest could not be deleted."
                a.outcome = gone == drop.count ? "done" : "failed"
                log("strip \(w.path): \(drop.map { String($0.dropFirst(w.path.count + 1)) }.joined(separator: ", "))")
            }
            r.actions.append(a)
        }
    }

    /// Folders a build regenerates: only ones git ignores, and never one git tracks files in. An untracked
    /// folder git does not ignore may be someone's work that is simply not committed yet.
    static func buildOutputs(_ wt: String) -> [String] {
        let kids = (try? FileManager.default.contentsOfDirectory(atPath: wt)) ?? []
        let dirs = (["build", ".gradle", ".kotlin"] + kids.map { $0 + "/build" }).filter { isDir(wt + "/" + $0) }
        guard !dirs.isEmpty else { return [] }
        let tracked = Sh.git(["ls-files", "--"] + dirs, in: wt).out.split(separator: "\n")
        return ignored(dirs.filter { d in !tracked.contains { $0.hasPrefix(d + "/") } }, in: wt).map { wt + "/" + $0 }
    }

    /// The paths (relative to the worktree) that git ignores there.
    static func ignored(_ paths: [String], in wt: String) -> [String] {
        guard !paths.isEmpty else { return [] }
        let out = Set(Sh.git(["check-ignore", "--"] + paths.map { $0 + "/" }, in: wt).out.split(separator: "\n").map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "/")) })
        return paths.filter { out.contains($0) }
    }

    /// True only when the project is provably gone: its folder can be listed and the project is not in it.
    /// "Can't see it" is never "gone": a project on an unplugged drive, in a folder macOS guards (where a
    /// background check would also raise a privacy prompt) or in a never-clean folder is left alone.
    static func projectGone(_ ws: String, _ s: RuleSettings) -> Bool {
        guard ws.hasPrefix("/"), !ws.hasPrefix("/Volumes/"), !s.protects(ws), !underPrivate(ws) else { return false }
        let parent = (ws as NSString).deletingLastPathComponent
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: parent) else { return false }
        return !names.contains((ws as NSString).lastPathComponent)
    }

    /// The path or one of its folders is one macOS guards with a privacy prompt (see Worktrees.privateHome).
    static func underPrivate(_ path: String) -> Bool {
        var p = path
        while p.count > 1 {
            if Worktrees.isPrivate(p) { return true }
            p = (p as NSString).deletingLastPathComponent
        }
        return false
    }

    static func reapDerivedData(_ r: inout ReapReport, _ s: RuleSettings, apply: Bool) {
        let dd = Sh.home + "/Library/Developer/Xcode/DerivedData"
        for n in ((try? FileManager.default.contentsOfDirectory(atPath: dd)) ?? []).sorted() where n.contains("-") {
            let p = dd + "/" + n
            guard let ws = NSDictionary(contentsOfFile: p + "/info.plist")?["WorkspacePath"] as? String, projectGone(ws, s),
                  let t = mtime(p), Date().timeIntervalSince(t) > 86400 else { continue }
            var a = ReapAction(kind: "Delete DerivedData", target: n, key: p, detail: "its project \(Views.tilde(ws)) no longer exists",
                               bytes: Worktrees.sizeKB(p).map { $0 * 1024 })
            if apply {
                let ok = (try? FileManager.default.removeItem(atPath: p)) != nil
                a.result = ok ? "Deleted." : "Could not delete."; a.outcome = ok ? "done" : "failed"
                log("delete DerivedData \(p): \(a.result ?? "")")
            }
            r.actions.append(a)
        }
    }

    // MARK: install

    /// What the hook and the clean-up agent run: this app's own binary, at a path that survives updates.
    static var installExe: String {
        let b = Bundle.main.bundleURL.resolvingSymlinksInPath()
        return b.pathExtension == "app" ? b.path + "/Contents/MacOS/RigWatch" : exe
    }
    static func isOurs(_ entry: [String: Any]) -> Bool {
        (entry["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.hasSuffix("RigWatch' hook") ?? false }
    }
    static func hookInstalled() -> Bool {
        guard let d = FileManager.default.contents(atPath: claudeSettings), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return false }
        return ((j["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]] ?? []).contains(where: isOurs)
    }
    static func agentInstalled() -> Bool { FileManager.default.fileExists(atPath: agentPlist) }

    // MARK: MCP server registration

    static let claudeConfig = (ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { $0 + "/.claude.json" }) ?? Sh.home + "/.claude.json"
    static let claudeCLI: String? = [Sh.home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", Sh.home + "/.claude/local/claude"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
    /// Whether Claude Code's user config lists RigWatch's MCP server.
    static func mcpInstalled() -> Bool {
        guard let d = FileManager.default.contents(atPath: claudeConfig), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return false }
        return (j["mcpServers"] as? [String: Any])?["rigwatch"] != nil
    }
    /// Registers `RigWatch mcp` for every Claude Code session of this user, through Claude Code's own CLI.
    static func installMCP(exe: String) -> String {
        guard let cli = claudeCLI else { return "Claude Code's command (claude) was not found, so the device manager is not registered. Run: claude mcp add --scope user rigwatch -- \(quote(exe)) mcp" }
        _ = Sh.run(cli, ["mcp", "remove", "--scope", "user", "rigwatch"], timeout: 30)
        let r = Sh.run(cli, ["mcp", "add", "--scope", "user", "rigwatch", "--", exe, "mcp"], timeout: 30)
        return r.code == 0 ? "the device manager (MCP server rigwatch) is registered for new Claude Code sessions"
            : "registering the device manager failed (claude mcp add: \((r.err.isEmpty ? r.out : r.err).trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)))"
    }
    static func uninstallMCP() {
        if let cli = claudeCLI { _ = Sh.run(cli, ["mcp", "remove", "--scope", "user", "rigwatch"], timeout: 30) }
    }

    /// Edits the PreToolUse hooks in ~/.claude/settings.json, after copying the file aside. Nil, or what went wrong.
    static func editHooks(_ change: (inout [[String: Any]]) -> Void) -> String? {
        var root: [String: Any] = [:]
        if let d = FileManager.default.contents(atPath: claudeSettings) {
            guard let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return "\(Views.tilde(claudeSettings)) is not plain JSON; left it alone." }
            root = j
            write(d, to: claudeSettings + ".rigwatch-backup")
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var pre = hooks["PreToolUse"] as? [[String: Any]] ?? []
        change(&pre)
        hooks["PreToolUse"] = pre.isEmpty ? nil : pre
        root["hooks"] = hooks.isEmpty ? nil : hooks
        guard let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "Could not write the settings." }
        write(out, to: claudeSettings)
        return nil
    }

    static func install(exe: String) -> String {
        // Starts the first hour of reporting only. Not on a re-install: the hook was already routing sessions.
        if !hookInstalled() || !FileManager.default.fileExists(atPath: dir + "/installed") { write(Data(), to: dir + "/installed") }
        let entry: [String: Any] = ["matcher": "Bash|mcp__.*", "hooks": [["type": "command", "command": quote(exe) + " hook", "timeout": 45]]]
        if let err = editHooks({ $0.removeAll(where: isOurs); $0.append(entry) }) { return err }
        let plist: [String: Any] = ["Label": agentLabel, "ProgramArguments": [exe, "reap", "--apply"], "StartInterval": 600, "RunAtLoad": true,
                                    "LowPriorityIO": true, "ProcessType": "Background", "StandardErrorPath": dir + "/reap-errors.log"]
        write(try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), to: agentPlist)
        let dom = "gui/\(getuid())"
        _ = Sh.run("/bin/launchctl", ["bootout", "\(dom)/\(agentLabel)"], timeout: 15)
        let b = Sh.run("/bin/launchctl", ["bootstrap", dom, agentPlist], timeout: 15)
        let agent = b.code == 0 ? "the clean-up runs every 10 minutes"
            : "the clean-up agent did not start (launchctl: \(b.err.trimmingCharacters(in: .whitespacesAndNewlines))); from Terminal run: launchctl bootstrap \(dom) \(agentPlist)"
        return "Rules on: new tool calls in every Claude Code session go through RigWatch, \(agent), and \(installMCP(exe: exe))."
    }

    static func uninstall() -> String {
        let err = editHooks { $0.removeAll(where: isOurs) }
        _ = Sh.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(agentLabel)"], timeout: 15)
        try? FileManager.default.removeItem(atPath: agentPlist)
        uninstallMCP()
        return err ?? "Rules off: the hook and the device manager are removed from Claude Code's settings and the clean-up agent is stopped."
    }

    // MARK: worktree creation

    /// `RigWatch wt REPO BRANCH [BASE]`: a worktree in <repo's folder>/.wt/<repo>/<branch>, with node_modules cloned in.
    static func newWorktree(_ a: [String]) -> Int32 {
        guard a.count >= 2 else { say("usage: RigWatch wt REPO BRANCH [BASE]"); return 2 }
        let repo = URL(fileURLWithPath: (a[0] as NSString).expandingTildeInPath).standardizedFileURL.path, branch = a[1]
        let path = (repo as NSString).deletingLastPathComponent + "/.wt/" + (repo as NSString).lastPathComponent + "/" + branch.replacingOccurrences(of: "/", with: "-")
        let exists = Sh.git(["rev-parse", "--verify", "-q", "refs/heads/" + branch], in: repo).code == 0
        let r = Sh.git(["worktree", "add", path] + (exists ? [branch] : ["-b", branch] + a.dropFirst(2).prefix(1)), in: repo, timeout: 600)
        guard r.code == 0 else { say(r.err.trimmingCharacters(in: .whitespacesAndNewlines)); return r.code == 0 ? 1 : r.code }
        for n in DepCache.prepare(path) { say("RigWatch: " + n) }
        print(path)
        return 0
    }

    static func status() -> String {
        let s = RuleSettings.load(), j = jobs()
        var out = ["rules \(s.paused ? "PAUSED" : "on") · hook \(hookInstalled() ? "installed" : "not installed") · clean-up agent \(agentInstalled() ? "installed" : "not installed")",
                   "memory pressure \(pressure()) (1 normal, 2 warning, 4 critical) · slot units in use (a build takes 2): Android \(load(j, pool: "android")) of \(cap("android", s)), iOS \(load(j, pool: "ios")) of \(cap("ios", s)), \(load(j)) of \(limit(s)) allowed in all"]
        out += j.map { "  \($0.state.padding(toLength: 8, withPad: " ", startingAt: 0)) \($0.kind.padding(toLength: 10, withPad: " ", startingAt: 0)) \(Int(Date().timeIntervalSince($0.since))) s  \(Views.tilde($0.cwd))  \($0.cmd.prefix(80))" }
        let procs = ProcSampler().sample()
        out += outsideQueue(procs).map { "  outside  \($0.kind.padding(toLength: 10, withPad: " ", startingAt: 0)) pid \($0.pid)  \($0.cwd.map(Views.tilde) ?? "?")  \($0.reason)" }
        for plat in ["android", "ios"] {
            let (phys, virt) = devices(plat, procs: procs)
            out.append("\(plat): physical \(phys.isEmpty ? "none" : phys.joined(separator: ", ")); virtual \(virt.isEmpty ? "none" : virt.map { "\($0.name) \($0.id) up \(Fmt.ago($0.started).replacingOccurrences(of: " ago", with: ""))" }.joined(separator: ", "))")
        }
        let leases = Leases.live()
        out.append("leases: " + (leases.isEmpty ? "none" : leases.map { $0.isImplicit ? "\($0.device) in use by session \($0.session) (no lease)" : "\($0.name) (\($0.device)) to session \($0.session) until \(Leases.time($0.until))\($0.purpose.isEmpty ? "" : " for \"\($0.purpose)\"")" }.joined(separator: "; ")))
        out.append("pinned: \(pins().isEmpty ? "none" : pins().sorted().joined(separator: ", "))")
        if let r = lastReport() { out.append("last clean-up \(Fmt.ago(r.at)): \(r.actions.count) action(s)\(r.applied ? "" : ", reported only")") }
        return out.joined(separator: "\n")
    }
}

/// `RigWatch <command>`: the Rules command line. Anything else opens the app.
enum CLI {
    static let usage = """
    RigWatch run [--kind K] -- CMD...   run CMD once an Android or iOS build slot is free
    RigWatch hook                       Claude Code PreToolUse hook (tool call JSON on stdin)
    RigWatch reap [--apply]             clean up idle devices, worktrees and DerivedData (reports only without --apply)
    RigWatch wt REPO BRANCH [BASE]      new worktree beside the repo, in .wt/, with node_modules cloned in
    RigWatch pin|unpin ID               keep an emulator or simulator (serial, AVD name or UDID) from the clean-up
    RigWatch answer ID yes|no [REASON]  answer RigWatch's question whether a device you use can be shut down
    RigWatch status                     what is running, queued and booted
    RigWatch mcp                        MCP server: agents acquire and release emulators, simulators and phones
    RigWatch version                    the version of this RigWatch
    RigWatch install|uninstall          turn the rules on or off (Claude Code hook, MCP device manager, clean-up agent)
    """
    static let commands: Set = ["run", "hook", "mcp", "reap", "status", "wt", "pin", "unpin", "answer", "install", "uninstall", "help", "version", "--version"]

    static func main(_ args: [String]) -> Int32? {
        guard let c = args.first, commands.contains(c) else { return nil }
        let a = Array(args.dropFirst())
        switch c {
        case "run": return Rules.run(a)
        case "hook": Rules.hook()   // nothing printed = the tool call goes ahead unchanged
        case "mcp": return MCPServer.main()
        case "reap": let r = Rules.reap(apply: a.contains("--apply")); Rules.saveReport(r); print(r.text)
        case "wt": return Rules.newWorktree(a)
        case "pin", "unpin":
            guard let id = a.first else { Rules.say("usage: RigWatch \(c) ID"); return 2 }
            Rules.setPin(id, c == "pin"); print("pinned: \(Rules.pins().sorted().joined(separator: ", ").ifEmpty("none"))")
        case "answer": return Asks.answer(a)
        case "status": print(Rules.status())
        case "version", "--version": print("RigWatch \(AppCopy.ownVersion)")
        case "install": print(Rules.install(exe: Rules.installExe))
        case "uninstall": print(Rules.uninstall())
        default: print(usage)
        }
        return 0
    }
}

/// One finished build that went through the queue, for the Builds page.
struct BuildRecord: Codable, Identifiable {
    let kind: String, pool: String, cwd: String, cmd: String
    let session: String?
    let queuedAt: Date, startedAt: Date, endedAt: Date
    let waited: TimeInterval
    let overflow: Bool, forced: Bool, releasedEarly: Bool
    let exit: Int32
    var id: Date { queuedAt }
    var ran: TimeInterval { endedAt.timeIntervalSince(startedAt) }
}

enum BuildHistory {
    static let file = Rules.dir + "/builds.jsonl"
    static func add(_ r: BuildRecord) {
        guard let d = try? JSONEncoder().encode(r) else { return }
        let line = d + Data("\n".utf8)
        if let h = FileHandle(forWritingAtPath: file) { h.seekToEndOfFile(); h.write(line); try? h.close() } else { Rules.write(line, to: file) }
        // Keep the file small: the last 500 builds.
        if let all = try? String(contentsOfFile: file, encoding: .utf8) {
            let lines = all.split(separator: "\n")
            if lines.count > 600 { Rules.write(Data((lines.suffix(500).joined(separator: "\n") + "\n").utf8), to: file) }
        }
    }
    /// Newest first.
    static func recent(_ n: Int = 50) -> [BuildRecord] {
        guard let all = try? String(contentsOfFile: file, encoding: .utf8) else { return [] }
        return all.split(separator: "\n").suffix(n).reversed().compactMap { try? JSONDecoder().decode(BuildRecord.self, from: Data($0.utf8)) }
    }
}

/// Builds that don't go through the queue still can't take the Mac over: while the rules are on, the app
/// lowers the priority (nice 10) of every build outside the queue and its child processes, and of Gradle's
/// and Kotlin's daemons, which do a Gradle build's work in processes of their own. Own processes only.
final class BuildGovernor {
    static let nice: Int32 = 10
    /// RIGWATCH_GOVERN=1 governs without the hook installed (for testing on a Mac with the rules off).
    static var active: Bool {
        if Demo.on { return true }
        let s = RuleSettings.load()
        return s.lowerOutside && !s.paused && (Rules.hookInstalled() || ProcessInfo.processInfo.environment["RIGWATCH_GOVERN"] == "1")
    }

    /// Lowers what needs lowering; returns every process now running at the lowered priority because of it.
    func apply(_ procs: [Proc]) -> Set<Int32> {
        guard Self.active else { return [] }
        var kids: [Int32: [Int32]] = [:]
        for p in procs { kids[p.ppid, default: []].append(p.pid) }
        var targets = Set<Int32>()
        for b in Rules.outsideQueue(procs) {
            var stack = [b.pid]
            while let x = stack.popLast() { targets.insert(x); stack += kids[x] ?? [] }
        }
        for p in procs where p.isOwn && p.name == "java" && p.args.contains(where: { $0.contains("GradleDaemon") || $0.contains("KotlinCompileDaemon") }) {
            targets.insert(p.pid)
        }
        let me = getuid()
        var lowered = Set<Int32>()
        for pid in targets where procs.first(where: { $0.pid == pid })?.uid == me {
            errno = 0
            let cur = getpriority(PRIO_PROCESS, id_t(pid))
            if errno != 0 { continue }
            if cur >= Self.nice || setpriority(PRIO_PROCESS, id_t(pid), Self.nice) == 0 { lowered.insert(pid) }
        }
        return lowered
    }
}
