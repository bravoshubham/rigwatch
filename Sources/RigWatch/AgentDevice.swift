import Foundation

/// agent-device (an MCP tool agents use to drive phones, emulators and simulators) keeps a claim per device
/// for the agent session using it, and boots a claimed simulator again whenever it finds it shut down. So
/// a device it holds is shut down through agent-device itself (`close --session S --shutdown`), which ends
/// the claim; `simctl shutdown` alone only lasts until agent-device notices. Claims are read, never written.
enum AgentDevice {
    struct Claim: Equatable {
        let session: String        // agent-device's session name
        let workspace: String      // the folder the agent works in
        let since: Date
        var stateDir: String? = nil   // the agent-device home of the daemon that owns the session (AGENT_DEVICE_STATE_DIR)
        var key = ""                  // the device and when this claim was made: tells it apart from a later claim on the same device
    }

    /// RIGWATCH_AGENT_DEVICE_DIR stands in for ~/.agent-device (used to test without the tool installed).
    static let dir = ProcessInfo.processInfo.environment["RIGWATCH_AGENT_DEVICE_DIR"] ?? Sh.home + "/.agent-device"
    /// RIGWATCH_AGENT_DEVICE_CLI stands in for the agent-device command (used to test without the tool installed).
    static let cli = ([ProcessInfo.processInfo.environment["RIGWATCH_AGENT_DEVICE_CLI"]].compactMap { $0 } + ["/opt/homebrew/bin/agent-device", "/usr/local/bin/agent-device"])
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    private static var cache: (stamp: Date, at: Date, claims: [String: Claim]) = (.distantPast, .distantPast, [:])
    private static let lock = NSLock()

    /// Live claims by device id (simulator UDID, adb serial). A claim counts only while the daemon that
    /// made it is still the same running process.
    static func claims() -> [String: Claim] {
        let folder = dir + "/device-claims", fm = FileManager.default
        guard let stamp = (try? fm.attributesOfItem(atPath: folder))?[.modificationDate] as? Date else { return [:] }
        lock.lock(); defer { lock.unlock() }
        // Re-read when the folder changes, and every 10 s anyway: a daemon can exit without touching it.
        if stamp == cache.stamp, Date().timeIntervalSince(cache.at) < 10 { return cache.claims }
        var out: [String: Claim] = [:]
        let ignored = stale()
        for f in (try? fm.contentsOfDirectory(atPath: folder)) ?? [] where f.hasSuffix(".json") {
            guard let d = fm.contents(atPath: folder + "/" + f),
                  let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let dev = j["device"] as? [String: Any], let id = dev["id"] as? String,
                  let session = j["session"] as? String,
                  let owner = (j["ownerPid"] as? NSNumber)?.int32Value, kill(owner, 0) == 0 || errno == EPERM else { continue }
            let ms = (j["createdAtMs"] as? NSNumber)?.doubleValue
            let key = "\(id) \(j["ownerToken"] as? String ?? "") \(ms.map { String(Int64($0)) } ?? f)"
            guard !ignored.contains(key) else { continue }
            let since = ms.map { Date(timeIntervalSince1970: $0 / 1000) }
                ?? ((try? fm.attributesOfItem(atPath: folder + "/" + f))?[.modificationDate] as? Date) ?? Date()
            // stateDir is <home>/sessions/<name>: several agent-device daemons, each with its own home, share the claims folder.
            let home = (j["stateDir"] as? String).flatMap { dir in dir.range(of: "/sessions/").map { String(dir[..<$0.lowerBound]) } }
            out[id] = Claim(session: session, workspace: j["workspace"] as? String ?? "", since: since, stateDir: home, key: key)
        }
        cache = (stamp, Date(), out)
        return out
    }

    /// Ends the agent-device session that holds the device, and shuts the device down with it unless told not to.
    static func release(_ c: Claim, deviceName: String, shutDown: Bool = true) -> String {
        guard let cli else { return "Could not release \(deviceName): agent-device holds it but its command was not found\(shutDown ? ", so it would boot it again" : "")." }
        let r = ask(cli, ["close", "--session", c.session] + (shutDown ? ["--shutdown"] : []), for: c)
        guard r.code == 0 else {
            let why = (r.err.isEmpty ? r.out : r.err).trimmingCharacters(in: .whitespacesAndNewlines).prefix(240)
            // An earlier close can end the session and still fail, leaving its claim file behind; nothing ever removes
            // that claim. When the daemon confirms the session is gone, the hold is stale and is ignored from now on.
            if why.contains("SESSION_NOT_FOUND"), let live = sessions(cli, for: c), !live.contains(c.session) {
                forget(c)
                if !shutDown { return "agent-device had already ended session \(c.session) but left its hold on \(deviceName) behind; RigWatch ignores that hold now. \(deviceName) keeps running and is free for other sessions." }
            }
            return "agent-device close failed for session \(c.session) (exit \(r.code)): \(why)"
        }
        if !shutDown {
            // Confirm the hold is really gone rather than trusting the exit code.
            cache = (.distantPast, .distantPast, [:])
            return claims().values.contains { $0.session == c.session } ? "agent-device still lists a hold for session \(c.session) on \(deviceName); it was not released."
                : "Released \(deviceName) from agent-device session \(c.session). It keeps running and is free for other sessions."
        }
        return "Ended agent-device session \(c.session) and shut down \(deviceName); it stays off until an agent claims it again."
    }

    /// Runs agent-device against the daemon that owns the session, from the session's workspace: agent-device keeps sessions per home and per workspace.
    private static func ask(_ cli: String, _ args: [String], for c: Claim) -> Sh.Result {
        Sh.run(cli, args, cwd: FileManager.default.fileExists(atPath: c.workspace) ? c.workspace : nil,
               env: c.stateDir.map { ["AGENT_DEVICE_STATE_DIR": $0] } ?? [:], timeout: 120)
    }

    /// The names of the sessions that daemon has open, or nil when it could not be asked.
    private static func sessions(_ cli: String, for c: Claim) -> Set<String>? {
        let r = ask(cli, ["session", "list", "--json"], for: c)
        guard r.code == 0, let j = (try? JSONSerialization.jsonObject(with: r.data)) as? [String: Any], j["success"] as? Bool == true,
              let list = (j["data"] as? [String: Any])?["sessions"] as? [Any] else { return nil }
        return Set(list.compactMap { ($0 as? String) ?? (($0 as? [String: Any]).flatMap { ($0["name"] ?? $0["session"]) as? String }) })
    }

    // MARK: claims left behind by ended sessions

    static let staleFile = Rules.dir + "/stale-device-claims.json"

    static func stale() -> Set<String> {
        Set(FileManager.default.contents(atPath: staleFile).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [])
    }

    static func forget(_ c: Claim) {
        guard !c.key.isEmpty else { return }
        var all = (FileManager.default.contents(atPath: staleFile).flatMap { try? JSONDecoder().decode([String].self, from: $0) }) ?? []
        all = Array((all.filter { $0 != c.key } + [c.key]).suffix(100))
        Rules.write(try? JSONEncoder().encode(all), to: staleFile)
        lock.lock(); cache = (.distantPast, .distantPast, [:]); lock.unlock()
    }
}
