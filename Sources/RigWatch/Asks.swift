import Foundation

/// "Ask the session" before shutting down a device an agent is using. RigWatch cannot message a session
/// directly, so the question waits in asks.json until the PreToolUse hook sees that session's next Bash or
/// MCP tool call; the hook adds it to that call's context once, and the agent answers with
/// `RigWatch answer ID yes|no [reason]`. A session that makes no tool call never sees it. Nothing here
/// shuts a device down: the answer only changes what the device card offers.
struct Ask: Codable, Equatable {
    var device: String             // device id (serial, UDID)
    var name: String
    var session: String            // Claude Code session id the question is for
    var askedAt: Date
    var state = State.pending
    var deliveredAt: Date?
    var answeredAt: Date?
    var reason = ""
    var answeredBy: String?        // CLAUDE_CODE_SESSION_ID of the answering command, when it had one

    enum State: String, Codable { case pending, delivered, yes, no }

    var answered: Bool { state == .yes || state == .no }
    /// Unanswered questions lapse 30 min after they were asked; answers are kept 30 min after they came.
    var expired: Bool { Date().timeIntervalSince(answeredAt ?? askedAt) > Asks.ttl }
}

enum Asks {
    static let file = Rules.dir + "/asks.json"
    static let ttl: TimeInterval = 1800

    static func load() -> [Ask] {
        (FileManager.default.contents(atPath: file).flatMap { try? decoder.decode([Ask].self, from: $0) } ?? []).filter { !$0.expired }
    }

    /// The list under an exclusive lock, expired entries dropped; written back only when `body` changed it.
    static func edit<T>(_ body: (inout [Ask]) -> T) -> T {
        try? FileManager.default.createDirectory(atPath: Rules.dir, withIntermediateDirectories: true)
        let fd = open(Rules.dir + "/asks.lock", O_RDWR | O_CREAT, 0o644)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { close(fd) } }
        let before = FileManager.default.contents(atPath: file).flatMap { try? decoder.decode([Ask].self, from: $0) } ?? []
        var list = before.filter { !$0.expired }
        let out = body(&list)
        if list != before { Rules.write(try? encoder.encode(list), to: file) }
        return out
    }

    /// Records a question for `session` about `device`, replacing any earlier one about that device.
    static func ask(device: String, name: String, session: String) {
        edit { list in
            list.removeAll { $0.device == device }
            list.append(Ask(device: device, name: name, session: session, askedAt: Date()))
        }
        Rules.log("ask: is it safe to shut down \(name) (\(device))? asked session \(session)")
    }

    static func forget(device: String) { edit { $0.removeAll { $0.device == device } } }

    /// Called by the hook: the questions waiting for this session, marked delivered, as one context note.
    static func deliver(session: String?) -> String? {
        guard let session, !session.isEmpty,
              let d = FileManager.default.contents(atPath: file), String(decoding: d, as: UTF8.self).contains(session) else { return nil }
        let due: [Ask] = edit { list in
            var due: [Ask] = []
            for i in list.indices where list[i].session == session && list[i].state == .pending {
                list[i].state = .delivered; list[i].deliveredAt = Date(); due.append(list[i])
            }
            return due
        }
        guard !due.isEmpty else { return nil }
        for a in due { Rules.log("ask: delivered the question about \(a.name) (\(a.device)) to session \(session)") }
        let me = Rules.quote(Rules.exe)   // the hook's own program: on PATH or not, it has `answer`
        return due.map {
            "RigWatch asks (from the user watching this Mac): is it safe to shut down \($0.name) (\($0.device)) now? " +
            "Answer by running `\(me) answer \($0.device) yes` or `\(me) answer \($0.device) no \"<reason>\"`. " +
            "Answering yes does not shut it down; the user decides. Answer no if you still need the device for this task."
        }.joined(separator: "\n\n")
    }

    /// `RigWatch answer ID yes|no [reason]`
    static func answer(_ a: [String]) -> Int32 {
        guard a.count >= 2, let yes = ["yes": true, "no": false][a[1].lowercased()] else {
            Rules.say("usage: RigWatch answer DEVICE-ID yes|no [reason]"); return 2
        }
        let id = a[0], reason = a.dropFirst(2).joined(separator: " ")
        let by = ProcessInfo.processInfo.environment["CLAUDE_CODE_SESSION_ID"]
        let hit: Ask? = edit { list in
            guard let i = list.firstIndex(where: { $0.device == id || $0.name == id }) else { return nil }
            list[i].state = yes ? .yes : .no
            list[i].answeredAt = Date(); list[i].reason = reason; list[i].answeredBy = by
            if list[i].deliveredAt == nil { list[i].deliveredAt = list[i].answeredAt }
            return list[i]
        }
        guard let hit else { Rules.say("RigWatch: no open question about \(id). Questions lapse 30 min after they are asked."); return 1 }
        Rules.log("ask: \(hit.name) (\(hit.device)) — session \(by ?? "unknown") answered \(yes ? "yes" : "no")\(reason.isEmpty ? "" : ": " + reason)")
        print("Thanks. RigWatch shows your answer (\(yes ? "safe to shut down" : "keep it")) on \(hit.name)'s card; the user decides whether to shut it down.")
        return 0
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
