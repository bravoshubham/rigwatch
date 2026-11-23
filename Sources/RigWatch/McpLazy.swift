import CryptoKit
import Foundation

/// `RigWatch mcp-lazy [--idle SECONDS] -- COMMAND ARGS…`: an MCP server that starts only when it is used.
///
/// Claude Code starts every configured MCP server with every session and keeps it for the session's life: with
/// many sessions that is many copies of servers most of them never call. Registered in a server's place, this
/// answers what a session asks at startup (`initialize`, the tool, prompt and resource lists, `ping`) from what
/// the real server answered last time, and starts the real server at the first other request: it replays the
/// session's own `initialize`, then passes everything through both ways. With nothing in flight for the idle time
/// (5 minutes) the server is stopped again, and the next request starts it afresh. The first time, with nothing
/// saved yet, the server starts at once and its answers are saved; each start refreshes them.
final class McpLazy {
    static func main(_ a: [String]) -> Int32 {
        var args = a, idle: TimeInterval = 300
        while let f = args.first, f != "--" {
            if f == "--idle", args.count > 1, let s = Double(args[1]) { idle = max(10, s); args.removeFirst(2) } else { break }
        }
        if args.first == "--" { args.removeFirst() }
        guard !args.isEmpty else { Rules.say("usage: RigWatch mcp-lazy [--idle SECONDS] -- COMMAND ARGS…"); return 2 }
        McpLazy(command: args, idle: idle).run()
        return 0
    }

    let command: [String], idle: TimeInterval
    let cacheFile: String
    let lock = NSLock()
    var cache: [String: Any] = [:]          // method -> result, as the real server gave it
    var clientInit: [String: Any]?          // the session's initialize request, replayed to each real start
    var child: Process?, toChild: FileHandle?
    var starting = false
    var queued: [Data] = []                 // what came in while the server was starting
    var pending: [String: (method: String, id: Any)] = [:]   // requests passed to the server, by id
    var lastActivity = Date()
    var timer: DispatchSourceTimer?

    init(command: [String], idle: TimeInterval) {
        self.command = command; self.idle = idle
        let dir = Rules.dir + "/mcp-lazy"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let name = ((command.first ?? "mcp") as NSString).lastPathComponent.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
        let tag = Insecure.MD5.hash(data: Data(command.joined(separator: "\u{1}").utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        cacheFile = dir + "/\(name)-\(tag).json"
        if let d = FileManager.default.contents(atPath: cacheFile), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] { cache = j }
    }

    /// Methods answered from the saved copy while the server is not running.
    static let saved: Set = ["initialize", "tools/list", "prompts/list", "resources/list", "resources/templates/list"]

    func run() {
        signal(SIGPIPE, SIG_IGN)
        let t = DispatchSource.makeTimerSource(queue: .global())
        t.schedule(deadline: .now() + 15, repeating: 15)
        t.setEventHandler { [weak self] in self?.stopIfIdle() }
        t.resume(); timer = t
        var buf = Data()
        while case let d = FileHandle.standardInput.availableData, !d.isEmpty {   // whatever has arrived, not a full buffer
            buf.append(d)
            while let nl = buf.firstIndex(of: 0x0A) {
                let line = buf[buf.startIndex..<nl]
                buf.removeSubrange(buf.startIndex...nl)
                if !line.isEmpty { fromClient(Data(line)) }
            }
        }
        // The session closed its end: the server goes with it.
        lock.lock(); let c = child; lock.unlock()
        if let c, c.isRunning { c.terminate() }
    }

    // MARK: from the session

    func fromClient(_ line: Data) {
        lock.lock(); defer { lock.unlock() }
        lastActivity = Date()
        guard let msg = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { forward(line); return }
        let method = msg["method"] as? String, id = msg["id"]
        if method == "initialize" { clientInit = msg }
        if child == nil && !starting {
            if let method, let id {
                if method == "ping" { reply(id, [:]); return }
                if Self.saved.contains(method), let r = cache[method] { reply(id, r); return }
            } else if method == nil || method?.hasPrefix("notifications/") == true {
                return   // notifications (initialized, cancelled, roots changed) and stray answers: no server to tell
            }
            start()
        }
        forward(line, method: method, id: id)
    }

    /// To the server, or into the queue while it starts. Call with the lock held.
    func forward(_ line: Data, method: String? = nil, id: Any? = nil) {
        if let method, let id { pending[key(id)] = (method, id) }
        if starting || toChild == nil { queued.append(line); return }
        write(line, to: toChild!)
    }

    func key(_ id: Any) -> String { "\(id)" }

    func reply(_ id: Any, _ result: Any) {
        var r = result
        // The saved initialize answer keeps the protocol version the session asked for, when it asked.
        if var ini = r as? [String: Any], ini["serverInfo"] != nil,
           let v = (clientInit?["params"] as? [String: Any])?["protocolVersion"] { ini["protocolVersion"] = v; r = ini }
        send(["jsonrpc": "2.0", "id": id, "result": r])
    }

    let outLock = NSLock()
    func send(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        outLock.lock(); defer { outLock.unlock() }
        FileHandle.standardOutput.write(d + Data([0x0A]))
    }

    func write(_ line: Data, to h: FileHandle) {
        do { try h.write(contentsOf: line + Data([0x0A])) } catch {}
    }

    // MARK: the real server

    /// Starts the server and replays the session's initialize. Call with the lock held.
    func start() {
        starting = true
        let p = Process(), inPipe = Pipe(), outPipe = Pipe()
        p.executableURL = URL(fileURLWithPath: command[0].hasPrefix("/") ? command[0] : "/usr/bin/env")
        p.arguments = command[0].hasPrefix("/") ? Array(command.dropFirst()) : command
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = FileHandle.standardError
        p.terminationHandler = { [weak self] proc in self?.ended(proc) }
        do { try p.run() } catch {
            starting = false
            FileHandle.standardError.write(Data("RigWatch mcp-lazy: could not start \(command[0]): \(error)\n".utf8))
            for l in queued { failRequest(l, "could not start the MCP server: \(error)") }
            queued = []
            return
        }
        child = p; toChild = inPipe.fileHandleForWriting
        FileHandle.standardError.write(Data("RigWatch mcp-lazy: started \((command[0] as NSString).lastPathComponent) (pid \(p.processIdentifier))\n".utf8))
        DispatchQueue.global().async { [weak self] in self?.readChild(outPipe.fileHandleForReading) }
        // The server learns who it talks to from the session's own initialize, under an id of ours.
        var ini = clientInit ?? ["jsonrpc": "2.0", "method": "initialize",
                                 "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "rigwatch-mcp-lazy", "version": "1"]]]
        ini["id"] = "rigwatch-lazy-init"
        if let d = try? JSONSerialization.data(withJSONObject: ini) { write(d, to: toChild!) }
    }

    func readChild(_ h: FileHandle) {
        var buf = Data()
        while case let d = h.availableData, !d.isEmpty {
            buf.append(d)
            while let nl = buf.firstIndex(of: 0x0A) {
                let line = Data(buf[buf.startIndex..<nl])
                buf.removeSubrange(buf.startIndex...nl)
                if !line.isEmpty { fromChild(line) }
            }
        }
    }

    func fromChild(_ line: Data) {
        lock.lock(); defer { lock.unlock() }
        lastActivity = Date()
        let msg = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        let id = msg?["id"].map(key)
        if id == "rigwatch-lazy-init" {
            if let r = msg?["result"] { cache["initialize"] = r }
            // Initialized: the queue goes through, and the saved lists are refreshed in the background.
            if let h = toChild {
                write(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8), to: h)
                for (m, i) in [("tools/list", "rigwatch-lazy-tools"), ("prompts/list", "rigwatch-lazy-prompts"), ("resources/list", "rigwatch-lazy-resources")] {
                    write(Data(#"{"jsonrpc":"2.0","id":"\#(i)","method":"\#(m)"}"#.utf8), to: h)
                }
                starting = false
                // A session that sent initialize to a running copy is answered from it; ours took its place.
                for l in queued {
                    if let q = (try? JSONSerialization.jsonObject(with: l)) as? [String: Any], let qid = q["id"] {
                        let m = q["method"] as? String
                        if m == "initialize", let r = cache["initialize"] { reply(qid, r); continue }
                        if m == "notifications/initialized" { continue }
                        pending[key(qid)] = (m ?? "", qid)
                    } else if ((try? JSONSerialization.jsonObject(with: l)) as? [String: Any])?["method"] as? String == "notifications/initialized" { continue }
                    write(l, to: h)
                }
                queued = []
            }
            saveCache()
            return
        }
        if let id, id.hasPrefix("rigwatch-lazy-") {
            let m = ["rigwatch-lazy-tools": "tools/list", "rigwatch-lazy-prompts": "prompts/list", "rigwatch-lazy-resources": "resources/list"][id]
            if let m, let r = msg?["result"] { cache[m] = r; saveCache() }
            else if let m { cache[m] = nil; saveCache() }   // the server has no such list
            return
        }
        // An answer to the session: note list answers, so the saved copy stays current.
        if let id, let m = pending.removeValue(forKey: id)?.method, Self.saved.contains(m), let r = msg?["result"] { cache[m] = r; saveCache() }
        outLock.lock(); FileHandle.standardOutput.write(line + Data([0x0A])); outLock.unlock()
    }

    func saveCache() {
        if let d = try? JSONSerialization.data(withJSONObject: cache) { Rules.write(d, to: cacheFile) }
    }

    func ended(_ p: Process) {
        lock.lock(); defer { lock.unlock() }
        guard child === p else { return }
        child = nil; toChild = nil
        let wasStarting = starting
        starting = false
        // Requests it never answered get an error, so the session isn't left waiting.
        for (_, p) in pending { send(["jsonrpc": "2.0", "id": p.id, "error": ["code": -32603, "message": "the MCP server exited"]]) }
        pending = [:]
        if wasStarting { for l in queued { failRequest(l, "the MCP server exited while starting") }; queued = [] }
    }

    func failRequest(_ line: Data, _ why: String) {
        guard let q = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let id = q["id"] else { return }
        send(["jsonrpc": "2.0", "id": id, "error": ["code": -32603, "message": why]])
    }

    func stopIfIdle() {
        lock.lock(); defer { lock.unlock() }
        guard let c = child, !starting, pending.isEmpty, Date().timeIntervalSince(lastActivity) > idle else { return }
        child = nil; toChild = nil
        c.terminate()
        FileHandle.standardError.write(Data("RigWatch mcp-lazy: stopped \((command[0] as NSString).lastPathComponent) after \(Int(idle)) s unused\n".utf8))
    }
}
