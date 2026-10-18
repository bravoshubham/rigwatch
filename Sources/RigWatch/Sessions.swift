import Foundation

struct Session: Identifiable, Hashable {
    var id: String                 // the tool's session id (Claude: transcript file name), or "pid:N" when only the process is known
    var title: String
    var lastPrompt: String
    var project: String
    var transcriptAge: TimeInterval?
    var live: Bool                 // a Claude process for it is running
    var host: String               // Desktop / CLI / gone
    var hostId: String?            // desktop app's local_… id, for the claude:// deep link
    var procCount = 0
    var cpu = 0.0
    var mem: UInt64 = 0
    var devices: [String] = []     // emulators / simulators it launched or recently drove
    var worktrees = 0
    var servers: [String] = []     // dev servers it started, e.g. "Vite :5173"
    var agent: Agent = .claude
    var cwd: String?
    var started: Date?

    var status: String {
        guard live else { return transcriptAge.map { $0 < 600 ? "Closed (recent)" : "Closed" } ?? "Closed" }
        guard let a = transcriptAge else { return "Live" }
        if a < 90 { return "Working" }
        if a < 1800 { return "Idle" }
        return "Dormant"
    }
    var isWorking: Bool { live && (transcriptAge ?? .infinity) < 90 }
}

/// Reads session titles and last prompts from the transcripts in ~/.claude/projects and the
/// desktop app's session records. Read-only; tails each file, cached by mtime.
final class SessionIndex {
    private struct Meta { var mtime: Date; var title: String?; var prompt: String? }
    private var paths: [String: String] = [:]          // id -> transcript path
    private var meta: [String: Meta] = [:]
    private var desktop: [String: (cli: String, title: String)] = [:]   // local_… -> (cli id, title)
    private var desktopByCli: [String: String] = [:]
    private var desktopAt = Date.distantPast
    private var mentionOffsets: [String: UInt64] = [:]
    private(set) var mentions: [String: [String: Date]] = [:]           // device key -> session -> when seen
    private(set) var lastAction: [String: (session: String, command: String, at: Date)] = [:]
    private let projects = Sh.home + "/.claude/projects"

    func cliId(forHost host: String) -> String? { refreshDesktop(); return desktop[host]?.cli }
    func hostId(forCli cli: String) -> String? { refreshDesktop(); return desktop.first { $0.value.cli == cli }?.key }

    private func refreshDesktop() {
        guard Date().timeIntervalSince(desktopAt) > 60 else { return }
        desktopAt = Date()
        let root = Sh.home + "/Library/Application Support/Claude/claude-code-sessions"
        guard let e = FileManager.default.enumerator(atPath: root) else { return }
        for case let rel as String in e where rel.hasSuffix(".json") && (rel as NSString).lastPathComponent.hasPrefix("local_") {
            guard let d = try? Data(contentsOf: URL(fileURLWithPath: root + "/" + rel)),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let sid = j["sessionId"] as? String, let cli = j["cliSessionId"] as? String else { continue }
            let t = (j["title"] as? String) ?? ""
            desktop[sid] = (cli, t); desktopByCli[cli] = t
        }
    }

    func path(for id: String) -> String? {
        if let p = paths[id], FileManager.default.fileExists(atPath: p) { return p }
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: projects) else { return nil }
        for d in dirs {
            let p = "\(projects)/\(d)/\(id).jsonl"
            if FileManager.default.fileExists(atPath: p) { paths[id] = p; return p }
        }
        return nil
    }

    func describe(_ id: String, live: Bool, host: String) -> Session {
        refreshDesktop()
        var s = Session(id: id, title: desktopByCli[id] ?? "", lastPrompt: "", project: "", transcriptAge: nil, live: live, host: host)
        guard let p = path(for: id) else { if s.title.isEmpty { s.title = String(id.prefix(8)) }; return s }
        s.project = Self.projectName(p)
        let mtime = ((try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date) ?? .distantPast
        s.transcriptAge = Date().timeIntervalSince(mtime)
        if meta[id]?.mtime != mtime { meta[id] = readMeta(p, mtime: mtime, old: meta[id]) }
        if s.title.isEmpty { s.title = meta[id]?.title ?? "" }
        s.lastPrompt = meta[id]?.prompt ?? ""
        if s.title.isEmpty { s.title = s.lastPrompt.isEmpty ? String(id.prefix(8)) : String(s.lastPrompt.prefix(60)) }
        return s
    }

    static func projectName(_ transcript: String) -> String {
        let dir = ((transcript as NSString).deletingLastPathComponent as NSString).lastPathComponent
        // Claude Code names the folder after the project path with every non-alphanumeric
        // character turned into "-": "-Users-me-code-my-app" -> "code-my-app".
        let home = String(Sh.home.map { $0.isLetter || $0.isNumber ? $0 : "-" }) + "-"
        if dir.hasPrefix(home), dir.count > home.count { return String(dir.dropFirst(home.count)) }
        return dir.split(separator: "-").suffix(2).joined(separator: "-")
    }

    private func readMeta(_ path: String, mtime: Date, old: Meta?) -> Meta {
        var m = Meta(mtime: mtime, title: old?.title, prompt: old?.prompt)
        guard let tail = Self.tail(path, bytes: 1_000_000) else { return m }
        var custom: String?, ai: String?, prompt: String?
        for line in tail.split(separator: "\n").reversed() {
            if custom == nil, line.contains("\"custom-title\"") { custom = Self.field(line, "customTitle") }
            if ai == nil, line.contains("\"ai-title\"") { ai = Self.field(line, "aiTitle") }
            if prompt == nil, line.contains("\"last-prompt\"") { prompt = Self.field(line, "lastPrompt") }
            if custom != nil && prompt != nil { break }
        }
        m.title = custom ?? ai ?? m.title
        m.prompt = prompt ?? m.prompt
        return m
    }

    private static func field(_ line: Substring, _ key: String) -> String? {
        guard let d = line.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return (j[key] as? String)?.replacingOccurrences(of: "\n", with: " ")
    }

    /// The last shell command in a transcript chunk that names the device.
    static func lastCommand(in text: String, mentioning key: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #""command":"((?:[^"\\]|\\.){1,2000})""#) else { return nil }
        var found: String?
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(m.range(at: 1), in: text) else { continue }
            let c = String(text[r])
            if c.contains(key) { found = c }
        }
        return found.map { $0.replacingOccurrences(of: "\\n", with: " ").replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\") }
    }

    static func tail(_ path: String, bytes: UInt64, from offset: UInt64? = nil) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let end = (try? h.seekToEnd()) ?? 0
        let start = offset.map { min($0, end) } ?? (end > bytes ? end - bytes : 0)
        try? h.seek(toOffset: start)
        guard let d = try? h.readToEnd() else { return "" }
        return String(decoding: d, as: UTF8.self)
    }

    /// Finds which sessions recently mentioned each device (serial like emulator-5554, or a
    /// simulator UDID) in their transcripts. Reads only bytes appended since the last scan.
    func scanMentions(keys: [String], window: TimeInterval = 3 * 3600) {
        guard !keys.isEmpty, let dirs = try? FileManager.default.contentsOfDirectory(atPath: projects) else { return }
        let now = Date()
        for d in dirs {
            let dir = "\(projects)/\(d)"
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for f in files where f.hasSuffix(".jsonl") {
                let p = "\(dir)/\(f)"
                guard let a = try? FileManager.default.attributesOfItem(atPath: p), let mt = a[.modificationDate] as? Date,
                      now.timeIntervalSince(mt) < window, let size = (a[.size] as? NSNumber)?.uint64Value else { continue }
                let off = mentionOffsets[p] ?? (size > 400_000 ? size - 400_000 : 0)
                guard size > off, let text = Self.tail(p, bytes: 0, from: off) else { continue }
                mentionOffsets[p] = size
                let id = String(f.dropLast(6))
                for k in keys where text.contains(k) {
                    mentions[k, default: [:]][id] = mt
                    if let c = Self.lastCommand(in: text, mentioning: k), (lastAction[k]?.at ?? .distantPast) <= mt {
                        lastAction[k] = (id, c, mt)
                    }
                }
            }
        }
        for (k, v) in mentions { mentions[k] = v.filter { now.timeIntervalSince($0.value) < window } }
    }
}
