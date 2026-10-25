import Darwin
import Foundation

/// Hands devices to agent sessions: `acquire_device` leases a free connected phone, then a free running
/// emulator or simulator, and boots one only when none is free. Used by RigWatch's MCP server.
enum DeviceManager {
    struct Failure: Error { let message: String }

    /// The asking agent session: Claude Code passes its session id to the MCP servers it starts.
    static var session: String { ProcessInfo.processInfo.environment["CLAUDE_CODE_SESSION_ID"].flatMap { $0.isEmpty ? nil : $0 } ?? "pid:\(getppid())" }
    static var owner: (pid: Int32, start: UInt64) { (getppid(), ProcSampler.startTime(getppid()) ?? 0) }

    static func platform(of d: Device) -> String { d.kind == .simulator ? "ios" : "android" }

    static let emulatorPath: String? = {
        let env = ProcessInfo.processInfo.environment
        let roots = [env["ANDROID_HOME"], env["ANDROID_SDK_ROOT"], Sh.home + "/Library/Android/sdk"].compactMap { $0 }
        return roots.map { $0 + "/emulator/emulator" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    // MARK: what exists

    static func running() -> [Device] { DeviceSampler().sample(procs: ProcSampler().sample(), deep: false).filter { $0.state == "device" || $0.kind == .simulator } }

    static func avds() -> [String] {
        guard let emulatorPath else { return [] }
        return Sh.run(emulatorPath, ["-list-avds"], timeout: 20).out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("INFO") && !$0.contains(" ") }
    }

    struct Sim { let udid: String, name: String, runtime: String, version: [Int], state: String }
    /// Available simulators, newest iOS first, iPhones before iPads.
    static func simulators() -> [Sim] {
        let r = Sh.run("/usr/bin/xcrun", ["simctl", "list", "devices", "available", "-j"], timeout: 30)
        guard let j = try? JSONSerialization.jsonObject(with: r.data) as? [String: Any], let devs = j["devices"] as? [String: [[String: Any]]] else { return [] }
        var out: [Sim] = []
        for (rt, list) in devs where rt.contains(".iOS-") {
            let v = rt.split(separator: "-").dropFirst().compactMap { Int($0) }
            let runtime = "iOS " + v.map(String.init).joined(separator: ".")
            for x in list {
                guard let u = x["udid"] as? String, let n = x["name"] as? String else { continue }
                out.append(Sim(udid: u, name: n, runtime: runtime, version: v, state: x["state"] as? String ?? ""))
            }
        }
        return out.sorted { a, b in
            if a.version != b.version { return a.version.lexicographicallyPrecedes(b.version) == false }
            if a.name.hasPrefix("iPhone") != b.name.hasPrefix("iPhone") { return a.name.hasPrefix("iPhone") }
            return a.name < b.name
        }
    }

    // MARK: tools

    static func list(platform: String?) -> [String: Any] {
        let leases = Leases.live(), me = session, devs = running()
        let rows: [[String: Any]] = devs.filter { platform == nil || self.platform(of: $0) == platform }.map { d in
            var row: [String: Any] = ["id": d.id, "name": d.name, "platform": self.platform(of: d), "kind": d.kind.rawValue, "state": d.state]
            if let l = leases.first(where: { $0.covers(d) }) {
                row["lease"] = ["yours": l.session == me, "session": l.session, "until": iso(l.until), "purpose": l.purpose, "in_use_without_acquire": l.isImplicit]
            } else if let c = d.claim {
                row["held_by_agent_device"] = ["session": c.session, "workspace": c.workspace]
            } else { row["free"] = true }
            return row
        }
        var out: [String: Any] = ["devices": rows, "your_session": me]
        if platform != "ios" { out["android_avds_to_boot"] = avds().filter { a in !devs.contains { $0.kind == .emulator && $0.name == a } } }
        if platform != "android" { out["ios_simulators_to_boot"] = simulators().filter { $0.state == "Shutdown" }.prefix(12).map { "\($0.name) · \($0.runtime) · \($0.udid)" } }
        if platform != "android" { let phones = Rules.iPhones(); if !phones.isEmpty { out["connected_iphones"] = phones } }
        return out
    }

    static func acquire(platform: String, want: String?, minutes: Int, purpose: String, headless: Bool) throws -> [String: Any] {
        guard platform == "android" || platform == "ios" else { throw Failure(message: "platform must be android or ios") }
        let me = session, (opid, ostart) = owner, mins = min(max(minutes, 1), Leases.maxMinutes)
        let until = Date().addingTimeInterval(TimeInterval(mins * 60))
        let s = RuleSettings.load()
        func matches(_ d: Device) -> Bool { want.map { w in d.id == w || d.name.caseInsensitiveCompare(w) == .orderedSame } ?? true }

        // Pick under the lease lock so two sessions asking at once never get the same device.
        enum Pick { case have(Device, Lease), take(Device), bootAVD(String), bootSim(Sim) }
        let devs = running(), sims = platform == "ios" ? simulators() : [], avdList = platform == "android" ? avds() : []
        let pick: Result<Pick, Failure> = Leases.edit { list in
            let now = list
            let taken = { (d: Device) in now.contains { $0.covers(d) && $0.session != me } || (d.claim != nil) }
            let mine = devs.filter { d in self.platform(of: d) == platform && now.contains { $0.covers(d) && $0.session == me } && matches(d) }
            if let d = mine.first, let i = list.firstIndex(where: { $0.covers(d) }) {
                list[i].until = max(list[i].until, until); if !purpose.isEmpty { list[i].purpose = purpose }
                if list[i].isImplicit {   // it was using the device already: now it holds it properly
                    list[i].implicit = nil; list[i].ownerPid = opid; list[i].ownerStart = ostart; list[i].name = d.name
                }
                return .success(.have(d, list[i]))
            }
            let free = devs.filter { self.platform(of: $0) == platform && !taken($0) && matches($0) }
            // A connected phone first (the Rules' "physical devices first"), then a running virtual device.
            let phone = free.first { $0.kind == .phone }, virt = free.first { $0.kind != .phone }
            let d = want != nil ? free.first : (s.physicalFirst ? phone ?? virt : virt ?? phone)
            if let d {
                list.append(Lease(device: d.id, name: d.name, platform: platform, physical: d.kind == .phone, session: me, ownerPid: opid, ownerStart: ostart,
                                  purpose: purpose, since: Date(), until: until, booted: false))
                return .success(.take(d))
            }
            if let w = want, devs.contains(where: { self.platform(of: $0) == platform && ($0.id == w || $0.name.caseInsensitiveCompare(w) == .orderedSame) }) {
                return .failure(Failure(message: "\(w) is running but held by another session. Ask for any \(platform) device, or wait for it to be released."))
            }
            if let cap = Rules.virtualCap(platform, s) {
                let virt = devs.filter { $0.kind != .phone && self.platform(of: $0) == platform }
                if virt.count >= cap {
                    let who = virt.map { d in "\(d.name) (\(now.first { $0.covers(d) }.map { $0.isImplicit ? "in use by session \($0.session)" : "leased to session \($0.session)" } ?? (d.claim.map { "held by agent-device for \($0.session)" } ?? "running")))" }
                    return .failure(Failure(message: "No \(platform) device is free, and \(virt.count) \(platform == "ios" ? "simulator" : "emulator")\(virt.count == 1 ? " already runs" : "s already run"), the most the Rules allow: \(who.joined(separator: "; ")). Wait and ask again, or ask the user to raise the limit on RigWatch's Rules page."))
                }
            }
            if Rules.pressure() >= 4 { return .failure(Failure(message: "Memory pressure is critical, so RigWatch won't boot another device now. Free memory or wait, then ask again.")) }
            if platform == "android" {
                let running = Set(devs.filter { $0.kind == .emulator }.map(\.name))
                let bookedAVDs = Set(list.filter { $0.device.hasPrefix("avd:") }.map { String($0.device.dropFirst(4)) })
                guard let avd = avdList.first(where: { a in !running.contains(a) && !bookedAVDs.contains(a) && (want.map { $0 == a } ?? true) }) else {
                    return .failure(Failure(message: emulatorPath == nil ? "The Android emulator is not installed (no emulator in the Android SDK)."
                        : want.map { "No AVD named \($0) is free to boot. AVDs: \(avdList.joined(separator: ", "))." } ?? "Every AVD is already running and leased. Create another AVD or wait for one to be released."))
                }
                list.append(Lease(device: "avd:" + avd, name: avd, platform: platform, session: me, ownerPid: opid, ownerStart: ostart,
                                  purpose: purpose, since: Date(), until: until, booted: true))
                return .success(.bootAVD(avd))
            }
            guard let sim = sims.first(where: { x in x.state == "Shutdown" && (want.map { w in x.udid == w || x.name.caseInsensitiveCompare(w) == .orderedSame } ?? true) }) else {
                return .failure(Failure(message: want.map { "No shut-down simulator named \($0)." } ?? "No shut-down iOS simulator is available to boot."))
            }
            list.append(Lease(device: sim.udid, name: sim.name, platform: platform, session: me, ownerPid: opid, ownerStart: ostart,
                              purpose: purpose, since: Date(), until: until, booted: true))
            return .success(.bootSim(sim))
        }

        switch try pick.get() {
        case .have(let d, let l): return granted(d.id, d.name, platform, l.until, booted: false, note: "You already held this device; the lease is extended.")
        case .take(let d):
            Rules.touch(d.id)
            Rules.log("lease: \(d.name) (\(d.id)) to session \(me) until \(Leases.time(until))\(purpose.isEmpty ? "" : ": " + purpose)")
            return granted(d.id, d.name, platform, until, booted: false, note: d.kind == .phone ? "A physical device: install and test on it as usual." : nil)
        case .bootAVD(let avd):
            do {
                let serial = try bootEmulator(avd, headless: headless)
                Leases.edit { list in if let i = list.firstIndex(where: { $0.device == "avd:" + avd && $0.session == me }) { list[i].device = serial } }
                Rules.log("lease: booted \(avd) (\(serial)) for session \(me) until \(Leases.time(until))")
                return granted(serial, avd, platform, until, booted: true, note: nil)
            } catch { Leases.edit { $0.removeAll { $0.device == "avd:" + avd && $0.session == me } }; throw error }
        case .bootSim(let sim):
            do {
                try bootSimulator(sim)
                Rules.log("lease: booted \(sim.name) (\(sim.udid)) for session \(me) until \(Leases.time(until))")
                return granted(sim.udid, sim.name, platform, until, booted: true, note: nil)
            } catch { Leases.edit { $0.removeAll { $0.device == sim.udid && $0.session == me } }; throw error }
        }
    }

    private static func granted(_ id: String, _ name: String, _ platform: String, _ until: Date, booted: Bool, note: String?) -> [String: Any] {
        var out: [String: Any] = ["id": id, "name": name, "platform": platform, "leased_until": iso(until), "booted_for_you": booted,
                                  "use": platform == "ios" ? "xcrun simctl … \(id)   (xcodebuild: -destination 'id=\(id)')" : "adb -s \(id) …   (Gradle: ANDROID_SERIAL=\(id))",
                                  "renew": "Commands that name \(id) keep the lease going; call renew_device for long waits, release_device when done."]
        if let note { out["note"] = note }
        return out
    }

    static func renew(_ id: String, minutes: Int) throws -> [String: Any] {
        let me = session, until = Date().addingTimeInterval(TimeInterval(min(max(minutes, 1), Leases.maxMinutes) * 60))
        let l: Lease? = Leases.edit { list in
            guard let i = list.firstIndex(where: { ($0.device == id || $0.name == id) && $0.session == me }) else { return nil }
            list[i].until = max(list[i].until, until); return list[i]
        }
        guard let l else { throw Failure(message: "You hold no lease on \(id). Call acquire_device.") }
        Rules.touch(l.device)
        return ["id": l.device, "name": l.name, "leased_until": iso(l.until)]
    }

    static func release(_ id: String, shutdown: Bool?) throws -> [String: Any] {
        let me = session
        let l: Lease? = Leases.edit { list in
            guard let i = list.firstIndex(where: { ($0.device == id || $0.name == id) && $0.session == me }) else { return nil }
            return list.remove(at: i)
        }
        guard let l else { throw Failure(message: "You hold no lease on \(id).") }
        Rules.log("lease: session \(me) released \(l.name) (\(l.device))")
        let off = !l.physical && (shutdown ?? l.booted)
        guard off else { return ["released": l.device, "shut_down": false, "note": l.physical ? "A physical device stays connected." : "It keeps running for the next session that asks."] }
        guard let d = running().first(where: { $0.id == l.device }) else { return ["released": l.device, "shut_down": false, "note": "It was no longer running."] }
        if Leases.live().contains(where: { $0.covers(d) }) { return ["released": l.device, "shut_down": false, "note": "Another session leases it now."] }
        if d.claim != nil { return ["released": l.device, "shut_down": false, "note": "agent-device holds it for a session, so it was left running."] }
        return ["released": l.device, "shut_down": true, "result": DeviceSampler.shutDown(d)]
    }

    // MARK: booting

    /// Starts an AVD in its own session (so it outlives this MCP server) and waits until Android has booted.
    static func bootEmulator(_ avd: String, headless: Bool) throws -> String {
        guard let emulatorPath else { throw Failure(message: "The Android emulator is not installed.") }
        let before = Set(adbSerials())
        let logPath = Rules.dir + "/emulator-\(avd).log"
        var args = [emulatorPath, "-avd", avd, "-no-boot-anim"]
        if headless { args.append("-no-window") }
        guard let pid = spawnDetached(args, log: logPath) else { throw Failure(message: "Could not start the emulator for \(avd).") }
        // It is this server's child: collect it when it exits, or it lingers as a zombie that still looks alive.
        DispatchQueue.global(qos: .background).async { var st: Int32 = 0; waitpid(pid, &st, 0) }
        Rules.touch("boot-" + avd)
        let deadline = Date().addingTimeInterval(240)
        var serial: String?
        while Date() < deadline {
            if kill(pid, 0) != 0, serial == nil {
                let tail = (try? String(contentsOfFile: logPath, encoding: .utf8))?.split(separator: "\n").suffix(6).joined(separator: "\n") ?? ""
                throw Failure(message: "The emulator for \(avd) exited while starting.\n\(tail)")
            }
            if serial == nil {
                serial = Set(adbSerials()).subtracting(before).first { s in
                    s.hasPrefix("emulator-") && DeviceSampler.avdName(s) == avd
                }
                if let serial { Rules.touch("boot-" + serial) }
            }
            if let serial, Sh.run(Sh.adb, ["-s", serial, "shell", "getprop", "sys.boot_completed"], timeout: 10).out.trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
                Rules.touch(serial)
                return serial
            }
            usleep(2_000_000)
        }
        // Don't leave a half-started emulator behind: nobody holds it and it would only use memory.
        if let serial { _ = Sh.run(Sh.adb, ["-s", serial, "emu", "kill"], timeout: 10) }
        kill(pid, SIGTERM)
        throw Failure(message: "\(avd) did not finish booting within 4 minutes, so RigWatch stopped it. See \(Views.tilde(logPath)).")
    }

    static func bootSimulator(_ sim: Sim) throws {
        Rules.touch("boot-" + sim.udid); Rules.touch("boot-" + sim.name)
        let b = Sh.run("/usr/bin/xcrun", ["simctl", "boot", sim.udid], timeout: 120)
        guard b.code == 0 || b.err.contains("current state: Booted") else { throw Failure(message: "simctl boot failed: \(b.err.prefix(300))") }
        let s = Sh.run("/usr/bin/xcrun", ["simctl", "bootstatus", sim.udid, "-b"], timeout: 240)
        guard s.code == 0 else { throw Failure(message: "\(sim.name) did not finish booting: \(s.err.prefix(300))") }
        Rules.touch(sim.udid)
    }

    static func adbSerials(states: Set<String>? = nil) -> [String] {
        Sh.run(Sh.adb, ["devices"], timeout: 10).out.split(whereSeparator: \.isNewline).dropFirst().compactMap { line -> String? in
            let f = line.split(separator: "\t")
            guard f.count == 2, states.map({ $0.contains(String(f[1])) }) ?? true else { return nil }
            return String(f[0])
        }
    }

    /// posix_spawn in a new session, output to a log file, with RigWatch's tool environment (which keeps the
    /// agent's session id, so the emulator's card shows who it was booted for).
    static func spawnDetached(_ argv: [String], log: String) -> pid_t? {
        var attr: posix_spawnattr_t? = nil, fa: posix_spawn_file_actions_t? = nil
        posix_spawnattr_init(&attr); posix_spawn_file_actions_init(&fa)
        defer { posix_spawnattr_destroy(&attr); posix_spawn_file_actions_destroy(&fa) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fa, 1, log, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        posix_spawn_file_actions_adddup2(&fa, 1, 2)
        let c = argv.map { strdup($0) } + [nil]
        let env = Sh.env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { c.forEach { free($0) }; env.forEach { free($0) } }
        var pid: pid_t = 0
        return posix_spawn(&pid, argv[0], &fa, &attr, c, env) == 0 ? pid : nil
    }

    static func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }
}

/// `RigWatch mcp`: a Model Context Protocol server on stdin/stdout (one JSON-RPC message per line).
enum MCPServer {
    static let versions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    static let tools: [[String: Any]] = [
        tool("list_devices", "List the emulators, simulators and phones on this Mac: which are free, which are leased (and whether to you), and which can be booted.",
             ["platform": ["type": "string", "enum": ["android", "ios"], "description": "Only this platform."]], required: []),
        tool("acquire_device", "Get a device for this session. Returns a free connected phone or a free running emulator/simulator, and boots one only when none is free (this can take a few minutes). The device is leased to you: no other session is given it and RigWatch's clean-up leaves it alone. Use the returned id with adb -s / simctl / xcodebuild -destination.",
             ["platform": ["type": "string", "enum": ["android", "ios"]],
              "name": ["type": "string", "description": "A specific AVD, simulator name, serial or UDID. Omit to take any free one."],
              "minutes": ["type": "integer", "minimum": 1, "maximum": Leases.maxMinutes, "description": "Lease length (default \(Leases.defaultMinutes)). Commands that name the device renew it."],
              "purpose": ["type": "string", "description": "What you need it for, shown to the user."],
              "headless": ["type": "boolean", "description": "Boot an emulator without a window (default true)."]], required: ["platform"]),
        tool("renew_device", "Extend your lease on a device, for example before a long build.",
             ["id": ["type": "string"], "minutes": ["type": "integer", "minimum": 1, "maximum": Leases.maxMinutes]], required: ["id"]),
        tool("release_device", "Give a device back when you are done. A device RigWatch booted for you is shut down unless shutdown is false; one that was already running keeps running.",
             ["id": ["type": "string"], "shutdown": ["type": "boolean"]], required: ["id"]),
        tool("prepare_worktree", "Prepare a new worktree before its first install or build: copies in node_modules, CocoaPods' Pods and Xcode's package and module caches from another worktree or RigWatch's store when they match this worktree's lockfiles (an APFS clone: seconds, no extra disk). The install afterwards only checks them. Builds and installs run through RigWatch do this on their own; call it to have it done up front.",
             ["path": ["type": "string", "description": "The worktree (or any folder in it). Defaults to the current directory."],
              "derived_data_path": ["type": "string", "description": "The -derivedDataPath your xcodebuild uses, if any, relative to the worktree."]], required: []),
        tool("build_queue", "Show RigWatch's build queue: Android and iOS slots, running and waiting builds, and memory pressure.", [:], required: []),
    ]

    static func tool(_ name: String, _ desc: String, _ props: [String: Any], required: [String]) -> [String: Any] {
        ["name": name, "description": desc, "inputSchema": ["type": "object", "properties": props, "required": required, "additionalProperties": false]]
    }

    static let instructions = """
    RigWatch manages the emulators, simulators and phones on this Mac for every agent session. Before using a device, \
    call acquire_device with the platform; use the id it returns; call release_device when you are done. Do not boot \
    emulators or simulators yourself, and do not use a device leased to another session. In a new worktree, call \
    prepare_worktree before the first install or build: it copies in node_modules, Pods and Xcode caches that match \
    its lockfiles, so the first build isn't a cold one.
    """

    static func main() -> Int32 {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let msg = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
                send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]]); continue
            }
            guard let method = msg["method"] as? String else { continue }   // a response to us: we send no requests
            let id = msg["id"]
            let params = msg["params"] as? [String: Any] ?? [:]
            guard id != nil else { continue }   // notifications: initialized, cancelled
            switch method {
            case "initialize":
                let asked = params["protocolVersion"] as? String ?? versions[0]
                reply(id, ["protocolVersion": versions.contains(asked) ? asked : versions[0],
                           "capabilities": ["tools": ["listChanged": false]],
                           "serverInfo": ["name": "rigwatch", "version": AppCopy.ownVersion],
                           "instructions": instructions])
            case "ping": reply(id, [:])
            case "tools/list": reply(id, ["tools": tools])
            case "tools/call": reply(id, call(params["name"] as? String ?? "", params["arguments"] as? [String: Any] ?? [:]))
            default: send(["jsonrpc": "2.0", "id": id!, "error": ["code": -32601, "message": "Method not found: \(method)"]])
            }
        }
        return 0
    }

    static func call(_ name: String, _ a: [String: Any]) -> [String: Any] {
        func str(_ k: String) -> String? { (a[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        func int(_ k: String) -> Int? { (a[k] as? NSNumber)?.intValue }
        do {
            let out: Any
            switch name {
            case "list_devices": out = DeviceManager.list(platform: str("platform"))
            case "acquire_device":
                guard let p = str("platform") else { throw DeviceManager.Failure(message: "platform is required (android or ios)") }
                out = try DeviceManager.acquire(platform: p, want: str("name"), minutes: int("minutes") ?? Leases.defaultMinutes,
                                                purpose: str("purpose") ?? "", headless: a["headless"] as? Bool ?? true)
            case "renew_device":
                guard let id = str("id") else { throw DeviceManager.Failure(message: "id is required") }
                out = try DeviceManager.renew(id, minutes: int("minutes") ?? Leases.defaultMinutes)
            case "release_device":
                guard let id = str("id") else { throw DeviceManager.Failure(message: "id is required") }
                out = try DeviceManager.release(id, shutdown: a["shutdown"] as? Bool)
            case "build_queue": out = Rules.status()
            case "prepare_worktree":
                let start = (str("path").map { ($0 as NSString).expandingTildeInPath }) ?? FileManager.default.currentDirectoryPath
                guard let root = Rules.roots("", cwd: start).first else { throw DeviceManager.Failure(message: "\(start) is not inside a git worktree.") }
                var notes = DepCache.prepare(root)
                if let dd = str("derived_data_path") { notes += DepCache.prepareDerivedData(cmd: "xcodebuild -derivedDataPath '\(dd)'", cwd: root) }
                let have = DepCache.spots(root).map { s in "\(s.rel.isEmpty ? "" : s.rel + "/")\(s.kind.folder): \(FileManager.default.fileExists(atPath: DepCache.path(root, s.rel) + "/" + s.kind.folder) ? "present" : "missing (no match for this lockfile yet; install it, and RigWatch keeps it for the next worktree)")" }
                out = ["worktree": Views.tilde(root), "done": notes.isEmpty ? ["nothing to copy"] : notes, "now": have]
            default: throw DeviceManager.Failure(message: "Unknown tool \(name)")
            }
            let text = (out as? String) ?? String(decoding: (try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data(), as: UTF8.self)
            return ["content": [["type": "text", "text": text]], "isError": false]
        } catch let f as DeviceManager.Failure {
            return ["content": [["type": "text", "text": f.message]], "isError": true]
        } catch {
            return ["content": [["type": "text", "text": "\(error)"]], "isError": true]
        }
    }

    static func reply(_ id: Any?, _ result: [String: Any]) { send(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]) }
    static func send(_ obj: [String: Any]) {
        guard var d = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
        d.append(0x0A)
        FileHandle.standardOutput.write(d)
    }
}
