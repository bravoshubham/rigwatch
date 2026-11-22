import CryptoKit
import Foundation

/// What a new worktree would otherwise install or build from nothing: node_modules, CocoaPods' Pods and
/// Xcode's reusable caches. Each is shared between worktrees by APFS clone (seconds, no extra disk), keyed by
/// the lockfile it was installed from, so a worktree only gets a copy that matches its own lockfile; the
/// install that follows then only checks. Sources: RigWatch's own store, filled after every successful
/// install, or a sibling worktree of the same repository that already has it installed.
enum DepCache {
    static let dir = Rules.dir + "/deps"

    enum Kind: String { case node, pods
        var folder: String { self == .node ? "node_modules" : "Pods" }
    }
    /// A folder of a repository that holds one kind of dependency: the repo root for node_modules, the root
    /// or ios/ (React Native) for Pods.
    struct Spot { let kind: Kind; let rel: String }   // rel: "" or "ios"

    static let nodeLocks = ["package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lock", "bun.lockb"]
    /// Files npm, yarn and pnpm write once an install has finished.
    static let nodeMarkers = ["node_modules/.package-lock.json", "node_modules/.yarn-integrity", "node_modules/.yarn-state.yml", "node_modules/.modules.yaml"]

    static func spots(_ root: String) -> [Spot] {
        let fm = FileManager.default
        var out: [Spot] = []
        if fm.fileExists(atPath: root + "/package.json") { out.append(Spot(kind: .node, rel: "")) }
        for rel in ["", "ios"] where fm.fileExists(atPath: path(root, rel) + "/Podfile.lock") { out.append(Spot(kind: .pods, rel: rel)) }
        return out
    }

    static func path(_ root: String, _ rel: String) -> String { rel.isEmpty ? root : root + "/" + rel }

    /// The lockfile (and patch-package patches) an install comes from; nil when there is nothing to key it on.
    static func key(_ s: Spot, _ root: String) -> String? {
        let base = path(root, s.rel), fm = FileManager.default
        var h = SHA256()
        switch s.kind {
        case .node:
            let lock = nodeLocks.lazy.compactMap { fm.contents(atPath: base + "/" + $0) }.first ?? fm.contents(atPath: base + "/package.json")
            guard let lock else { return nil }
            h.update(data: lock)
            let patches = base + "/patches"
            for rel in ((fm.enumerator(atPath: patches)?.allObjects as? [String]) ?? []).sorted() {
                if let d = fm.contents(atPath: patches + "/" + rel) { h.update(data: Data(rel.utf8)); h.update(data: d) }
            }
        case .pods:
            guard let lock = fm.contents(atPath: base + "/Podfile.lock") else { return nil }
            h.update(data: lock)
        }
        return s.kind.rawValue + "-" + h.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Installed and finished: an install marker for node_modules, a Manifest.lock equal to Podfile.lock for Pods.
    static func installed(_ s: Spot, _ root: String) -> Bool {
        let base = path(root, s.rel), fm = FileManager.default
        switch s.kind {
        // A marker alone isn't enough: an install stopped part way can leave one behind.
        case .node: return nodeMarkers.contains { fm.fileExists(atPath: base + "/" + $0) } && nodeProblems(base).isEmpty
        case .pods:
            guard let a = fm.contents(atPath: base + "/Pods/Manifest.lock"), let b = fm.contents(atPath: base + "/Podfile.lock") else { return false }
            return a == b
        }
    }

    /// Only into a folder git ignores there: a copy must never show up as a change in someone's worktree.
    static func ignored(_ s: Spot, _ root: String) -> Bool {
        // The trailing slash asks about a folder, so a "node_modules/" pattern matches before the folder exists.
        Sh.git(["check-ignore", "-q", (s.rel.isEmpty ? "" : s.rel + "/") + s.kind.folder + "/"], in: root).code == 0
    }

    /// The other worktrees of the same repository.
    static func siblings(_ root: String) -> [String] {
        Sh.git(["worktree", "list", "--porcelain"], in: root).out.split(separator: "\n")
            .compactMap { $0.hasPrefix("worktree ") ? String($0.dropFirst(9)) : nil }
            .filter { $0 != root && FileManager.default.fileExists(atPath: $0) }
    }

    @discardableResult
    static func clone(_ src: String, _ dst: String) -> Bool {
        let fm = FileManager.default, tmp = dst + ".rigwatch-tmp"
        try? fm.removeItem(atPath: tmp)
        try? fm.createDirectory(atPath: (dst as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard Sh.run("/bin/cp", ["-cR", src, tmp], timeout: 1800).code == 0, (try? fm.moveItem(atPath: tmp, toPath: dst)) != nil else {
            try? fm.removeItem(atPath: tmp); return false
        }
        return true
    }

    /// Gives a worktree what it is missing, from the store or a sibling with the same lockfile. Notes for the agent.
    static func prepare(_ root: String) -> [String] {
        let fm = FileManager.default
        var notes: [String] = []
        for s in spots(root) {
            let dst = path(root, s.rel) + "/" + s.kind.folder
            guard !fm.fileExists(atPath: dst), let k = key(s, root), ignored(s, root) else { continue }
            let stored = dir + "/" + k + "/" + s.kind.folder
            let source: String?
            if Rules.isDir(stored) { source = stored }
            else { source = siblings(root).first { key(s, $0) == k && installed(s, $0) }.map { path($0, s.rel) + "/" + s.kind.folder } }
            guard let source else { continue }
            let t0 = Date()
            guard clone(source, dst) else { notes.append("could not copy \(s.kind.folder) into \(Views.tilde(path(root, s.rel)))"); continue }
            let from = source.hasPrefix(dir) ? "RigWatch's store" : Views.tilde((source as NSString).deletingLastPathComponent)
            if s.kind == .node, let bad = nodeProblems(path(root, s.rel)).first {
                // Incomplete where it came from: worse than none, since the install would trust it.
                try? fm.removeItem(atPath: dst)
                if source.hasPrefix(dir) { try? fm.removeItem(atPath: dir + "/" + k) }
                notes.append("the node_modules copied from \(from) was incomplete, so it was removed again: \(bad)")
                Rules.log("deps: removed an incomplete node_modules \(k) from \(from)")
                continue
            }
            notes.append("copied \(s.kind.folder) for this lockfile from \(from) in \(Int(Date().timeIntervalSince(t0))) s (APFS clone); the install now only checks it")
            Rules.log("deps: \(s.kind.folder) \(k) into \(Views.tilde(path(root, s.rel))) from \(from)")
            touch(k)
            if !source.hasPrefix(dir) { store(source, k, s) }
        }
        return notes
    }

    /// Keeps a worktree's finished installs in the store, for the next worktree with the same lockfile.
    @discardableResult
    static func seed(_ root: String, apply: Bool = true) -> [String] {
        var kept: [String] = []
        for s in spots(root) where installed(s, root) && ignored(s, root) {
            guard let k = key(s, root) else { continue }
            if Rules.isDir(dir + "/" + k + "/" + s.kind.folder) { touch(k); kept.append(k); continue }
            guard apply else { kept.append(k); continue }
            if store(path(root, s.rel) + "/" + s.kind.folder, k, s) { kept.append(k) }
        }
        return kept
    }

    @discardableResult
    private static func store(_ src: String, _ k: String, _ s: Spot) -> Bool {
        let dst = dir + "/" + k + "/" + s.kind.folder
        guard !Rules.isDir(dst), clone(src, dst) else { return Rules.isDir(dst) }
        Rules.log("deps: stored \(s.kind.folder) \(k) from \(Views.tilde((src as NSString).deletingLastPathComponent))")
        prune(s.kind)
        return true
    }

    private static func touch(_ k: String) { try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: dir + "/" + k) }

    /// The newest three lockfiles of each kind; older ones are dropped (clones: what a worktree still uses stays on disk there).
    static func prune(_ kind: Kind) {
        let fm = FileManager.default
        let entries = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix(kind.rawValue + "-") }.map { dir + "/" + $0 }
            .sorted { (Rules.mtime($0) ?? .distantPast) > (Rules.mtime($1) ?? .distantPast) }
        for e in entries.dropFirst(3) { try? fm.removeItem(atPath: e); Rules.log("deps: dropped \((e as NSString).lastPathComponent)") }
    }

    // MARK: checks

    /// What is wrong with a worktree's dependencies, after fixing what can be: Pods that name another worktree of the
    /// repository (as Pods cloned from it do) are pointed at this one, and git-ignored xcconfigs the project includes
    /// are copied from the main checkout. Each problem says what to run.
    static func check(_ root: String, apply: Bool = true) -> (fixed: [String], problems: [String]) {
        var fixed: [String] = [], problems: [String] = []
        let fm = FileManager.default
        for s in spots(root) {
            let base = path(root, s.rel)
            guard fm.fileExists(atPath: base + "/" + s.kind.folder) else { continue }
            switch s.kind {
            case .node: problems += nodeProblems(base)
            case .pods:
                let named = repointPods(root, s.rel, apply: apply)
                if !named.isEmpty { fixed.append("pointed \(Views.tilde(base))/Pods at this worktree: it named \(named.sorted().map(Views.tilde).joined(separator: ", "))") }
                if fm.fileExists(atPath: root + "/node_modules/react-native/package.json"),
                   !["build/generated/ios", "ios/build/generated/ios"].contains(where: { fm.fileExists(atPath: root + "/" + $0) }) {
                    problems.append("React Native's iOS codegen output (build/generated/ios) is missing in \(Views.tilde(root)): run pod install in \(Views.tilde(base)), which runs codegen")
                }
            }
        }
        let (copied, missing) = includedConfigs(root, apply: apply)
        return (fixed + copied, problems + missing)
    }

    /// `check`, only when a lockfile, an install or the Pods project changed since the last check of this worktree.
    static func checkIfChanged(_ root: String) -> (fixed: [String], problems: [String]) {
        let stamps = dir + "/checked"
        try? FileManager.default.createDirectory(atPath: stamps, withIntermediateDirectories: true)
        let stamp = stamps + "/" + Insecure.MD5.hash(data: Data(root.utf8)).map { String(format: "%02x", $0) }.joined()
        let last = Rules.mtime(stamp) ?? .distantPast
        let watched = spots(root).flatMap { s -> [String] in
            let b = path(root, s.rel)
            return (s.kind == .node ? ["package.json", "node_modules"] + nodeLocks + nodeMarkers : ["Podfile.lock", "Pods/Pods.xcodeproj/project.pbxproj"]).map { b + "/" + $0 }
        }
        guard watched.contains(where: { (Rules.mtime($0) ?? .distantPast) > last }) else { return ([], []) }
        let r = check(root)
        Rules.write(Data(), to: stamp)
        return r
    }

    /// Direct dependencies (package.json) missing from node_modules, or installed at a version the lockfile doesn't have.
    static func nodeProblems(_ base: String) -> [String] {
        let fm = FileManager.default
        guard let d = fm.contents(atPath: base + "/package.json"), let pj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return [] }
        let names = Set(["dependencies", "devDependencies"].flatMap { ((pj[$0] as? [String: Any]) ?? [:]).keys })
        let locked = lockedVersions(base)
        var missing: [String] = [], wrong: [String] = []
        for n in names.sorted() {
            guard let v = fm.contents(atPath: base + "/node_modules/\(n)/package.json")
                .flatMap({ (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] })?["version"] as? String else { missing.append(n); continue }
            if let want = locked[n], !want.isEmpty, !want.contains(v) { wrong.append("\(n) \(v), lockfile \(want.sorted().joined(separator: " or "))") }
        }
        var out: [String] = []
        if !missing.isEmpty {
            out.append("node_modules in \(Views.tilde(base)) lacks \(missing.count) of the \(names.count) packages package.json names (\(missing.prefix(5).joined(separator: ", "))\(missing.count > 5 ? ", …" : "")): run the install")
        }
        if !wrong.isEmpty { out.append("node_modules in \(Views.tilde(base)) doesn't match the lockfile: \(wrong.prefix(5).joined(separator: "; "))\(wrong.count > 5 ? "; …" : ""): run the install") }
        return out
    }

    /// The versions the lockfile resolves each package to (package-lock.json, or yarn.lock of yarn 1 or yarn 2+).
    static func lockedVersions(_ base: String) -> [String: Set<String>] {
        let fm = FileManager.default
        var out: [String: Set<String>] = [:]
        if let d = fm.contents(atPath: base + "/package-lock.json"), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
           let pk = j["packages"] as? [String: Any] {
            for (k, v) in pk where k.hasPrefix("node_modules/") && !k.dropFirst(13).contains("/node_modules/") {
                if let ver = (v as? [String: Any])?["version"] as? String { out[String(k.dropFirst(13)), default: []].insert(ver) }
            }
            return out
        }
        guard let y = try? String(contentsOfFile: base + "/yarn.lock", encoding: .utf8) else { return out }
        var names: [String] = []
        for line in y.split(separator: "\n", omittingEmptySubsequences: false) {
            if !line.hasPrefix(" "), !line.hasPrefix("#"), line.hasSuffix(":") {
                // "a@npm:^1, a@npm:^2": or a@^1, "@s/b@^2":
                names = line.dropLast().split(separator: ",").compactMap { d in
                    let t = d.trimmingCharacters(in: CharacterSet(charactersIn: " \""))
                    guard let at = t.dropFirst().firstIndex(of: "@") else { return nil }
                    return String(t[..<at])
                }
            } else if line.hasPrefix("  version"), !names.isEmpty {
                let v = line.dropFirst(9).trimmingCharacters(in: CharacterSet(charactersIn: ": \""))
                for n in names { out[n, default: []].insert(v) }
                names = []
            }
        }
        return out
    }

    /// An absolute path up to a node_modules or Pods folder: the worktree it belongs to.
    static let foreignRoot = try! NSRegularExpression(pattern: #"(/[^\s"'\\;=]+?)/(?:node_modules|Pods)/"#)

    /// Points the Pods project, xcconfigs, file lists and local podspecs at this worktree where they name another
    /// worktree of the same repository (a sibling, or one since removed beside it). The worktrees they named.
    static func repointPods(_ root: String, _ rel: String, apply: Bool = true) -> [String] {
        let fm = FileManager.default, pods = path(root, rel) + "/Pods"
        let parent = (root as NSString).deletingLastPathComponent, sibs = Set(siblings(root))
        var texts: [(String, String)] = [], named = Set<String>()
        for sub in ["Pods.xcodeproj", "Target Support Files", "Local Podspecs"] {
            let d = pods + "/" + sub
            for f in (fm.enumerator(atPath: d)?.allObjects as? [String]) ?? [] where ["xcconfig", "pbxproj", "xcfilelist", "sh", "json"].contains((f as NSString).pathExtension) {
                guard let data = fm.contents(atPath: d + "/" + f), let t = String(data: data, encoding: .utf8) else { continue }
                var hit = false
                for m in foreignRoot.matches(in: t, range: NSRange(t.startIndex..., in: t)) {
                    guard let r = Range(m.range(at: 1), in: t) else { continue }
                    var c = String(t[r])
                    if !rel.isEmpty, c.hasSuffix("/" + rel) { c = String(c.dropLast(rel.count + 1)) }
                    guard c != root, sibs.contains(c) || ((c as NSString).deletingLastPathComponent == parent && !fm.fileExists(atPath: c)) else { continue }
                    named.insert(c); hit = true
                }
                if hit { texts.append((d + "/" + f, t)) }
            }
        }
        guard !named.isEmpty, apply else { return Array(named) }
        for (f, t) in texts {
            var u = t
            for c in named {
                let rx = try! NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: c) + #"(?=[/"'\s;:,)\]]|$)"#)
                u = rx.stringByReplacingMatches(in: u, range: NSRange(u.startIndex..., in: u), withTemplate: NSRegularExpression.escapedTemplate(for: root))
            }
            if u != t { try? u.write(toFile: f, atomically: true, encoding: .utf8) }
        }
        Rules.log("deps: pointed \(texts.count) Pods file(s) in \(Views.tilde(path(root, rel))) at it; they named \(named.sorted().map(Views.tilde).joined(separator: ", "))")
        return Array(named)
    }

    static let includeLine = try! NSRegularExpression(pattern: #"^\s*#include\??\s+"([^"]+)""#, options: .anchorsMatchLines)

    /// xcconfigs the project's xcconfigs #include that git ignores (secrets, local settings) and the worktree lacks:
    /// copied from the main checkout when it has them, else reported.
    static func includedConfigs(_ root: String, apply: Bool = true) -> (copied: [String], missing: [String]) {
        let fm = FileManager.default, skip: Set = ["node_modules", "Pods", ".git", "build", "DerivedData"]
        let derived = Set(Offload.derivedDirs(root))
        var configs: [String] = [], level = [""]
        for _ in 0..<4 {
            var next: [String] = []
            for rel in level {
                for n in (try? fm.contentsOfDirectory(atPath: root + "/" + rel)) ?? [] where !skip.contains(n) {
                    let r = rel.isEmpty ? n : rel + "/" + n
                    if n.hasSuffix(".xcconfig") { configs.append(r) }
                    else if Rules.isDir(root + "/" + r), !derived.contains(r), !n.hasPrefix(".") { next.append(r) }
                }
            }
            level = next
        }
        let main = Sh.git(["worktree", "list", "--porcelain"], in: root).out.split(separator: "\n").first.map { String($0.dropFirst(9)) }
        var copied: [String] = [], missing: [String] = []
        for c in configs {
            guard let t = try? String(contentsOfFile: root + "/" + c, encoding: .utf8) else { continue }
            for m in includeLine.matches(in: t, range: NSRange(t.startIndex..., in: t)) {
                guard let r = Range(m.range(at: 1), in: t) else { continue }
                let inc = String(t[r]), optional = t[Range(m.range, in: t)!].contains("#include?")
                guard !inc.hasPrefix("/"), !inc.contains("Pods/") else { continue }
                let rel = URL(fileURLWithPath: ((c as NSString).deletingLastPathComponent as NSString).appendingPathComponent(inc), relativeTo: URL(fileURLWithPath: "/")).standardizedFileURL.path.dropFirst()
                guard !fm.fileExists(atPath: root + "/" + rel), !optional || fm.fileExists(atPath: (main ?? "") + "/" + rel) else { continue }
                let note = "\(rel) (included by \(c))"
                if let main, main != root, fm.fileExists(atPath: main + "/" + rel), Sh.git(["check-ignore", "-q", String(rel)], in: root).code == 0, !apply || clone(main + "/" + rel, root + "/" + rel) {
                    copied.append("copied \(note) from the main checkout \(Views.tilde(main)): git ignores it")
                    Rules.log("deps: copied \(rel) into \(Views.tilde(root)) from \(Views.tilde(main))")
                } else if !missing.contains(where: { $0.hasPrefix(String(rel)) }) {
                    missing.append("\(note) is missing in \(Views.tilde(root)) and the main checkout has none to copy: the app target won't build without it")
                }
            }
        }
        return (copied, missing)
    }

    // MARK: Xcode

    /// Parts of a DerivedData folder that don't depend on where the worktree is: resolved Swift packages, clang's
    /// module cache and Xcode's content-addressed compilation cache.
    static let xcodeShared = ["SourcePackages", "ModuleCache.noindex", "CompilationCache.noindex"]
    static let derivedArg = try! NSRegularExpression(pattern: #"-derivedDataPath\s+(?:"([^"]+)"|'([^']+)'|([^\s;&|]+))"#)

    /// For an xcodebuild with -derivedDataPath inside its worktree: copies the shared parts from the same folder
    /// of a sibling worktree, so the first build there doesn't resolve packages and rebuild modules from nothing.
    static func prepareDerivedData(cmd: String, cwd: String) -> [String] {
        guard let m = derivedArg.firstMatch(in: cmd, range: NSRange(cmd.startIndex..., in: cmd)),
              let r = (1...3).lazy.compactMap({ Range(m.range(at: $0), in: cmd) }).first else { return [] }
        let arg = (String(cmd[r]) as NSString).expandingTildeInPath
        let cd = Rules.matches(try! NSRegularExpression(pattern: #"\bcd\s+("[^"]+"|'[^']+'|[^\s;&|]+)"#), cmd, group: 1).last
            .map { ($0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) as NSString).expandingTildeInPath }
        let base = cd.map { $0.hasPrefix("/") ? $0 : cwd + "/" + $0 } ?? cwd
        let dd = URL(fileURLWithPath: arg.hasPrefix("/") ? arg : base + "/" + arg).standardizedFileURL.path
        guard let root = Rules.roots(cmd, cwd: cwd).first(where: { dd.hasPrefix($0 + "/") }) else { return [] }
        let rel = String(dd.dropFirst(root.count + 1))
        let fm = FileManager.default
        let missing = xcodeShared.filter { !fm.fileExists(atPath: dd + "/" + $0) }
        guard !missing.isEmpty else { return [] }
        // The sibling built most recently has the freshest caches.
        let donors = siblings(root).map { $0 + "/" + rel }.filter { d in xcodeShared.contains { fm.fileExists(atPath: d + "/" + $0) } }
            .sorted { (Rules.mtime($0) ?? .distantPast) > (Rules.mtime($1) ?? .distantPast) }
        guard let donor = donors.first else { return [] }
        let t0 = Date()
        let copied = missing.filter { fm.fileExists(atPath: donor + "/" + $0) && clone(donor + "/" + $0, dd + "/" + $0) }
        guard !copied.isEmpty else { return [] }
        Rules.log("deps: \(copied.joined(separator: ", ")) into \(Views.tilde(dd)) from \(Views.tilde(donor))")
        return ["copied Xcode's \(copied.joined(separator: ", ")) from \(Views.tilde(donor)) in \(Int(Date().timeIntervalSince(t0))) s (APFS clone), so this build reuses its packages and compiled modules"]
    }
}
