import Foundation

struct Worktree: Identifiable, Hashable {
    let path: String
    var repo: String
    var repoPath: String
    var branch: String
    var head: String
    var exists: Bool
    var isMain: Bool
    var locked: Bool
    var prunable: Bool
    var session: String?            // session uuid found in the path
    var lastActivity: Date?
    var usedBy: [String] = []       // processes whose cwd is inside
    var sizeKB: Int64?
    var id: String { path }
}

struct SafetyCheck {
    var safe: Bool
    var force: Bool                 // only untracked setup files left, so `remove --force` loses nothing
    var reasons: [String]
}

/// `git worktree list` for every repo one folder below home (~/<folder>/<repo>), plus a strict
/// "would removing this lose anything?" check before any removal.
enum Worktrees {
    static let setupFiles = ["local.properties", "node_modules", "app/keystore", ".claude/", "ios/Pods", "Pods/", "Secrets.xcconfig", ".build/", "build/", ".gradle/", ".kotlin/"]
    static let uuidRe = #"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"#

    static func repos() -> [String] {
        var out: [String] = []
        let skip: Set<String> = ["Library", "Applications", "Movies", "Music", "Pictures", "Public", "Desktop", "Downloads"]
        let roots = ((try? FileManager.default.contentsOfDirectory(atPath: Sh.home)) ?? [])
            .filter { !$0.hasPrefix(".") && !skip.contains($0) }.map { Sh.home + "/" + $0 }
        for root in roots {
            for d in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] {
                var dir: ObjCBool = false
                let p = "\(root)/\(d)"
                if FileManager.default.fileExists(atPath: p + "/.git", isDirectory: &dir), dir.boolValue { out.append(p) }
            }
        }
        return out.sorted()
    }

    static func list(cwds: [(String, String)]) -> [Worktree] {
        var out: [Worktree] = []
        for repo in repos() {
            let r = Sh.git(["worktree", "list", "--porcelain"], in: repo)
            var cur: [String: String] = [:]
            var first = true
            for line in (r.out + "\n\n").split(separator: "\n", omittingEmptySubsequences: false) {
                if line.isEmpty {
                    if let p = cur["worktree"] {
                        var w = Worktree(path: p, repo: (repo as NSString).lastPathComponent, repoPath: repo,
                                         branch: cur["branch"].map { $0.replacingOccurrences(of: "refs/heads/", with: "") } ?? (cur["detached"] != nil ? "(detached)" : ""),
                                         head: String((cur["HEAD"] ?? "").prefix(9)), exists: FileManager.default.fileExists(atPath: p),
                                         isMain: first, locked: cur["locked"] != nil, prunable: cur["prunable"] != nil)
                        w.session = p.firstMatch(uuidRe)
                        w.lastActivity = activity(w)
                        w.usedBy = cwds.filter { $0.1 == p || $0.1.hasPrefix(p + "/") }.map { $0.0 }
                        out.append(w)
                        first = false
                    }
                    cur = [:]
                    continue
                }
                let kv = line.split(separator: " ", maxSplits: 1)
                cur[String(kv[0])] = kv.count > 1 ? String(kv[1]) : ""
            }
        }
        return out
    }

    /// Newest of HEAD's reflog and the files git reports as changed. Not the index mtime:
    /// any `git status` refreshes that.
    static func activity(_ w: Worktree) -> Date? {
        guard w.exists else { return nil }
        var gitdir = w.path + "/.git"
        if let link = try? String(contentsOfFile: gitdir, encoding: .utf8), link.hasPrefix("gitdir: ") {
            gitdir = link.dropFirst(8).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let fm = FileManager.default
        return [gitdir + "/logs/HEAD", gitdir + "/HEAD"].compactMap { (try? fm.attributesOfItem(atPath: $0))?[.modificationDate] as? Date }.max()
    }

    static func check(_ w: Worktree, sessionWorking: Bool) -> SafetyCheck {
        var reasons: [String] = []
        if w.isMain { return SafetyCheck(safe: false, force: false, reasons: ["This is the repository's main checkout."]) }
        if w.locked { reasons.append("The worktree is locked.") }
        if !w.exists { return SafetyCheck(safe: reasons.isEmpty, force: false, reasons: reasons + ["Folder is already gone; only the stale entry is pruned."]) }
        if !w.usedBy.isEmpty { reasons.append("Open in: " + w.usedBy.joined(separator: ", ")) }
        if sessionWorking { reasons.append("Its agent session is working right now.") }
        let st = Sh.git(["status", "--porcelain", "--untracked-files=normal"], in: w.path).out.split(separator: "\n")
        let tracked = st.filter { !$0.hasPrefix("??") }
        if !tracked.isEmpty { reasons.append("\(tracked.count) uncommitted change(s), e.g. \(tracked.first!.dropFirst(3))") }
        let untracked = st.filter { $0.hasPrefix("??") }.map { String($0.dropFirst(3)) }
        let real = untracked.filter { u in !setupFiles.contains { u.hasPrefix($0) } }
        if !real.isEmpty { reasons.append("\(real.count) untracked file(s), e.g. \(real.first!)") }
        var lone = Set(Sh.git(["rev-list", "HEAD", "--not", "--remotes"], in: w.path).out.split(separator: "\n").map(String.init))
        if !lone.isEmpty {
            let remotes = Set(Sh.git(["branch", "-r", "--format=%(refname:short)"], in: w.path).out.split(separator: "\n").map(String.init))
            // The remote's default branch first, then the usual integration branches.
            let head = Sh.git(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: w.path).out.trimmingCharacters(in: .whitespacesAndNewlines)
            for up in [head, "origin/main", "origin/master", "origin/develop", "origin/development"] where !up.isEmpty && remotes.contains(up) && !lone.isEmpty {
                let plus = Sh.git(["cherry", up, "HEAD"], in: w.path).out.split(separator: "\n").filter { $0.hasPrefix("+ ") }.map { String($0.dropFirst(2)) }
                lone.formIntersection(plus)
            }
            if !lone.isEmpty { reasons.append("\(lone.count) commit(s) exist only here (not on any remote by content).") }
        }
        return SafetyCheck(safe: reasons.isEmpty, force: !untracked.isEmpty, reasons: reasons)
    }

    static func remove(_ w: Worktree, force: Bool) -> String {
        if !w.exists {
            _ = Sh.git(["worktree", "prune"], in: w.repoPath)
            return "Pruned the stale entry for \(w.path)."
        }
        let r = Sh.git(["worktree", "remove"] + (force ? ["--force"] : []) + [w.path], in: w.repoPath, timeout: 120)
        _ = Sh.git(["worktree", "prune"], in: w.repoPath)
        return r.code == 0 ? "Removed \(w.path)." : "git refused: \(r.err.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))"
    }

    /// At most three du at a time, each at macOS background priority (throttled CPU and disk I/O),
    /// so measuring sizes never competes with real work.
    private static let duSlots = DispatchSemaphore(value: 3)
    static func sizeKB(_ path: String) -> Int64? {
        duSlots.wait(); defer { duSlots.signal() }
        let r = Sh.run("/usr/sbin/taskpolicy", ["-b", "/usr/bin/du", "-sk", path], timeout: 600)
        return r.out.split(separator: "\t").first.flatMap { Int64($0) }
    }
}
