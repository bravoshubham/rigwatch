import CryptoKit
import Darwin
import Foundation

/// Spreads builds across Macs. When this Mac is busy or its build slots are full and an allowed Mac that shares is
/// clearly less busy, a command queued here (`RigWatch run`) starts at once, and each Gradle or xcodebuild run in it
/// goes through `peer exec`, which builds on that Mac: the worktree is copied there (only changes), the build runs
/// in that Mac's queue with its output streamed back (paths shown as this Mac's), and its results (APKs, reports,
/// test results, Xcode products) are copied back to where they would have been. The rest of the command (variables,
/// redirects into logs, an install afterwards) runs here as usual. A build that installs on a device here, signs
/// for a phone or reads files outside its worktree runs here, in the queue. When that Mac can't build the project
/// (dependencies, SDK, Java, Xcode) the build runs here instead, and that Mac is skipped for it for 6 hours.
enum Offload {
    /// What another Mac needs to run a build. Paths into the worktree read `@@ROOT@@` until the copy there is known.
    struct Shape {
        var kind: String
        var root: String                  // the checkout copied over
        var rel: String                   // the command's folder inside it
        var cmd: String
        var simulator = false, emulator = false
        var device: String?               // simulator name to ask for (--name)
        var gradleResults = false         // copy back every module's build/outputs, reports and test-results
        var back: [(from: String, to: String)] = []   // relative to the copy there -> absolute here
        var keep: [String] = []           // relative paths there the copy must leave alone
        var derived: String?              // the DerivedData here that .rigwatch-dd there stands for
        var signs = false                 // builds for a real device: only on a Mac that can sign for this Mac's team
    }
    static let root = "@@ROOT@@"
    /// RigWatch there must answer `home` and know `run --here --watch-stdin`.
    static let minBuild = 39   // the copy there is a git worktree; that Mac cleans up mirrors and shared node_modules/Pods

    // MARK: which commands can move

    private static func rx(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
    static let threadFlag = rx(#" (?:--max-workers=\d+|-jobs \d+)"#)
    static let prefixes = rx(#"^(?:(?:[A-Za-z_]\w*=(?:"[^"]*"|'[^']*'|\S*)|time|env|xcrun|nice(?:\s+-n\s*-?\d+)?|caffeinate(?:\s+-\w+)*|arch\s+-\w+|timeout\s+\S+)\s+)*"#)
    static let allowedTools: Set = ["cd", "xcodebuild", "tail", "head", "grep", "egrep", "xcpretty", "xcbeautify", "echo", "true", "set", "export"]
    static let gradleTool = rx(#"^(?:\S*/)?gradlew?$"#)
    static let absPath = rx(#"(?:^|(?<=[\s='"(:,]))(/[^\s'";&|)]*)"#)
    static let gradleInstall = rx(#"(?:^|[\s:])(?:un)?install[A-Z]\w*"#)
    static let gradleDevice = rx(#"(?:^|[\s:])connected\w*"#)
    static let serialAssign = rx(#"(?:^|\s)ANDROID_SERIAL=\S+\s*"#)
    static let xcRefuse = rx(#"(?:^|\s)(?:archive|install|installsrc|docbuild)(?=\s|$)|-exportArchive|-exportLocalizations|-importLocalizations|-sdk\s+["']?(?:watchos|appletvos|xros)\b"#)
    /// A build for a real iPhone: it goes to a Mac that can sign for this Mac's team, and its app comes back here.
    static let deviceBuild = rx(#"-allowProvisioningUpdates|-sdk\s+["']?iphoneos\b"#)
    static let xcTest = rx(#"(?:^|\s)(?:test|test-without-building)(?=\s|$)"#)
    static let destination = rx(#"-destination\s+("[^"]*"|'[^']*'|\S+)"#)
    static let projectArg = rx(#"-(workspace|project)\s+("[^"]*"|'[^']*'|[^\s;&|]+)"#)
    static let resultArg = rx(#"-resultBundlePath\s+("[^"]*"|'[^']*'|[^\s;&|]+)"#)
    static let cdArg = rx(#"\bcd\s+("[^"]+"|'[^']+'|[^\s;&|]+)"#)
    static let simSDK = rx(#"-sdk\s+["']?(?:iphonesimulator|macosx)"#)

    static func unquote(_ s: String) -> String { s.count >= 2 && (s.first == "'" || s.first == "\"") && s.last == s.first ? String(s.dropFirst().dropLast()) : s }

    /// The command's pieces between && || ; | and newlines (outside quotes), or nil for anything harder to be sure
    /// of: a lone & (background job), command substitution.
    static func segments(_ cmd: String) -> [String]? {
        var out: [String] = [], cur = "", q: Character? = nil
        let c = Array(cmd)
        var i = 0
        while i < c.count {
            let ch = c[i]
            if let open = q { cur.append(ch); if ch == open { q = nil }; i += 1; continue }
            switch ch {
            case "'", "\"": q = ch; cur.append(ch)
            case "`": return nil
            case "$" where i + 1 < c.count && c[i + 1] == "(": return nil
            case ";", "\n": out.append(cur); cur = ""
            case "|": out.append(cur); cur = ""; if i + 1 < c.count && c[i + 1] == "|" { i += 1 }
            case "&":
                if i + 1 < c.count && c[i + 1] == "&" { out.append(cur); cur = ""; i += 1 }
                else if (i > 0 && c[i - 1] == ">") || (i + 1 < c.count && c[i + 1] == ">") { cur.append(ch) }
                else { return nil }
            default: cur.append(ch)
            }
            i += 1
        }
        out.append(cur)
        return out.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// A redirect into a file (not /dev/null, not another stream): that file would be written on the other Mac.
    static func writesFile(_ seg: String) -> Bool {
        var q: Character? = nil
        let c = Array(seg)
        for (i, ch) in c.enumerated() {
            if let open = q { if ch == open { q = nil }; continue }
            if ch == "'" || ch == "\"" { q = ch; continue }
            guard ch == ">" else { continue }
            var rest = String(c[(i + 1)...]).drop { $0 == ">" }.drop { $0 == " " }
            if rest.hasPrefix("&") { rest = rest.dropFirst(); if rest.first?.isNumber == true { continue } }
            if !rest.hasPrefix("/dev/null") { return true }
        }
        return false
    }

    /// Where Xcode keeps a project's DerivedData by default: <name>-<hash of the workspace or project path>.
    static func defaultDerivedData(_ project: String) -> String {
        let d = Array(Insecure.MD5.hash(data: Data(project.utf8)))
        var out = [Character](repeating: "a", count: 28)
        for half in 0..<2 {
            var v: UInt64 = 0
            for b in d[(half * 8)..<(half * 8 + 8)] { v = v << 8 | UInt64(b) }
            for i in stride(from: half * 14 + 13, through: half * 14, by: -1) { out[i] = Character(UnicodeScalar(UInt8(v % 26) + 97)); v /= 26 }
        }
        let name = ((project as NSString).lastPathComponent as NSString).deletingPathExtension.replacingOccurrences(of: " ", with: "_")
        return Sh.home + "/Library/Developer/Xcode/DerivedData/\(name)-\(String(out))"
    }

    /// How `RigWatch run`'s command would run on another Mac, or nil (with why) when it has to run here.
    static func shape(_ argv: [String], kind: String, cwd: String, why: inout String) -> Shape? {
        guard kind == "gradle" || kind == "xcodebuild" else { why = "not a Gradle or Xcode build"; return nil }
        guard argv.count == 3, argv[0] == "/bin/zsh", argv[1] == "-c" else { why = "not a shell command"; return nil }
        var cmd = threadFlag.stringByReplacingMatches(in: argv[2], range: NSRange(argv[2].startIndex..., in: argv[2]), withTemplate: "")
        cmd = cmd.replacingOccurrences(of: "${HOME}", with: Sh.home).replacingOccurrences(of: "$HOME", with: Sh.home)
            .replacingOccurrences(of: #"(?<=^|[\s='"(:])~(?=/)"#, with: Sh.home, options: .regularExpression)
        // Gradle told to download through a proxy on this Mac: there it downloads directly.
        if cmd.range(of: #"-Dhttps?\.proxyHost=(?:127\.|localhost\b)"#, options: [.regularExpression, .caseInsensitive]) != nil {
            cmd = cmd.replacingOccurrences(of: #"\s+(['"]?)-Dhttps?\.(?:proxyHost|proxyPort|nonProxyHosts)=\S*?\1(?=\s|$)"#, with: "", options: .regularExpression)
        }
        guard cmd.range(of: #"\$[A-Za-z_{]"#, options: .regularExpression) == nil else { why = "uses shell variables of this Mac"; return nil }
        guard let segs = segments(cmd) else { why = "runs in the background or substitutes commands"; return nil }
        // A proxy or server on 127.0.0.1 is this Mac's: there, the same address finds nothing.
        guard cmd.range(of: #"(?<![\w.-])(?:127\.\d+\.\d+\.\d+|localhost|\[::1\])(?![\w-])"#, options: [.regularExpression, .caseInsensitive]) == nil else {
            why = "uses a proxy or server on this Mac (localhost)"; return nil
        }
        for s in segs {
            let body = String(s[(Range(prefixes.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))?.range ?? NSRange(), in: s)?.upperBound ?? s.startIndex)...])
            let tool = String(body.split(separator: " ").first ?? "")
            guard allowedTools.contains(tool) || Rules.has(gradleTool, tool) else { why = "also runs \(tool.isEmpty ? "something else" : tool)"; return nil }
            if writesFile(s) { why = "writes a file through a redirect"; return nil }
        }
        let roots = Rules.roots(cmd, cwd: cwd)
        guard roots.count <= 1 else { why = "works in more than one checkout"; return nil }
        let top = roots.first ?? cwd
        guard top != Sh.home, top != "/" else { why = "no project folder"; return nil }
        var sh = Shape(kind: kind, root: top, rel: cwd.hasPrefix(top + "/") ? String(cwd.dropFirst(top.count + 1)) : "", cmd: cmd)
        let base: String = {
            let cd = Rules.matches(cdArg, cmd, group: 1).last.map { unquote($0) }
            return cd.map { $0.hasPrefix("/") ? $0 : cwd + "/" + $0 } ?? cwd
        }()
        func abs(_ p: String) -> String { URL(fileURLWithPath: p.hasPrefix("/") ? p : base + "/" + p).standardizedFileURL.path }

        if kind == "gradle" {
            if Rules.has(gradleInstall, cmd) { why = "installs on a device here"; return nil }
            if Rules.has(gradleDevice, cmd) {
                sh.emulator = true
                sh.cmd = serialAssign.stringByReplacingMatches(in: sh.cmd, range: NSRange(sh.cmd.startIndex..., in: sh.cmd), withTemplate: " ")
            }
            sh.gradleResults = true
        } else {
            if Rules.has(xcRefuse, cmd) { why = "archives or installs (those stay here)"; return nil }
            let dests = Rules.matches(destination, cmd, group: 1)
            guard dests.count <= 1 else { why = "more than one destination"; return nil }
            let test = Rules.has(xcTest, cmd)
            sh.signs = Rules.has(deviceBuild, cmd)
            if let d = dests.first.map(unquote) {
                let sim = d.contains("Simulator"), mac = d.contains("platform=macOS") || d.contains("platform=OS X")
                if !sim && !mac {
                    guard d.contains("platform=iOS") else { why = "a destination other Macs can't build for"; return nil }
                    guard !test else { why = "tests on a real iPhone (it is connected here)"; return nil }
                    // The iPhone is connected here: there it builds for any iPhone, which installs on this one.
                    sh.signs = true
                    sh.cmd = sh.cmd.replacingOccurrences(of: dests[0], with: Rules.quote("generic/platform=iOS"))
                }
                var name = d.range(of: #"name=([^,]+)"#, options: .regularExpression).map { String(d[$0].dropFirst(5)) }
                if let id = d.range(of: #"id=[0-9A-Fa-f-]{36}"#, options: .regularExpression).map({ String(d[$0].dropFirst(3)) }) { name = name ?? simName(id) }
                if sim && test {
                    sh.simulator = true; sh.device = name
                    sh.cmd = sh.cmd.replacingOccurrences(of: dests[0], with: "\"platform=iOS Simulator,id=$RIGWATCH_SIM_UDID\"")
                } else if sim, d.contains("id=") {
                    guard let name else { why = "names a simulator this Mac can't find"; return nil }
                    sh.cmd = sh.cmd.replacingOccurrences(of: dests[0], with: Rules.quote("platform=iOS Simulator,name=\(name)"))
                }
            } else if !Rules.has(simSDK, cmd) && !sh.signs { why = "no simulator or macOS destination (would build for a device)"; return nil }
            else if test { why = "tests without a destination"; return nil }
            // Products and test results come back to the DerivedData this command would have used here.
            let ddGiven = Rules.matches(DepCache.derivedArg, cmd, group: 0).first
            let dd: String
            if let g = ddGiven, let m = DepCache.derivedArg.firstMatch(in: g, range: NSRange(g.startIndex..., in: g)),
               let r = (1...3).lazy.compactMap({ Range(m.range(at: $0), in: g) }).first {
                dd = abs(String(g[r]))
                if !dd.hasPrefix(top + "/") {
                    sh.cmd = sh.cmd.replacingOccurrences(of: g, with: "-derivedDataPath \(root)/.rigwatch-dd")
                    sh.derived = dd
                    sh.back += [(".rigwatch-dd/Build/Products", dd + "/Build/Products"), (".rigwatch-dd/Logs/Test", dd + "/Logs/Test")]
                } else {
                    let rel = String(dd.dropFirst(top.count + 1))
                    sh.keep.append(rel)
                    sh.back += [(rel + "/Build/Products", dd + "/Build/Products"), (rel + "/Logs/Test", dd + "/Logs/Test")]
                }
            } else {
                let proj: String? = {
                    if let p = Rules.matches(projectArg, cmd, group: 2).first { return abs(unquote(p)) }
                    let items = (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []
                    let ws = items.filter { $0.hasSuffix(".xcworkspace") }, pj = items.filter { $0.hasSuffix(".xcodeproj") }
                    return ws.isEmpty && pj.count == 1 ? base + "/" + pj[0] : nil
                }()
                guard let proj, proj.hasPrefix(top + "/") else { why = "can't tell which project it builds"; return nil }
                dd = defaultDerivedData(proj)
                guard let r = sh.cmd.range(of: #"xcodebuild(?=\s|$)"#, options: .regularExpression) else { why = "no xcodebuild"; return nil }
                sh.cmd.insert(contentsOf: " -derivedDataPath \(root)/.rigwatch-dd", at: r.upperBound)
                sh.derived = dd
                sh.back += [(".rigwatch-dd/Build/Products", dd + "/Build/Products"), (".rigwatch-dd/Logs/Test", dd + "/Logs/Test")]
            }
            if let rb = Rules.matches(resultArg, cmd, group: 1).first {
                let local = abs(unquote(rb))
                let there = local.hasPrefix(top + "/") ? String(local.dropFirst(top.count + 1)) : ".rigwatch-out/" + (local as NSString).lastPathComponent
                if !local.hasPrefix(top + "/") { sh.cmd = sh.cmd.replacingOccurrences(of: rb, with: Rules.quote("\(root)/\(there)")) }
                sh.keep.append(there)
                sh.back.append((there, local))
                sh.cmd = "rm -rf \(Rules.quote("\(root)/\(there)")); " + sh.cmd   // xcodebuild won't write over an old bundle
            }
        }
        // Every other path must be inside the worktree (it moves with it) or a tool both Macs have.
        for p in Rules.matches(absPath, sh.cmd, group: 1) where !p.hasPrefix(root) {
            let ok = p == top || p.hasPrefix(top + "/") || ["/dev/", "/usr/", "/bin/", "/opt/homebrew/", "/Applications/Xcode"].contains { p.hasPrefix($0) }
            if !ok { why = "uses \(p), outside its worktree"; return nil }
        }
        sh.cmd = sh.cmd.replacingOccurrences(of: top, with: root)
        return sh
    }

    /// A simulator's name from its UDID (to ask the other Mac for one like it).
    static func simName(_ udid: String) -> String? {
        let r = Sh.run("/usr/bin/xcrun", ["simctl", "list", "devices", "-j"], timeout: 15)
        guard let j = (try? JSONSerialization.jsonObject(with: r.data)) as? [String: Any], let all = j["devices"] as? [String: [[String: Any]]] else { return nil }
        return all.values.joined().first { ($0["udid"] as? String)?.uppercased() == udid.uppercased() }?["name"] as? String
    }

    // MARK: the command

    /// The worktree a command builds in, when there is one.
    static let leadingCd = try! NSRegularExpression(pattern: #"^\s*cd\s+("[^"]+"|'[^']+'|[^\s;&|]+)"#)
    static func root(_ cmd: String, cwd: String) -> String? {
        // A command that starts with `cd` builds there: the session's own folder (often the main checkout, with the
        // build in a worktree) is not a second checkout.
        var cwd = cwd
        if let d = Rules.matches(leadingCd, cmd, group: 1).first {
            let p = (d.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) as NSString).expandingTildeInPath
            cwd = p.hasPrefix("/") ? p : cwd + "/" + p
        }
        let r = Rules.roots(cmd, cwd: cwd)
        guard r.count <= 1, let top = r.first ?? (FileManager.default.fileExists(atPath: cwd + "/gradlew") ? cwd : nil), top != Sh.home else { return nil }
        return top
    }

    /// The command with every Gradle and xcodebuild run going through `peer exec` (an `xcrun` in front is dropped).
    static func wrap(_ cmd: String) -> String? {
        // The session asked for this Mac (inline or exported): it is queued here as usual.
        if cmd.range(of: #"\bRIGWATCH_(?:NO_PEER|HERE)=(?:1|true|yes)\b"#, options: .regularExpression) != nil { return nil }
        var out = cmd, n = 0
        for (kind, tool, skip) in Rules.heavy where kind != "install" {
            for m in tool.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
                guard let r = Range(m.range(at: 1), in: out), !(skip.map { Rules.has($0, cmd) } ?? false) else { continue }
                var at = r.lowerBound
                if out[..<at].hasSuffix("xcrun ") { let s = out.index(at, offsetBy: -6); out.removeSubrange(s..<at); at = s }
                out.insert(contentsOf: "\(Rules.quote(Rules.exe)) peer exec --kind \(kind) -- ", at: at)
                n += 1
            }
        }
        return n > 0 ? out : nil
    }

    /// Arguments as one shell line (quoted only where needed).
    static func shellJoin(_ a: [String]) -> String {
        a.map { $0.range(of: #"^[A-Za-z0-9_@%+=:,./-]+$"#, options: .regularExpression) != nil ? $0 : Rules.quote($0) }.joined(separator: " ")
    }

    /// `peer exec --kind K -- TOOL ARGS`: one build of a command `RigWatch run` sent to another Mac
    /// (RIGWATCH_BUILD_ON). It builds there when it can, or here through the build queue.
    static func exec(_ args: [String]) -> Int32 {
        var a = args, kind = "gradle"
        if a.first == "--kind", a.count > 1 { kind = a[1]; a.removeFirst(2) }
        if a.first == "--" { a.removeFirst() }
        guard !a.isEmpty else { Rules.say("usage: RigWatch peer exec --kind gradle|xcodebuild -- TOOL ARGS"); return 2 }
        let line = shellJoin(a), cwd = FileManager.default.currentDirectoryPath
        let session = ProcessInfo.processInfo.environment["CLAUDE_CODE_SESSION_ID"]
        func here(_ why: String?) -> Int32 {
            if let why {
                Rules.say("RigWatch: this \(kind == "gradle" ? "Gradle" : "xcodebuild") run stays on this Mac: \(why).")
                Rules.log("offload: \(kind) for session \(session ?? "?") stays on this Mac after all: \(why)")
            }
            return Rules.run(["--here", "--kind", kind, "--", "/bin/zsh", "-c", line])
        }
        let env = ProcessInfo.processInfo.environment
        if ["1", "true", "yes"].contains(env["RIGWATCH_NO_PEER"] ?? env["RIGWATCH_HERE"] ?? "") { return here("RIGWATCH_NO_PEER is set") }
        guard let host = env["RIGWATCH_BUILD_ON"], let info = Peers.seen()[host]?.info else { return here(nil) }
        var why = ""
        guard let sh = shape(["/bin/zsh", "-c", line], kind: kind, cwd: cwd, why: &why) else { return here(why) }
        if sh.emulator, info.avds.isEmpty, !info.emulators.contains(where: \.free) { return here("\(info.name) has no Android emulator") }
        if sh.signs {
            let mine = Set(Peers.signingTeams())
            guard !mine.isEmpty else { return here("it builds for a real iPhone and this Mac has no signing certificate to go by") }
            guard let theirs = info.signing, !mine.isDisjoint(with: theirs) else {
                return here("it builds for a real iPhone and \(info.name) can't sign for this Mac's team (sign in to Xcode there, Settings > Accounts, with the same team)")
            }
        }
        if sh.kind == "xcodebuild", !info.xcode { return here("\(info.name) has no Xcode") }
        if let f = failures()[key(host, sh.root)], Date().timeIntervalSince(f.at) < skipFor { return here("\(info.name) couldn't build it lately (\(f.why))") }
        var sources: [DispatchSourceSignal] = []
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            src.setEventHandler {
                if copyPid > 0 { kill(copyPid, SIGTERM); exit(128 + sig) }   // stopped while copying: the copy stops too
                if Rules.child > 0 { kill(Rules.child, sig) } else { exit(128 + sig) }
            }
            src.resume(); sources.append(src)
        }
        defer { withExtendedLifetime(sources) {} }
        if let code = run(sh, host: host, info: info, session: session) { return code }
        let code = here(nil)
        if code != 0, let back = lastFallback { noteFailure(back, sh.root, nil) }   // it fails here too: the project, not that Mac
        return code
    }

    // MARK: which Mac

    static func key(_ host: String, _ root: String) -> String { host + "|" + root }
    static let failuresFile = Rules.dir + "/offload-failures.json", copiesFile = Rules.dir + "/remote-copies.json"
    static let skipFor: TimeInterval = 6 * 3600
    static func failures() -> [String: Peers.Failure] {
        let all = FileManager.default.contents(atPath: failuresFile).flatMap { try? Leases.decoder.decode([String: Peers.Failure].self, from: $0) } ?? [:]
        // Entries older than the skip have no effect; drop them from the file so it shows only what still applies.
        let live = all.filter { Date().timeIntervalSince($0.value.at) < skipFor }
        if live.count < all.count { Rules.write(try? Leases.encoder.encode(live), to: failuresFile) }
        return live
    }
    static func noteFailure(_ host: String, _ root: String, _ why: String?) {
        var all = failures().filter { Date().timeIntervalSince($0.value.at) < skipFor }
        all[key(host, root)] = why.map { Peers.Failure(at: Date(), why: $0) }
        Rules.write(try? Leases.encoder.encode(all), to: failuresFile)
    }
    static func copies() -> [String: Date] {
        FileManager.default.contents(atPath: copiesFile).flatMap { try? Leases.decoder.decode([String: Date].self, from: $0) } ?? [:]
    }
    static func noteCopy(_ host: String, _ root: String) {
        let fd = open(Rules.dir + "/remote-copies.lock", O_RDWR | O_CREAT, 0o644)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { close(fd) } }
        var all = copies(); all[key(host, root)] = Date()
        Rules.write(try? Leases.encoder.encode(all), to: copiesFile)
    }

    /// The least busy allowed Mac that can take this build now, or nil to build here. Only when this Mac is busy
    /// or its slots are full (`full`), and only a Mac clearly less busy and not itself near busy. A Mac without a
    /// copy of the worktree yet, or with an older RigWatch, gets one in the background and is used next time.
    /// The Mac the last `pick` started getting ready (a copy of the worktree, a newer RigWatch), or nil.
    static var preparing: String?

    static func pick(kind: String, root: String, full: Bool) -> (host: String, info: PeerInfo)? {
        preparing = nil
        let h = Peers.here(), spare = Peers.limits.offloadMode == "spare"
        // Peers first: every build goes to a peer with room, however idle this Mac is, so this Mac keeps its CPU for
        // the sessions and devices; it builds here only when no peer can take it.
        let peersFirst = Peers.limits.offloadMode == "peers"
        guard full || peersFirst || Peers.hereIsBusy(h) else { return nil }
        let allowed = Peers.load().filter(\.allowed)
        guard !allowed.isEmpty else { return nil }
        var seen = Peers.seen()
        let fresh = { (s: Peers.Seen?) in s.map { Date().timeIntervalSince($0.at) < 180 } ?? false }
        if !allowed.contains(where: { fresh(seen[$0.host]) }) {
            let stamp = Rules.dir + "/peer-refresh.stamp"
            if (Rules.mtime(stamp).map { Date().timeIntervalSince($0) > 60 } ?? true) {
                Rules.write(Data(), to: stamp); Peers.refreshAllowed(); seen = Peers.seen()
            }
        }
        let skip = failures(), have = copies(), took = copyTimes()
        let ok = allowed.compactMap { p -> (String, PeerInfo)? in
            guard let s = seen[p.host], fresh(s) else { return nil }
            let i = s.info
            // Spare mode: that Mac takes builds however busy it gets (its own queue still limits them), unless its
            // memory is critical. Balanced: only a Mac clearly less busy than this one and not near busy itself.
            let fits = spare ? i.pressure < 4
                : peersFirst ? i.pressure < 2 && (i.memFree ?? 100) >= Peers.limits.memFreeMin && i.busy < Peers.busyAt - Peers.margin
                : i.pressure < 2 && (i.memFree ?? 100) >= Peers.limits.memFreeMin && i.busy < Peers.busyAt - Peers.margin && (full || i.busy <= h.busy - Peers.margin)
            guard i.sharing, fits, kind != "xcodebuild" || i.xcode,
                  skip[key(p.host, root)].map({ Date().timeIntervalSince($0.at) > skipFor }) ?? true else { return nil }
            return (p.host, i)
        }
        let sent = Dictionary(grouping: Peers.activeRuns(), by: \.host).mapValues(\.count)
        // Peers first sends only to a Mac with room left for one more build (its own queue would only make it wait).
        let ranked = ok.filter { !peersFirst || full || room($0.1, sent[$0.0] ?? 0) >= 1 }
            .sorted { room($0.1, sent[$0.0] ?? 0) > room($1.1, sent[$1.0] ?? 0) }
        guard let best = ranked.first else { return nil }
        for (host, i) in ranked where Peers.build(i.version) >= minBuild && have[key(host, root)] != nil {
            let t = took[key(host, root)].flatMap { Date().timeIntervalSince($0.at) < skipFor ? $0.seconds : nil }
            // Copying it there lately took longer than most builds: worth it only when this build would otherwise wait.
            if !full, let t, t > slowCopy { continue }
            if host == best.0 { return (host, i) }
            // A Mac with less room that already has a copy: only while bringing that copy up to date is quick.
            if (t ?? 0) < 120 {
                if have[key(best.0, root)] == nil { prepare(best.0, root) }
                return (host, i)
            }
        }
        // None has a copy yet: the Mac with the most room gets one in the background, unless one is on its way somewhere.
        prepare(best.0, root)
        preparing = best.1.name
        return nil
    }

    /// How many more builds a Mac has room for: spare cores (4 a build) or free memory (6 GB a build), whichever is
    /// less, minus the builds this Mac has sent it that haven't finished.
    static func room(_ i: PeerInfo, _ sent: Int) -> Double {
        let cores = Double(i.cores) * max(0, 1 - i.busy), mem = i.memGB * Double(i.memFree ?? 50) / 100
        return min(cores / 4, mem / 6) - Double(sent)
    }

    /// Whether a copy of this worktree to any Mac is running now (its lock is held).
    static func copying(_ root: String) -> String? {
        Peers.load().map(\.host).first { host in
            let fd = open(copyLock(host, root), O_RDONLY)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            if flock(fd, LOCK_SH | LOCK_NB) != 0 { return true }
            flock(fd, LOCK_UN); return false
        }
    }
    static func copyLock(_ host: String, _ root: String) -> String {
        Rules.dir + "/copy-" + Insecure.MD5.hash(data: Data(key(host, root).utf8)).map { String(format: "%02x", $0) }.joined() + ".lock"
    }

    /// `RigWatch peer sync HOST ROOT` in the background (at most every 15 minutes per Mac and worktree): brings
    /// RigWatch there up to date and copies the worktree over, so the next build can go there without waiting.
    static func prepare(_ host: String, _ root: String) {
        let dir = Rules.dir + "/sync"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let stamp = dir + "/" + Insecure.MD5.hash(data: Data(key(host, root).utf8)).map { String(format: "%02x", $0) }.joined()
        if let d = Rules.mtime(stamp), Date().timeIntervalSince(d) < 900 { return }
        // One copy of a worktree on its way at a time: a second Mac would only halve the speed of both.
        if let other = copying(root) { Rules.say("RigWatch: \(Views.tilde(root)) is being copied to \(other); this build waits for a slot here or for that copy."); return }
        Rules.write(Data(), to: stamp)
        Rules.say("RigWatch: getting \(host) ready to take builds of \(Views.tilde(root)) in the background; this build waits for a slot here meanwhile and goes there once the copy is ready.")
        detach([Rules.exe, "peer", "sync", host, root])
    }

    /// Starts a process in a session of its own, so it outlives this command.
    static func detach(_ argv: [String]) {
        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr); defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        var acts: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&acts); defer { posix_spawn_file_actions_destroy(&acts) }
        for fd: Int32 in 0...2 { posix_spawn_file_actions_addopen(&acts, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0) }
        let c = argv.map { strdup($0) } + [nil]
        let env = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { c.forEach { free($0) }; env.forEach { free($0) } }
        var pid: pid_t = 0
        _ = posix_spawn(&pid, argv[0], &acts, &attr, c, env)
    }

    /// `peer sync HOST ROOT`.
    static func sync(_ a: [String]) -> Int32 {
        guard a.count == 2 else { Rules.say("usage: RigWatch peer sync HOST ROOT"); return 2 }
        let (host, root) = (a[0], a[1])
        guard case .online(let i) = Peers.ready(host), i.home != nil else { Rules.log("offload: \(host) is not ready to take builds"); return 1 }
        let t0 = Date(), r = copy(root, to: host, keep: [], wait: false)
        if r.code == -2 { Rules.log("offload: \(Views.tilde(root)) is already being copied to \(host)"); return 0 }
        guard r.code == 0 else { Rules.log("offload: could not copy \(Views.tilde(root)) to \(host): \(r.err.prefix(200))"); return 1 }
        noteCopy(host, root)
        Rules.log("offload: copied \(Views.tilde(root)) to \(host) in \(Int(Date().timeIntervalSince(t0))) s")
        return 0
    }

    /// `peer trim`, run here by a Mac that sends its builds here, before each copy: the clean-up of the copies
    /// other Macs sent (idle, over the cap), and of this Mac's copies elsewhere of worktrees gone here; at most every 10 minutes. RigWatch's own cache, so even with the Rules paused.
    static func trim() -> Int32 {
        let stamp = Rules.dir + "/last-copy-trim"
        if let t = Rules.mtime(stamp), Date().timeIntervalSince(t) < 600 { return 0 }
        let fd = open(Rules.dir + "/copy-trim.lock", O_RDWR | O_CREAT, 0o644)
        defer { if fd >= 0 { close(fd) } }
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { return 0 }
        FileManager.default.createFile(atPath: stamp, contents: nil)
        var r = ReapReport()
        Rules.reapRemoteCopies(&r, ProcSampler().sample(), apply: true)
        dropGone(&r, apply: true)
        for a in r.actions { print("\(a.target): \(a.detail): \(a.result ?? "")") }
        return 0
    }

    /// Copies on other Macs of worktrees that are gone here: removed there, with their branch in the mirror.
    static func dropGone(_ r: inout ReapReport, apply: Bool) {
        for (k, _) in copies() {
            let parts = k.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, !FileManager.default.fileExists(atPath: parts[1]) else { continue }
            let (host, root) = (parts[0], parts[1]), dest = copyDir(root), base = (dest as NSString).deletingLastPathComponent
            var a = ReapAction(kind: "Remove copy", target: "\(host): \((dest as NSString).lastPathComponent)", key: k, detail: "copy of \(Views.tilde(root)), which is gone here")
            if apply {
                let q = Rules.quote, name = (dest as NSString).lastPathComponent
                let res = RemoteTree.ssh(host, "cd \"$HOME\" || exit 1; rm -rf \(q(dest)) || exit 1; for m in \(q(base))/.mirrors/*.git; do [ -d \"$m\" ] || continue; "
                    + "git --git-dir=\"$m\" update-ref -d refs/heads/\(q(name)) 2>/dev/null; git --git-dir=\"$m\" worktree prune; done; true", timeout: 300)
                if res.code == 0 {
                    a.outcome = "done"; a.result = "removed"
                    let fd = open(Rules.dir + "/remote-copies.lock", O_RDWR | O_CREAT, 0o644)
                    if fd >= 0 { flock(fd, LOCK_EX) }
                    var all = copies(); all[k] = nil
                    Rules.write(try? Leases.encoder.encode(all), to: copiesFile)
                    if fd >= 0 { close(fd) }
                } else { a.outcome = "failed"; a.result = res.code == 255 ? "\(host) not reachable; tried again later" : "exit \(res.code): \(res.err.prefix(150))" }
                Rules.log("offload: \(a.detail) on \(host): \(a.result ?? "")")
            }
            r.actions.append(a)
        }
    }

    // MARK: running it there

    /// Where a worktree's copy lives on the other Mac, relative to its home.
    static func copyDir(_ root: String) -> String {
        let me = Peers.localName.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression)
        let tag = Insecure.MD5.hash(data: Data(root.utf8)).prefix(3).map { String(format: "%02x", $0) }.joined()
        let name = (root as NSString).lastPathComponent.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
        return "Library/Caches/RigWatch/remote/\(me)/\(name)-\(tag)"
    }

    /// Brings the copy of a worktree there up to date: by git (RemoteTree: history once per repository, then only
    /// the changes; node_modules and Pods once per lockfile), or for a folder git can't send, the whole tree by rsync.
    /// Build output never goes: the copy there keeps its own and builds incrementally.
    /// One copy of a worktree to a Mac runs at a time: another build of it waits (`wait`) and then sends only what
    /// changed meanwhile, or, for a background `peer sync`, leaves it to the copy already running.
    static func copy(_ root: String, to host: String, keep: [String], wait: Bool = true) -> Sh.Result {
        let dest = copyDir(root)
        let fd = open(copyLock(host, root), O_RDWR | O_CREAT, 0o644)
        defer { if fd >= 0 { close(fd) } }
        if fd >= 0, flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard wait else { return Sh.Result(code: -2, data: Data(), err: "another copy of it is running") }
            Rules.say("RigWatch: another build is copying \(Views.tilde(root)) to \(host); waiting for it, then sending only what changed.")
            flock(fd, LOCK_EX)
        }
        stopOrphans(host: host, dest: dest)
        let t0 = Date(), limit = 3600.0
        var prog = CopyProgress(host: host, root: root, pid: getpid(), pidStart: ProcSampler.startTime(getpid()) ?? 0, since: t0)
        var wrote = Date.distantPast
        // An rsync to that Mac with progress for `status`: no compression or diffing over a Thunderbolt bridge or LAN.
        func rsync(_ extra: [String]) -> Sh.Result {
            let args = [nearby(host) ? "-a" : "-az", "--progress", "-e", RemoteTree.sshCommand] + (nearby(host) ? ["--whole-file"] : []) + extra
            let r = Sh.run("/usr/bin/rsync", args, timeout: max(60, limit - Date().timeIntervalSince(t0)), started: { copyPid = $0 }) { line in
                // openrsync: "   3000000 100%  363.54MB/s   00:00:00 (xfer#1, to-check=1/4)" once a file is sent.
                guard line.contains("to-check="), let m = progressLine.firstMatch(in: String(line), range: NSRange(line.startIndex..., in: line)) else { return }
                let s = String(line), n = { (i: Int) in Range(m.range(at: i), in: s).flatMap { Int64(s[$0]) } ?? 0 }
                prog.bytes += n(1); prog.files = Int(n(2)); prog.total = Int(n(3))
                if Date().timeIntervalSince(wrote) > 3 { wrote = Date(); noteProgress(prog) }
            }
            copyPid = 0
            return r
        }
        noteProgress(prog)
        var r: Sh.Result
        if let why = RemoteTree.unsupported(root) {
            Rules.log("offload: copying all of \(Views.tilde(root)) to \(host): \(why)")
            r = rsync(wholeTreeArgs(root, dest: dest, keep: keep) + [root + "/", host + ":" + dest + "/"])
        } else {
            r = RemoteTree.send(root, to: host, dest: dest, keep: keep, rsync: rsync)
        }
        copyPid = 0
        noteProgress(nil, removing: prog.id)
        if r.code == 0 || r.code == 24 { localize(root, on: host, dest: dest) }
        let took = Date().timeIntervalSince(t0)
        noteCopyTime(host, root, took)
        // 24: files vanished while copying, as they do in a worktree a session is working in. The rest got there.
        if r.code == 24 { r = Sh.Result(code: 0, data: r.data, err: r.err) }
        if r.code != 0, r.err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let why = took >= limit - 5 ? "it was still copying after \(Int(limit / 60)) min and was stopped"
                : r.code == 255 ? "ssh to \(host) failed" : r.code == 15 || r.code == 20 ? "the copy was stopped" : "rsync exited \(r.code)"
            r = Sh.Result(code: r.code, data: r.data, err: "\(why) (after \(Int(took)) s)")
        }
        return r
    }

    /// The old way, for a folder git can't send (no git, submodules, LFS): the whole tree with rsync, without build
    /// output (excluded by name and by what Xcode keeps in DerivedData) or files over 100 MB.
    static func wholeTreeArgs(_ root: String, dest: String, keep: [String]) -> [String] {
        var args = ["--delete", "--max-size=100m", "--rsync-path", "mkdir -p \(Rules.quote(dest)) && touch \(Rules.quote(dest))/\(usedStamp) && rsync", "--exclude", "/" + usedStamp]
        for f in ["- node_modules/**/android/build/", "- **/node_modules/**/android/build/", "+ node_modules/**", "+ **/node_modules/**", "+ Pods/**", "+ **/Pods/**"] { args += ["--filter", f] }
        // React Native's iOS codegen writes headers the Pods project compiles into build/generated/ios: those go too.
        for b in ["/build/", "/ios/build/"] {
            for f in ["+ \(b)", "+ \(b)generated/", "+ \(b)generated/ios/", "+ \(b)generated/ios/**", "- \(b)**"] { args += ["--filter", f] }
        }
        for x in RemoteTree.outputDirs { args += ["--exclude", x + "/"] }
        for x in RemoteTree.outputSuffixes { args += ["--exclude", "*" + x] }
        for k in Set(keep + derivedDirs(root)) { args += ["--exclude", "/" + k + "/"] }
        return args
    }

    /// Xcode DerivedData folders inside a worktree (a `-derivedDataPath` such as `.dd`), whatever their name and
    /// whether or not git ignores them: tens of GB the other Mac rebuilds on its own. Found by what Xcode keeps in
    /// them, up to three levels down.
    static func derivedDirs(_ root: String) -> [String] {
        let fm = FileManager.default, skip: Set = [".git", "node_modules", "Pods", "build", ".gradle"]
        var out: [String] = [], level = [""]
        for _ in 0..<3 {
            var next: [String] = []
            for rel in level {
                for name in (try? fm.contentsOfDirectory(atPath: root + "/" + rel)) ?? [] where !skip.contains(name) {
                    let r = rel.isEmpty ? name : rel + "/" + name, full = root + "/" + r
                    var dir: ObjCBool = false
                    guard fm.fileExists(atPath: full, isDirectory: &dir), dir.boolValue, (try? fm.destinationOfSymbolicLink(atPath: full)) == nil else { continue }
                    if ["ModuleCache.noindex", "Index.noindex", "Build/Intermediates.noindex"].contains(where: { fm.fileExists(atPath: full + "/" + $0) }) { out.append(r) }
                    else if !name.hasSuffix(".xcodeproj"), !name.hasSuffix(".xcworkspace"), !name.hasSuffix(".app") { next.append(r) }
                }
            }
            level = next
        }
        return out
    }

    /// A Mac on a Thunderbolt bridge or the local network: compressing and diffing the copy only costs CPU there
    /// (measured over Thunderbolt with this Mac busy: 24 MB/s with -z, 41 MB/s with --whole-file and no -z).
    static func nearby(_ host: String) -> Bool {
        nearbyLock.lock(); defer { nearbyLock.unlock() }
        if let n = nearbyHosts[host] { return n }
        let name = Sh.run("/usr/bin/ssh", ["-G", host], timeout: 5).out.split(separator: "\n")
            .first { $0.hasPrefix("hostname ") }.map { String($0.dropFirst(9)) } ?? host
        let n = name.hasSuffix(".local") || name.range(of: #"^(?:169\.254|10|192\.168|172\.(?:1[6-9]|2\d|3[01]))\."#, options: .regularExpression) != nil
        nearbyHosts[host] = n
        return n
    }
    private static var nearbyHosts: [String: Bool] = [:]
    private static let nearbyLock = NSLock()

    /// CocoaPods writes the worktree's absolute path into the Pods project, its xcconfigs and file lists, and Xcode
    /// keeps it in DerivedData: in the copy there it names this Mac's folder, and the build fails ("Unable to load
    /// contents of file list"). This points the copy's Pods files at the copy, and removes DerivedData there that was
    /// copied from here (by RigWatch before 1.11.10), so that Mac builds its own.
    static func localize(_ root: String, on host: String, dest: String) {
        let pat = NSRegularExpression.escapedPattern(for: root).replacingOccurrences(of: "#", with: "\\#")
        var sh = "cd \(Rules.quote(dest)) || exit 0; there=\"$HOME/\(dest)\"; "
        // No globs: the login shell there may be zsh, which ends the whole command on a pattern that matches nothing.
        sh += "find . -maxdepth 2 -type d -name Pods | while IFS= read -r d; do LC_ALL=C grep -rlF --null \(Rules.quote(root)) \"$d\" --include='*.xcconfig' --include='*.pbxproj' --include='*.xcfilelist' --include='*.sh' "
            + "| xargs -0 sed -i '' \"s#\(pat)#$there#g\"; done; "
        // React Native's .xcode.env.local names this Mac's node by its Homebrew version folder: there, its own node.
        sh += "n=$(PATH=/opt/homebrew/bin:/usr/local/bin:$PATH command -v node); find . -maxdepth 2 -name .xcode.env.local | while IFS= read -r f; do "
            + "b=$(sed -n 's/^export NODE_BINARY=//p' \"$f\"); [ -n \"$n\" ] && [ -n \"$b\" ] && [ ! -x \"$b\" ] && sed -i '' \"s#^export NODE_BINARY=.*#export NODE_BINARY=$n#\" \"$f\"; done; "
        for d in derivedDirs(root) { sh += "[ -f \(Rules.quote(d))/info.plist ] && LC_ALL=C grep -qF \(Rules.quote(root)) \(Rules.quote(d))/info.plist && rm -rf \(Rules.quote(d)); " }
        sh += "true"
        let r = Sh.run("/usr/bin/ssh", RemoteTree.sshOpts + [host, sh], timeout: 300)
        if r.code != 0 { Rules.log("offload: could not point the copy of \(Views.tilde(root)) on \(host) at itself (exit \(r.code)): \(r.err.prefix(200))") }
    }

    // MARK: copies in progress, for `status` and build_queue

    struct CopyProgress: Codable {
        var host: String, root: String, pid: Int32, pidStart: UInt64, since: Date
        var bytes: Int64 = 0, files = 0, total = 0
        var id: String { key(host, root) + "|\(pid)" }
        var line: String {
            let secs = max(1, Date().timeIntervalSince(since))
            return "copying \(Views.tilde(root)) to \(host): \(Fmt.bytes(UInt64(bytes))) sent"
                + (total > 0 ? ", files \(files) of \(total)" : "") + ", \(Fmt.bytes(UInt64(Double(bytes) / secs)))/s, \(Int(secs / 60)) min"
        }
    }
    static let progressLine = try! NSRegularExpression(pattern: #"^\s*(\d+)\s+100%.*to-check=(\d+)/(\d+)"#)
    static let progressFile = Rules.dir + "/copy-progress.json"
    static let progressLock = NSLock()
    static func copiesInProgress() -> [CopyProgress] {
        (FileManager.default.contents(atPath: progressFile).flatMap { try? Leases.decoder.decode([CopyProgress].self, from: $0) } ?? [])
            .filter { ProcSampler.startTime($0.pid) == $0.pidStart }
    }
    static func noteProgress(_ p: CopyProgress?, removing id: String? = nil) {
        progressLock.lock(); defer { progressLock.unlock() }
        let fd = open(Rules.dir + "/remote-copies.lock", O_RDWR | O_CREAT, 0o644)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { close(fd) } }
        var all = copiesInProgress().filter { $0.id != (p?.id ?? id) }
        if let p { all.append(p) }
        Rules.write(try? Leases.encoder.encode(all), to: progressFile)
    }

    static let usedStamp = ".rigwatch-used"
    /// The rsync of a copy in progress, stopped with the build that started it.
    static var copyPid: pid_t = 0

    /// With the lock held no other copy to that folder is meant to run: one still running belongs to a build that
    /// went away without stopping it, and would only fight this one.
    static func stopOrphans(host: String, dest: String) {
        let target = host + ":" + dest + "/"
        for l in Sh.run("/bin/ps", ["-Ao", "pid=,ppid=,command="], timeout: 20).out.split(separator: "\n") {
            let f = l.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard f.count == 3, let pid = Int32(f[0]), pid != getpid(), f[2].hasPrefix("/usr/bin/rsync "), f[2].hasSuffix(target) else { continue }
            kill(pid, SIGTERM)
            Rules.log("offload: stopped a copy to \(host) left running by a build that went away (rsync \(pid))")
        }
    }

    /// How long the last copy of each worktree to each Mac took, successful or not.
    static let copyTimesFile = Rules.dir + "/copy-times.json"
    struct CopyTime: Codable { var at: Date; var seconds: Double }
    static func copyTimes() -> [String: CopyTime] {
        FileManager.default.contents(atPath: copyTimesFile).flatMap { try? Leases.decoder.decode([String: CopyTime].self, from: $0) } ?? [:]
    }
    static func noteCopyTime(_ host: String, _ root: String, _ s: TimeInterval) {
        let fd = open(Rules.dir + "/remote-copies.lock", O_RDWR | O_CREAT, 0o644)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { close(fd) } }
        var all = copyTimes().filter { Date().timeIntervalSince($0.value.at) < skipFor }
        all[key(host, root)] = CopyTime(at: Date(), seconds: s)
        Rules.write(try? Leases.encoder.encode(all), to: copyTimesFile)
    }
    /// A copy slower than this sends the next build of that worktree there only when no slot is free here.
    static let slowCopy: TimeInterval = 600

    /// Output that means the other Mac can't build this project at all (rather than the code being wrong).
    static let cantBuildThere = try! NSRegularExpression(pattern: [
        #"Could not (?:resolve|GET|HEAD|download)\b"#, #"Received status code 40[13]"#, #"40[13] (?:Unauthorized|Forbidden)"#, #"UnknownHostException"#,
        #"SDK location not found"#, #"Failed to find (?:target|Build Tools|Platform)"#, #"licen[cs]es? for .* not (?:been )?accepted"#,
        #"No matching toolchains"#, #"Cannot find a Java installation"#, #"JAVA_HOME is (?:not set|set to an invalid)"#, #"Unsupported class file major version"#,
        #"Could not determine java version"#, #"NDK (?:is not installed|not configured)"#, #"Gradle could not start"#, #"command not found"#,
        #"not a git repository"#, #"xcode-select: error"#, #"Unable to find a (?:destination|device)"#, #"requires a provisioning profile"#,
        #"No signing certificate"#, #"No Accounts?\b"#, #"No profiles for"#, #"No Account for Team"#, #"errSecInternalComponent"#, #"unable to find utility"#, #"agreed to the Xcode license"#, #"Could not resolve package dependencies"#,
        #"Failed to clone repository"#, #"SDK "[^"]*" cannot be located"#, #"There is no SDK"#, #"is not installed\. To use with Xcode"#,
        #"exit value 127\b"#, #"problem occurred evaluating settings"#, #"Unable to locate a Java Runtime"#, #"Cannot run program"#, #"node: not found"#, #"No such file or directory: node"#, #"Authorization is required to install"#, #"requires Xcode"#, #"No such module"#, #"Connection refused"#, #"Connect to (?:127\.0\.0\.1|localhost)"#,
        #"RigWatch on [^:]+: (?:no folder|no simulator|no emulator|this Mac doesn't share|.* doesn't share)"#, #"RIGWATCH_NO_PEER"#,
    ].joined(separator: "|"), options: [.caseInsensitive])

    /// Runs the build there, streaming its output here. The exit code, or nil when it should run here instead.
    static func run(_ sh: Shape, host: String, info: PeerInfo, session: String?) -> Int32? {
        // An older RigWatch app here rewriting the status file drops `home`: then ask that Mac.
        guard let home = info.home ?? Sh.run("/usr/bin/ssh", Peers.sshOpts + [host, "echo $HOME"], timeout: 15).out.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else { return nil }
        let rel = copyDir(sh.root), there = home + "/" + rel, t0 = Date()
        var rr = Peers.RemoteRun(host: host, mac: info.name, session: session ?? "", command: sh.cmd.replacingOccurrences(of: root, with: sh.root),
                                 cwd: sh.root, phase: "copying", since: t0, pid: getpid(), pidStart: ProcSampler.startTime(getpid()) ?? 0)
        Peers.noteRun(rr)
        defer { Peers.noteRun(nil, removing: rr.id) }
        Rules.say("RigWatch: this Mac is \(Peers.hereIsBusy(Peers.here()) ? "busy" : "out of build slots"), so this build runs on \(info.name) (\(host), busy \(String(format: "%.2f", info.busy))); copying changes there.")
        let c = copy(sh.root, to: host, keep: sh.keep)
        guard c.code == 0 else {
            let why = "could not copy the worktree there: " + c.err.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)
            Rules.log("offload: \(host): \(why)"); Rules.say("RigWatch: \(why); building here instead.")
            return nil
        }
        noteCopy(host, sh.root)
        let copied = Date().timeIntervalSince(t0)
        var args = ["run", "--dir", there + (sh.rel.isEmpty ? "" : "/" + sh.rel), "--kind", sh.kind, "--watch-stdin", "--session", session ?? "agent", "--from", Peers.localName]
        if sh.simulator { args.append("--simulator") }
        if sh.emulator { args.append("--emulator") }
        if let d = sh.device { args += ["--name", d] }
        args += ["--", sh.cmd.replacingOccurrences(of: root, with: there)]
        let key = BuildProgress.key(sh.cmd)
        rr.phase = "running"; rr.progress = BuildProgress(total: BuildProgress.total(key)); Peers.noteRun(rr)

        // Paths there read as this Mac's: specific outputs first, then the worktree.
        let maps = (sh.back.map { (there + "/" + $0.from, $0.to) } + (sh.derived.map { [(there + "/.rigwatch-dd", $0)] } ?? []) + [(there, sh.root)])
            .sorted { $0.0.count > $1.0.count }
        let p = Process(), inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = Peers.sshOpts + ["-T", host, Peers.remote(args)]
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = errPipe
        let lock = NSLock()
        var tail: [String] = [], noted = Date()
        func pump(_ pipe: Pipe, to out: FileHandle) -> DispatchGroup {
            let g = DispatchGroup(); g.enter()
            DispatchQueue.global().async {
                var buf = Data()
                func emit(_ line: Data) {
                    var s = String(decoding: line, as: UTF8.self)
                    for (a, b) in maps where s.contains(a) { s = s.replacingOccurrences(of: a, with: b) }
                    out.write(Data(s.utf8))
                    lock.lock(); defer { lock.unlock() }
                    tail.append(s); if tail.count > 400 { tail.removeFirst(tail.count - 400) }
                    // The Builds page shows the task it is on: the run's record, rewritten at most once a second.
                    if rr.progress?.read(s) == true, Date().timeIntervalSince(noted) > 1 { noted = Date(); Peers.noteRun(rr) }
                }
                while let d = try? pipe.fileHandleForReading.read(upToCount: 65536), !d.isEmpty {
                    buf.append(d)
                    while let nl = buf.firstIndex(of: 0x0A) { emit(buf[buf.startIndex...nl]); buf.removeSubrange(buf.startIndex...nl) }
                }
                if !buf.isEmpty { emit(buf) }
                g.leave()
            }
            return g
        }
        do { try p.run() } catch { return nil }
        Rules.child = p.processIdentifier   // a signal to `RigWatch run` stops the ssh, and with it the build there
        let g1 = pump(outPipe, to: .standardOutput), g2 = pump(errPipe, to: .standardError)
        p.waitUntilExit(); g1.wait(); g2.wait()
        Rules.child = 0
        withExtendedLifetime(inPipe) {}
        let started = t0.addingTimeInterval(copied)
        if p.terminationReason == .uncaughtSignal { return 128 + p.terminationStatus }
        let code = p.terminationStatus
        let text = tail.joined()
        if code == 255 || (code != 0 && Rules.has(cantBuildThere, text)) {
            let line = code == 255 ? "SSH connection failed" : text.split(separator: "\n").first { Rules.has(cantBuildThere, String($0)) }.map { String($0).trimmingCharacters(in: .whitespaces) } ?? "it failed there"
            let why = String(line.prefix(200))
            noteFailure(host, sh.root, why)
            Rules.log("offload: \(host) can't build \(Views.tilde(sh.root)): \(why)")
            Rules.say("RigWatch: \(info.name) can't build this project (\(why)). Building it here instead; \(info.name) is skipped for it for \(Int(skipFor / 3600)) hours.")
            lastFallback = host
            return nil
        }
        if code == 0, let pr = rr.progress, pr.finished { BuildProgress.saveTotal(key, pr.done) }
        rr.phase = "copying back"; Peers.noteRun(rr)
        let back = copyBack(sh, host: host, there: rel)
        Rules.log("offload: built on \(host) for session \(session ?? "?") (exit \(code), copy \(Int(copied)) s, run \(Int(Date().timeIntervalSince(started))) s): \(sh.cmd.prefix(120))")
        Rules.say("RigWatch: built on \(info.name) in \(Int(Date().timeIntervalSince(t0))) s (copying \(Int(copied)) s)\(back.isEmpty ? "" : "; results copied back: " + back.joined(separator: ", ")).")
        BuildHistory.add(BuildRecord(kind: sh.kind, pool: sh.kind == "xcodebuild" ? "ios" : "android", cwd: sh.root, cmd: String(rr.command.suffix(200)), session: session,
                                     queuedAt: t0, startedAt: started, endedAt: Date(), waited: copied, overflow: false, forced: false,
                                     releasedEarly: false, exit: code, host: "\(info.name) (\(host))"))
        return code
    }
    /// The Mac a build last fell back from (so a failure here too clears its mark: the project was at fault).
    static var lastFallback: String?

    /// Copies the build's results back: Gradle's outputs, reports and test results of every module, or the Xcode
    /// products and test results into the DerivedData this Mac would have used.
    static func copyBack(_ sh: Shape, host: String, there: String) -> [String] {
        let ssh = (["/usr/bin/ssh"] + Peers.sshOpts).joined(separator: " ")
        var got: [String] = []
        if sh.gradleResults {
            let r = Sh.run("/usr/bin/rsync", ["-az", "-e", ssh, "--prune-empty-dirs", "--exclude", ".git/", "--exclude", "node_modules/", "--exclude", ".gradle/",
                                              "--exclude", "build/intermediates/", "--exclude", "build/tmp/", "--exclude", "build/kotlin/",
                                              "--include", "*/", "--include", "build/outputs/***", "--include", "build/reports/***", "--include", "build/test-results/***",
                                              "--exclude", "*", host + ":" + there + "/", sh.root + "/"], timeout: 1800)
            if r.code == 0 { got.append("build outputs, reports and test results") } else { Rules.say("RigWatch: copying results back failed: \(r.err.prefix(200))") }
        }
        for (from, to) in sh.back {
            try? FileManager.default.createDirectory(atPath: to, withIntermediateDirectories: true)
            let r = Sh.run("/usr/bin/rsync", ["-az", "-e", ssh, host + ":" + there + "/" + from + "/", to + "/"], timeout: 1800)
            if r.code == 0 { got.append(Views.tilde(to)) } else if (try? FileManager.default.contentsOfDirectory(atPath: to))?.isEmpty == true { try? FileManager.default.removeItem(atPath: to) }
        }
        return got
    }
}
