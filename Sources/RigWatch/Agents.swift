import AppKit
import Foundation

/// The coding agents RigWatch recognises. Full ones get titles, prompts and resume from their own
/// session files; every other one is shown from its processes alone.
enum Agent: String, CaseIterable {
    case claude = "Claude Code", opencode = "OpenCode", codex = "Codex"
    case cursor = "Cursor", cursorAgent = "Cursor Agent", windsurf = "Windsurf", t3 = "T3 Code"
    case gemini = "Gemini CLI", aider = "Aider", goose = "Goose", amp = "Amp"

    var full: Bool { self == .claude || self == .opencode || self == .codex }

    var color: NSColor {
        switch self {
        case .claude: NSColor(red: 0.90, green: 0.53, blue: 0.42, alpha: 1)
        case .opencode: NSColor(red: 0.98, green: 0.75, blue: 0.25, alpha: 1)
        case .codex: NSColor(red: 0.45, green: 0.62, blue: 1.00, alpha: 1)
        case .cursor, .cursorAgent: NSColor(red: 0.62, green: 0.66, blue: 0.75, alpha: 1)
        case .windsurf: NSColor(red: 0.18, green: 0.85, blue: 0.75, alpha: 1)
        case .t3: NSColor(red: 0.75, green: 0.55, blue: 1.00, alpha: 1)
        case .gemini: NSColor(red: 0.35, green: 0.70, blue: 1.00, alpha: 1)
        case .aider, .goose, .amp: NSColor(red: 0.55, green: 0.85, blue: 0.45, alpha: 1)
        }
    }

    /// What a process is, from its name, path and (for our own processes) argv.
    static func of(_ p: Proc) -> Agent? {
        let n = p.name, path = p.path, a = p.args.dropFirst().joined(separator: " ")
        if n == "claude" || path.contains("/claude-code/") { return .claude }
        if n == "opencode" { return a.contains("serve") ? nil : .opencode }   // `opencode serve` is its background server, not a session
        if n == "codex" { return .codex }
        if n == "cursor-agent" { return .cursorAgent }
        if path.hasSuffix("Cursor.app/Contents/MacOS/Cursor") { return .cursor }
        if path.hasSuffix("Windsurf.app/Contents/MacOS/Electron") || path.hasSuffix("Windsurf.app/Contents/MacOS/Windsurf") { return .windsurf }
        if n == "t3" || path.contains("/.t3/runtime/") { return .t3 }
        if n == "gemini" || (n == "node" && a.contains("/gemini")) { return .gemini }
        if n == "aider" || (n.hasPrefix("python") && a.contains("aider")) { return .aider }
        if n == "goose" { return .goose }
        if n == "amp" || (n == "node" && a.contains("/amp/")) { return .amp }
        return nil
    }

    /// The session id a process was started with: `opencode --session ID` / `-s ID`, `codex resume ID`.
    static func sessionArg(_ args: [String]) -> String? {
        let a = Array(args.dropFirst())
        for (i, x) in a.enumerated() {
            if x.hasPrefix("--session=") { return String(x.dropFirst(10)) }
            if (x == "--session" || x == "-s" || x == "resume"), i + 1 < a.count, !a[i + 1].hasPrefix("-") { return a[i + 1] }
        }
        return nil
    }

    /// OpenCode 2's background server (`opencode serve`), shared by every OpenCode session.
    static func isOpenCodeService(_ p: Proc) -> Bool {
        (p.name == "opencode" || p.name == "opencode.exe") && p.args.dropFirst().contains("serve")
    }

    /// Copies the command that resumes this session in a terminal, or nil if the tool has none.
    func resumeCommand(_ id: String) -> String? {
        switch self {
        case .claude: "claude --resume \(id)"
        case .opencode: "opencode --session \(id)"
        case .codex: "codex resume \(id)"
        default: nil
        }
    }
}

/// Sessions for every agent other than Claude Code (which `SessionIndex` reads from its transcripts).
final class AgentIndex {
    private struct Live { let agent: Agent; let root: Proc; var cpu: Double; var mem: UInt64; var procs: Int; var cwd: String?; var via: String? }

    func sessions(_ ps: [Proc]) -> [Session] {
        let byPid = Dictionary(uniqueKeysWithValues: ps.map { ($0.pid, $0) })
        var kids: [Int32: [Int32]] = [:]
        for p in ps { kids[p.ppid, default: []].append(p.pid) }
        let kind = Dictionary(uniqueKeysWithValues: ps.compactMap { p in Agent.of(p).map { (p.pid, $0) } })

        func nearestAgentAncestor(_ p: Proc) -> (Int32, Agent)? {
            var x = p.ppid, hops = 0
            while x > 1, hops < 64, let q = byPid[x] { if let k = kind[x] { return (x, k) }; x = q.ppid; hops += 1 }
            return nil
        }
        // A root is an agent process whose nearest agent ancestor is a different tool (or none):
        // a helper process of the same tool belongs to its parent's card.
        var lives: [Live] = []
        for p in ps {
            guard let k = kind[p.pid], k != .claude else { continue }
            let up = nearestAgentAncestor(p)
            if let up, up.1 == k { continue }
            var l = Live(agent: k, root: p, cpu: 0, mem: 0, procs: 0, cwd: p.isOwn ? ProcSampler.cwd(p.pid) : nil, via: up.map { $0.1.rawValue })
            // Sum the tree, but stop at a different agent: it gets a card of its own.
            var stack = [p.pid]
            while let x = stack.popLast() {
                guard let q = byPid[x] else { continue }
                l.cpu += q.cpu; l.mem += q.mem; l.procs += 1
                for c in kids[x] ?? [] where (kind[c] == nil || kind[c] == k) && !(byPid[c].map(Agent.isOpenCodeService) ?? false) { stack.append(c) }
            }
            lives.append(l)
        }

        var out: [Session] = []
        let oc = lives.filter { $0.agent == .opencode }
        let cx = lives.filter { $0.agent == .codex }
        let ocRows = oc.isEmpty ? [] : OpenCodeStore.recent()
        let cxRows = cx.isEmpty ? [] : CodexStore.recent()
        for l in lives {
            let started = DeviceSampler.startDate(l.root.pid)
            var s = Session(id: "pid:\(l.root.pid)", title: l.agent.rawValue + (l.cwd.flatMap { $0 == Sh.home || $0 == "/" ? nil : " · " + ($0 as NSString).lastPathComponent } ?? ""),
                            lastPrompt: "", project: l.cwd.map { Views.tilde($0) } ?? "", transcriptAge: nil, live: true,
                            host: l.via.map { "via \($0)" } ?? (l.agent.full ? "CLI" : "App"))
            s.agent = l.agent; s.cwd = l.cwd; s.started = started
            s.procCount = l.procs; s.cpu = l.cpu; s.mem = l.mem
            // Full agents: the session named on the command line, else the newest one of that tool in this folder.
            let rows = l.agent == .opencode ? ocRows : l.agent == .codex ? cxRows : []
            let named = Agent.sessionArg(l.root.args).flatMap { id in rows.first { $0.id == id } }
            if let cwd = l.cwd, let r = named ?? rows.filter({ $0.dir == cwd }).max(by: { $0.updated < $1.updated }) {
                s.id = r.id; s.title = r.title.isEmpty ? s.title : r.title; s.lastPrompt = r.prompt
                s.project = (cwd as NSString).lastPathComponent
                s.transcriptAge = Date().timeIntervalSince(r.updated)
            } else if !l.agent.full {
                // Basic: no session files to read, so "active" follows CPU.
                s.transcriptAge = l.cpu > 5 ? 0 : started.map { Date().timeIntervalSince($0) }
            }
            out.append(s)
        }
        return out
    }
}

struct AgentRow { let id: String; let title: String; let dir: String; let updated: Date; let prompt: String }

/// OpenCode keeps every session in one SQLite database. Read-only, through the system sqlite3,
/// cached until the database (or its WAL) changes.
enum OpenCodeStore {
    static let db = Sh.home + "/.local/share/opencode/opencode.db"
    private static var cache: (stamp: Date, rows: [AgentRow]) = (.distantPast, [])

    static func recent() -> [AgentRow] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: db) else { return [] }
        let stamp = [db, db + "-wal"].compactMap { (try? fm.attributesOfItem(atPath: $0))?[.modificationDate] as? Date }.max() ?? .distantPast
        if stamp == cache.stamp { return cache.rows }
        let sql = """
        select s.id, s.title, s.directory, s.time_updated,
          coalesce((select json_extract(p.data,'$.text') from part p join message m on m.id = p.message_id
                    where p.session_id = s.id and json_extract(m.data,'$.role') = 'user' and json_extract(p.data,'$.type') = 'text'
                    order by p.time_created desc limit 1), '') as prompt
        from session s where s.parent_id is null and s.time_archived is null
        order by s.time_updated desc limit 40;
        """
        // OpenCode 2 moved sessions to `session_v2` and messages to `session_message`; 1.x databases have neither.
        let v2 = Sh.run("/usr/bin/sqlite3", ["-readonly", db, "select 1 from sqlite_master where name = 'session_v2'"], timeout: 5).out.contains("1")
        let sqlV2 = """
        select s.id, s.title, s.directory, s.time_updated,
          coalesce((select json_extract(m.data,'$.text') from session_message m
                    where m.session_id = s.id and m.type = 'user' order by m.seq desc limit 1), '') as prompt
        from session_v2 s where s.parent_id is null and s.time_archived is null
        order by s.time_updated desc limit 40;
        """
        let r = Sh.run("/usr/bin/sqlite3", ["-readonly", "-json", db, v2 ? sqlV2 : sql], timeout: 5)
        let arr = (try? JSONSerialization.jsonObject(with: r.data) as? [[String: Any]]) ?? []
        let rows = arr.compactMap { d -> AgentRow? in
            guard let id = d["id"] as? String, let dir = d["directory"] as? String else { return nil }
            let ms = (d["time_updated"] as? NSNumber)?.doubleValue ?? 0
            let prompt = d["prompt"] as? String ?? ""
            return AgentRow(id: id, title: d["title"] as? String ?? "", dir: dir, updated: Date(timeIntervalSince1970: ms / 1000),
                            prompt: prompt.replacingOccurrences(of: "\n", with: " "))
        }
        cache = (stamp, rows)
        return rows
    }
}

/// Codex CLI writes one JSONL "rollout" per session under ~/.codex/sessions/YYYY/MM/DD/. The first
/// line is the session's metadata (id, cwd); user prompts are `user_message` events.
enum CodexStore {
    static let root = Sh.home + "/.codex/sessions"
    private static var cache: [String: (mtime: Date, row: AgentRow)] = [:]

    static func recent() -> [AgentRow] {
        let fm = FileManager.default
        var out: [AgentRow] = []
        let cal = Calendar(identifier: .gregorian)
        for back in 0..<7 {   // the last week of day folders
            let d = cal.date(byAdding: .day, value: -back, to: Date())!
            let c = cal.dateComponents([.year, .month, .day], from: d)
            let dir = String(format: "%@/%04d/%02d/%02d", root, c.year!, c.month!, c.day!)
            for f in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where f.hasSuffix(".jsonl") {
                let p = dir + "/" + f
                guard let mt = (try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date else { continue }
                if let hit = cache[p], hit.mtime == mt { out.append(hit.row); continue }
                guard let row = read(p, mtime: mt) else { continue }
                cache[p] = (mt, row); out.append(row)
            }
        }
        return out
    }

    private static func read(_ path: String, mtime: Date) -> AgentRow? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let head = String(decoding: h.readData(ofLength: 64_000), as: UTF8.self)
        guard let first = head.split(separator: "\n").first, let meta = json(first) else { return nil }
        let payload = meta["payload"] as? [String: Any] ?? meta
        guard let cwd = payload["cwd"] as? String else { return nil }
        let id = payload["id"] as? String ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        var firstPrompt = "", lastPrompt = ""
        func prompts(_ text: Substring) -> [String] {
            text.split(separator: "\n").filter { $0.contains("\"user_message\"") }.compactMap { line in
                (json(line)?["payload"] as? [String: Any])?["message"] as? String
            }
        }
        firstPrompt = prompts(Substring(head)).first ?? ""
        lastPrompt = SessionIndex.tail(path, bytes: 400_000).map { prompts(Substring($0)).last ?? "" } ?? ""
        let clean = { (s: String) in s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) }
        return AgentRow(id: id, title: String(clean(firstPrompt).prefix(70)), dir: cwd, updated: mtime, prompt: clean(lastPrompt.isEmpty ? firstPrompt : lastPrompt))
    }

    private static func json(_ s: Substring) -> [String: Any]? {
        guard let d = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }
}
