import Foundation

/// One builder per repository, many writers: a repository may name an integrator worktree. Builds there go first in
/// the queue; a build in another worktree of the same repository is warned (or refused) and pointed at it. Entries
/// are keyed by the repository's folder name (its main checkout) and name the integrator's worktree; they go stale
/// after 12 hours. RigWatch's own list (`RigWatch integrator claim`) and, when the Rules name one, a team's file in
/// the same shape are both read.
enum Integrators {
    struct Entry: Codable { var worktree: String; var session: String?; var since: String? }

    static let file = Rules.dir + "/integrators.json"
    static let stale: TimeInterval = 12 * 3600

    /// Live entries by repository name, the team file first so RigWatch's own claims win.
    static func all() -> [String: Entry] {
        var out: [String: Entry] = [:]
        let team = RuleSettings.load().integratorsFile.trimmingCharacters(in: .whitespaces)
        for path in [team.isEmpty ? nil : (team as NSString).expandingTildeInPath, file].compactMap({ $0 }) {
            guard let d = FileManager.default.contents(atPath: path), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
            for (repo, v) in j {
                guard let e = v as? [String: Any], let wt = e["worktree"] as? String else { continue }
                let since = e["since"] as? String
                if let s = since.flatMap(date), Date().timeIntervalSince(s) > stale { continue }
                out[repo] = Entry(worktree: (wt as NSString).expandingTildeInPath, session: e["session"] as? String, since: since)
            }
        }
        return out
    }

    static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        return f.date(from: s) ?? { f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.date(from: s) }()
    }

    /// The repository a checkout belongs to: the folder name of its main checkout.
    static func repo(of root: String) -> String? {
        Sh.git(["worktree", "list", "--porcelain"], in: root).out.split(separator: "\n").first
            .map { (String($0.dropFirst(9)) as NSString).lastPathComponent }
    }

    /// The integrator for a checkout's repository, when that checkout is not the integrator's own.
    static func other(for root: String) -> (repo: String, entry: Entry)? {
        let live = all()
        guard !live.isEmpty, let r = repo(of: root), let e = live[r] else { return nil }
        return inside(root, e.worktree) ? nil : (r, e)
    }

    /// True when a directory is inside a live integrator worktree (its builds go first).
    static func isIntegrator(_ dir: String, _ live: [String: Entry]) -> Bool {
        live.values.contains { inside(dir, $0.worktree) }
    }

    /// Compared with symlinks resolved on both sides (/tmp and /private/tmp are one folder).
    static func inside(_ dir: String, _ worktree: String) -> Bool {
        let d = URL(fileURLWithPath: dir).resolvingSymlinksInPath().path, wt = URL(fileURLWithPath: worktree).resolvingSymlinksInPath().path
        return d == wt || d.hasPrefix(wt + "/")
    }

    /// What the hook says to a build in a writer's worktree.
    static func message(_ r: (repo: String, entry: Entry), refuse: Bool) -> String {
        "\(r.repo) has an integrator: \(Views.tilde(r.entry.worktree))\(r.entry.session.map { " (session \($0))" } ?? "")\(r.entry.since.map { " since \($0)" } ?? ""). "
            + "One builder per repository: commit on your branch and ask the integrator to merge, build and install it, instead of building here."
            + (refuse ? "" : " This build goes ahead, behind the integrator's builds.")
    }

    /// `RigWatch integrator claim [PATH] | release [PATH] | list`
    static func main(_ a: [String]) -> Int32 {
        let path = a.dropFirst().first.map { ($0 as NSString).expandingTildeInPath } ?? FileManager.default.currentDirectoryPath
        switch a.first {
        case "list":
            let live = all()
            if live.isEmpty { print("no integrators") }
            for (r, e) in live.sorted(by: { $0.key < $1.key }) { print("\(r): \(Views.tilde(e.worktree))\(e.session.map { "  session \($0)" } ?? "")\(e.since.map { "  since \($0)" } ?? "")") }
            return 0
        case "claim", "release":
            guard let root = Rules.roots("", cwd: path).first, let r = repo(of: root) else { Rules.say("\(path) is not inside a git checkout"); return 1 }
            var j = (FileManager.default.contents(atPath: file).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
            if a.first == "claim" {
                j[r] = ["worktree": root, "session": ProcessInfo.processInfo.environment["CLAUDE_CODE_SESSION_ID"] ?? "", "since": ISO8601DateFormatter().string(from: Date())]
                print("\(r): integrator is now \(Views.tilde(root)) for 12 hours (claim again to renew)")
            } else {
                j[r] = nil
                print("\(r): no integrator in RigWatch's list" + (all()[r].map { " (the team file still names \(Views.tilde($0.worktree)))" } ?? ""))
            }
            Rules.write(try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys]), to: file)
            Rules.log("integrator: \(a.first!) \(r) \(Views.tilde(root))")
            return 0
        default:
            Rules.say("usage: RigWatch integrator claim [PATH] | release [PATH] | list"); return 2
        }
    }
}
