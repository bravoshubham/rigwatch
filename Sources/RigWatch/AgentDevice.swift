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
    }

    /// RIGWATCH_AGENT_DEVICE_DIR stands in for ~/.agent-device (used to test without the tool installed).
    static let dir = ProcessInfo.processInfo.environment["RIGWATCH_AGENT_DEVICE_DIR"] ?? Sh.home + "/.agent-device"
    static let cli = ["/opt/homebrew/bin/agent-device", "/usr/local/bin/agent-device"].first { FileManager.default.isExecutableFile(atPath: $0) }

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
        for f in (try? fm.contentsOfDirectory(atPath: folder)) ?? [] where f.hasSuffix(".json") {
            guard let d = fm.contents(atPath: folder + "/" + f),
                  let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let dev = j["device"] as? [String: Any], let id = dev["id"] as? String,
                  let session = j["session"] as? String,
                  let owner = (j["ownerPid"] as? NSNumber)?.int32Value, kill(owner, 0) == 0 || errno == EPERM else { continue }
            let ms = (j["createdAtMs"] as? NSNumber)?.doubleValue
            let since = ms.map { Date(timeIntervalSince1970: $0 / 1000) }
                ?? ((try? fm.attributesOfItem(atPath: folder + "/" + f))?[.modificationDate] as? Date) ?? Date()
            out[id] = Claim(session: session, workspace: j["workspace"] as? String ?? "", since: since)
        }
        cache = (stamp, Date(), out)
        return out
    }

    /// Ends the agent-device session that holds the device and shuts the device down with it.
    static func release(_ c: Claim, deviceName: String) -> String {
        guard let cli else { return "Could not release \(deviceName): agent-device holds it but its command was not found, so it would boot it again." }
        let r = Sh.run(cli, ["close", "--session", c.session, "--shutdown"], timeout: 120)
        guard r.code == 0 else {
            let why = (r.err.isEmpty ? r.out : r.err).trimmingCharacters(in: .whitespacesAndNewlines).prefix(240)
            return "agent-device close failed for session \(c.session) (exit \(r.code)): \(why)"
        }
        return "Ended agent-device session \(c.session) and shut down \(deviceName); it stays off until an agent claims it again."
    }
}
