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
        case .node: return nodeMarkers.contains { fm.fileExists(atPath: base + "/" + $0) }
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
