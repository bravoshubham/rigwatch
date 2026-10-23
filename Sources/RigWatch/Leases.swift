import Foundation

/// A device lent to one agent session through RigWatch's MCP server (`acquire_device`). While a lease is live
/// no other session is handed the device and the clean-up leaves it alone. A lease ends when it runs out
/// unrenewed, when it is released, or as soon as the Claude Code process that took it exits.
struct Lease: Codable, Equatable {
    var device: String             // serial or UDID; "avd:NAME" while an emulator RigWatch started is still booting
    var name: String
    var platform: String           // android, ios
    var physical = false
    var session: String            // CLAUDE_CODE_SESSION_ID of the session that took it, or "pid:N"
    var ownerPid: Int32            // the agent process the MCP server runs under
    var ownerStart: UInt64         // with ownerPid, names one process run
    var purpose = ""
    var since: Date
    var until: Date
    var booted = false             // RigWatch booted it for this lease, so releasing it shuts it down
    var implicit: Bool?            // taken by a session using the device directly (adb -s, simctl, a device tool), not through acquire_device

    var isImplicit: Bool { implicit == true }
    var ownerAlive: Bool { ProcSampler.startTime(ownerPid) == ownerStart }
    /// Owned by the agent process (the session's claude process for an implicit lease), so a lease ends with
    /// its session. An implicit lease whose agent process wasn't found lasts only until it runs out; older
    /// RigWatch versions drop those, so the owner is filled in whenever it can be.
    var live: Bool { until > Date() && (ownerAlive || (isImplicit && ownerPid == 0)) }
    /// Whether this lease is for that device: by id, or by AVD name while its emulator boots.
    func covers(_ d: Device) -> Bool { device == d.id || (device.hasPrefix("avd:") && d.kind == .emulator && device.dropFirst(4) == d.name) }
}

enum Leases {
    static let file = Rules.dir + "/leases.json"
    static let defaultMinutes = 30, maxMinutes = 240
    /// A command of the leasing session that names its device keeps the lease at least this long.
    static let renewOnUse: TimeInterval = 20 * 60

    /// Live leases; lapsed ones are dropped from the file as a side effect.
    static func live() -> [Lease] {
        guard FileManager.default.fileExists(atPath: file) else { return [] }
        return edit { $0 }
    }

    /// The lease list under an exclusive lock, dead leases dropped; written back only when it changed.
    @discardableResult
    static func edit<T>(_ body: (inout [Lease]) -> T) -> T {
        try? FileManager.default.createDirectory(atPath: Rules.dir, withIntermediateDirectories: true)
        let fd = open(Rules.dir + "/leases.lock", O_RDWR | O_CREAT, 0o644)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { close(fd) } }
        let before = FileManager.default.contents(atPath: file).flatMap { try? decoder.decode([Lease].self, from: $0) } ?? []
        var list = before.filter(\.live)
        for gone in before where !gone.live { Rules.log("lease: \(gone.name) (\(gone.device)) ended for session \(gone.session): \(gone.ownerAlive ? "not renewed" : "its agent exited")") }
        let out = body(&list)
        if list != before { Rules.write(try? encoder.encode(list), to: file) }
        return out
    }

    /// Called by the hook for every command. Using a device counts as holding it: a session naming a device
    /// nobody holds gets an implicit lease on it, renewed by each use, so acquire_device won't hand it to
    /// another session. A session naming its own device keeps it; one naming another's is told so.
    static func noteCommand(_ cmd: String, session: String?) -> String? {
        guard let session, !session.isEmpty else { return nil }
        let ids = namedDevices(cmd)
        guard !ids.isEmpty else { return nil }
        let now = Date(), owner = agentProcess()
        var others: [Lease] = []
        edit { list in
            for id in ids {
                if let i = list.firstIndex(where: { $0.device == id }) {
                    if list[i].session == session {
                        list[i].until = max(list[i].until, now.addingTimeInterval(renewOnUse))
                        if list[i].isImplicit, list[i].ownerPid == 0, let a = owner { list[i].ownerPid = a.pid; list[i].ownerStart = a.start }
                    } else { others.append(list[i]) }
                } else {
                    let ios = id.count == 36 && id.contains("-")
                    list.append(Lease(device: id, name: id, platform: ios ? "ios" : "android", physical: !ios && !id.hasPrefix("emulator-"),
                                      session: session, ownerPid: owner?.pid ?? 0, ownerStart: owner?.start ?? 0,
                                      since: now, until: now.addingTimeInterval(renewOnUse), implicit: true))
                }
            }
        }
        guard !others.isEmpty else { return nil }
        return others.map {
            ($0.isImplicit ? "RigWatch: \($0.device) is in use by another agent session (it ran a command on it in the last \(Int(renewOnUse / 60)) minutes). "
                : "RigWatch: \($0.name) (\($0.device)) is leased to another agent session until \(time($0.until))\($0.purpose.isEmpty ? "" : " for \"\($0.purpose)\""). ") +
            "Using it may break that session's run. Get a device of your own with the rigwatch MCP tool acquire_device."
        }.joined(separator: "\n")
    }

    /// The Claude Code process this hook runs under (Desktop and CLI sessions both run a process named claude).
    static func agentProcess() -> (pid: Int32, start: UInt64)? {
        var pid = getppid()
        for _ in 0..<15 where pid > 1 {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return nil }
            let name = withUnsafeBytes(of: &info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if name == "claude", let st = ProcSampler.startTime(pid) { return (pid, st) }
            pid = Int32(info.pbi_ppid)
        }
        return nil
    }

    // MARK: which devices a command uses

    /// Emulator serials and UDIDs anywhere in the command, plus a phone's serial where a device is chosen:
    /// adb -s X, ANDROID_SERIAL=X, --serial/--udid X, or a serial/deviceId/udid field of a device tool.
    static let serialArg = try! NSRegularExpression(pattern: #"(?:(?<![\w-])-s\s+|ANDROID_SERIAL=|--serial[=\s]+|--udid[=\s]+|"(?:serial|deviceId|device_id|deviceSerial|udid|device)"\s*:\s*)["']?([A-Za-z0-9][A-Za-z0-9._:-]{5,})"#)
    /// adb with no device chosen: it talks to the only device connected.
    static let adbBare = try! NSRegularExpression(pattern: #"(?:^|[\s;&|(/`])adb\s+(?!-s\b|-[de]\b|devices\b|kill-server|start-server|version\b|connect\b|disconnect\b|pair\b|help\b)"#)
    /// Gradle installing or running device tests: every connected Android device unless ANDROID_SERIAL picks one.
    static let gradleDevice = try! NSRegularExpression(pattern: #"gradlew?\s[^;&|]*\b(?:install\w*|connected\w*Test)\b"#)

    static func namedDevices(_ cmd: String) -> [String] {
        var ids = Set(Rules.matches(Rules.deviceIds, cmd))
        let serials = Rules.matches(serialArg, cmd, group: 1).filter { !ids.contains($0) }
        let pick = cmd.contains("ANDROID_SERIAL=") || cmd.range(of: #"(?<![\w-])-s\s"#, options: .regularExpression) != nil
        let bare = !pick && Rules.has(adbBare, cmd), gradle = !pick && Rules.has(gradleDevice, cmd)
        if !serials.isEmpty || bare || gradle {
            // Only serials adb really has: a -s of some other tool (grep -s, sort -s) is not a device.
            let connected = DeviceManager.adbSerials(states: ["device"])
            ids.formUnion(serials.filter(connected.contains))
            if bare, connected.count == 1 { ids.formUnion(connected) }
            if gradle { ids.formUnion(connected) }
        }
        return ids.sorted()
    }

    static func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }

    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
