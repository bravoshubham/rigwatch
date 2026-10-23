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

    var ownerAlive: Bool { ProcSampler.startTime(ownerPid) == ownerStart }
    var live: Bool { until > Date() && ownerAlive }
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

    /// Called by the hook for every command: a session naming a device it leases keeps the lease going, and
    /// a session naming a device leased to another session is told so. Returns that note, if any.
    static func noteCommand(_ cmd: String, session: String?) -> String? {
        let ids = Rules.matches(Rules.deviceIds, cmd)
        guard !ids.isEmpty, FileManager.default.fileExists(atPath: file) else { return nil }
        var others: [Lease] = []
        edit { list in
            for i in list.indices where ids.contains(list[i].device) {
                if let session, list[i].session == session { list[i].until = max(list[i].until, Date().addingTimeInterval(renewOnUse)) }
                else { others.append(list[i]) }
            }
        }
        guard !others.isEmpty else { return nil }
        return others.map {
            "RigWatch: \($0.name) (\($0.device)) is leased to another agent session until \(time($0.until))\($0.purpose.isEmpty ? "" : " for \"\($0.purpose)\""). " +
            "Using it may break that session's run. Get a device of your own with the rigwatch MCP tool acquire_device."
        }.joined(separator: "\n")
    }

    static func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }

    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
