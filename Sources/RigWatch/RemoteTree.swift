import CryptoKit
import Foundation

/// Sends a worktree to another Mac the way git would, instead of copying the whole folder:
/// - Its committed history goes once per repository into a bare mirror there; each copy is a git worktree of it,
///   checked out at a snapshot commit of this worktree (HEAD plus uncommitted and untracked changes), so a build
///   sends only the objects that Mac doesn't have yet.
/// - node_modules and Pods go once per lockfile into a store there, and each copy gets an APFS clone of them.
/// - Git-ignored files the build needs (.xcode.env.local, local configs, React Native's iOS codegen) go by rsync.
/// - Build output never goes: DerivedData, build folders, archives, apps, results, files over 100 MB.
enum RemoteTree {
    /// Folders of build output, by name, anywhere in the tree.
    static let outputDirs = ["build", "DerivedData", ".gradle", ".cxx", ".kotlin", ".externalNativeBuild", ".rigwatch-dd", ".rigwatch-out", ".dd"]
    static let outputSuffixes = [".xcarchive", ".xcresult", ".dSYM", ".app", ".appex", ".ipa", ".apk", ".aab"]
    static let maxFile: Int64 = 100 << 20

    /// Why this worktree goes by a plain copy instead, or nil when it can go by git.
    static func unsupported(_ root: String) -> String? {
        let fm = FileManager.default
        let top = Sh.git(["rev-parse", "--show-toplevel"], in: root).out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !top.isEmpty, top == root || top == URL(fileURLWithPath: root).resolvingSymlinksInPath().path else { return "not the top of a git checkout" }
        if fm.fileExists(atPath: root + "/.gitmodules") { return "it has git submodules" }
        if let a = fm.contents(atPath: root + "/.gitattributes"), String(decoding: a, as: UTF8.self).contains("filter=lfs") { return "it uses Git LFS" }
        return nil
    }

    static func hash(_ s: String, _ n: Int = 3) -> String { Insecure.MD5.hash(data: Data(s.utf8)).prefix(n).map { String(format: "%02x", $0) }.joined() }

    /// Where this Mac's copies live there, relative to that Mac's home.
    static var base: String { (Offload.copyDir("/x") as NSString).deletingLastPathComponent }

    /// The repository's mirror there: one per repository (its common git folder), whatever the worktree.
    static func mirror(_ root: String) -> String? {
        let common = Sh.git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: root).out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !common.isEmpty else { return nil }
        let main = (common as NSString).lastPathComponent == ".git" ? (common as NSString).deletingLastPathComponent : common
        let name = (main as NSString).lastPathComponent.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
        return base + "/.mirrors/\(name)-\(hash(common)).git"
    }

    // MARK: what goes

    /// gitignore-style patterns for build output, plus folders of this worktree to leave alone (anchored).
    static func excludes(_ root: String, keep: [String]) -> [String] {
        outputDirs.map { $0 + "/" } + outputSuffixes.map { "*" + $0 } + Set(keep + Offload.derivedDirs(root)).map { "/" + $0 + "/" }
    }

    /// A commit of the worktree as it is now: HEAD plus every change, tracked or untracked (not ignored), except
    /// build output and files over 100 MB. Made in a copy of the index, so the worktree's own index is untouched,
    /// and with fixed dates, so an unchanged worktree gives the same commit and the push has nothing to send.
    static func snapshot(_ root: String, excludes: [String]) -> (sha: String?, skipped: [String], err: String) {
        let fm = FileManager.default
        let index = Sh.git(["rev-parse", "--path-format=absolute", "--git-path", "index"], in: root).out.trimmingCharacters(in: .whitespacesAndNewlines)
        let tmp = Rules.dir + "/snapshot-\(getpid())-\(hash(root))"
        defer { try? fm.removeItem(atPath: tmp + ".index"); try? fm.removeItem(atPath: tmp + ".list") }
        try? fm.removeItem(atPath: tmp + ".index")
        if fm.fileExists(atPath: index) { try? fm.copyItem(atPath: index, toPath: tmp + ".index") }
        let env = ["GIT_INDEX_FILE": tmp + ".index", "GIT_AUTHOR_NAME": "RigWatch", "GIT_AUTHOR_EMAIL": "rigwatch@localhost",
                   "GIT_COMMITTER_NAME": "RigWatch", "GIT_COMMITTER_EMAIL": "rigwatch@localhost",
                   "GIT_AUTHOR_DATE": "@1 +0000", "GIT_COMMITTER_DATE": "@1 +0000", "GIT_OPTIONAL_LOCKS": "0"]
        func git(_ a: [String], _ t: Double = 600) -> Sh.Result { Sh.run("/usr/bin/git", ["-C", root] + a, env: env, timeout: t) }
        var r = git(["add", "-u"])
        guard r.code == 0 else { return (nil, [], "git add -u: " + r.err) }
        r = git(["ls-files", "-o", "--exclude-standard", "-z"] + excludes.flatMap { ["-x", $0] })
        guard r.code == 0 else { return (nil, [], "git ls-files: " + r.err) }
        var add: [String] = [], skipped: [String] = []
        for p in r.out.split(separator: "\0").map(String.init) {
            if p.hasSuffix("/") { skipped.append(p + " (a git checkout of its own)"); continue }
            let size = ((try? fm.attributesOfItem(atPath: root + "/" + p))?[.size] as? NSNumber)?.int64Value ?? 0
            if size > maxFile { skipped.append("\(p) (\(Fmt.bytes(UInt64(size))))"); continue }
            add.append(p)
        }
        if !add.isEmpty {
            fm.createFile(atPath: tmp + ".list", contents: Data(add.joined(separator: "\0").utf8))
            r = git(["add", "--pathspec-from-file=" + tmp + ".list", "--pathspec-file-nul"])
            guard r.code == 0 else { return (nil, skipped, "git add: " + r.err) }
        }
        r = git(["write-tree"])
        guard r.code == 0 else { return (nil, skipped, "git write-tree: " + r.err) }
        let tree = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = git(["rev-parse", "-q", "--verify", "HEAD^{commit}"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
        r = git(["commit-tree", tree, "-m", "RigWatch snapshot"] + (head.isEmpty ? [] : ["-p", head]))
        guard r.code == 0 else { return (nil, skipped, "git commit-tree: " + r.err) }
        return (r.out.trimmingCharacters(in: .whitespacesAndNewlines), skipped, "")
    }

    struct Dep { let kind: DepCache.Kind; let rel: String; let key: String; let src: String
        var folder: String { rel.isEmpty ? kind.folder : rel + "/" + kind.folder }
    }

    /// Git-ignored things the build needs: paths to send as they are, and node_modules and Pods to share by lockfile.
    static func ignored(_ root: String, excludes: [String]) -> (paths: [String], deps: [Dep]) {
        let r = Sh.git(["ls-files", "-o", "-i", "--exclude-standard", "--directory", "-z"], in: root, timeout: 300)
        let anchored = excludes.filter { $0.hasPrefix("/") }.map { String($0.dropFirst().dropLast()) }
        var paths: [String] = [], deps: [Dep] = []
        for e in r.out.split(separator: "\0").map(String.init) {
            let dir = e.hasSuffix("/"), p = dir ? String(e.dropLast()) : e, name = (p as NSString).lastPathComponent
            let parent = (p as NSString).deletingLastPathComponent
            if name == ".git" || name == Offload.usedStamp { continue }
            if anchored.contains(where: { p == $0 || p.hasPrefix($0 + "/") }) { continue }
            if outputSuffixes.contains(where: name.hasSuffix) { continue }
            if outputDirs.contains(name) {
                // React Native's iOS codegen writes headers the Pods project compiles into build/generated/ios.
                if name == "build", Rules.isDir(root + "/" + p + "/generated/ios") { paths.append(p + "/generated/ios/") }
                continue
            }
            if dir, name == "node_modules" || name == "Pods" {
                let s = DepCache.Spot(kind: name == "Pods" ? .pods : .node, rel: parent)
                if let k = DepCache.key(s, root), DepCache.installed(s, root) { deps.append(Dep(kind: s.kind, rel: parent, key: k, src: root + "/" + p)); continue }
            }
            paths.append(e)
        }
        return (paths, deps)
    }

    // MARK: sending

    /// ssh options for a copy's steps: one connection for all of them (the setup, the push, the rsyncs), which
    /// stays two minutes for the next build, instead of a handshake each.
    /// The socket lives in a short folder of this user's own: a socket path may not be longer than 104 bytes, and
    /// one under a long home folder name (or ~/.ssh) is. Without that folder, each step connects on its own.
    static let sshOpts: [String] = {
        let dir = "/tmp/rigwatch-\(getuid())"
        mkdir(dir, 0o700)
        var st = stat()
        guard lstat(dir, &st) == 0, st.st_uid == getuid(), (st.st_mode & S_IFMT) == S_IFDIR, st.st_mode & 0o077 == 0 else { return Peers.sshOpts }
        return Peers.sshOpts + ["-o", "ControlMaster=auto", "-o", "ControlPath=\(dir)/%C", "-o", "ControlPersist=120"]
    }()
    static var sshCommand: String { (["/usr/bin/ssh"] + sshOpts).joined(separator: " ") }

    static func ssh(_ host: String, _ script: String, timeout: Double) -> Sh.Result {
        Sh.run("/usr/bin/ssh", sshOpts + [host, "/bin/sh -c " + Rules.quote(script)], timeout: timeout)
    }

    /// Sends a worktree to `dest` there (see the type). `rsync` runs a copy with progress (Offload's).
    static func send(_ root: String, to host: String, dest: String, keep: [String],
                     rsync: ([String]) -> Sh.Result) -> Sh.Result {
        func fail(_ m: String) -> Sh.Result { Sh.Result(code: 1, data: Data(), err: m) }
        guard let mirror = mirror(root) else { return fail("no git folder in \(Views.tilde(root))") }
        let ex = excludes(root, keep: keep)
        let snap = snapshot(root, excludes: ex)
        guard let sha = snap.sha else { return fail("could not take a snapshot of the worktree: \(snap.err.prefix(200))") }
        if !snap.skipped.isEmpty { Rules.log("offload: not sent to \(host): \(snap.skipped.prefix(5).joined(separator: ", "))\(snap.skipped.count > 5 ? " and \(snap.skipped.count - 5) more" : "")") }
        let (paths, deps) = ignored(root, excludes: ex)
        let q = Rules.quote, branch = "refs/heads/" + (dest as NSString).lastPathComponent

        // 1. Folders, the mirror, the used stamp; which dependency sets it lacks. A clean-up runs there in the background.
        var s = "cd \"$HOME\" || exit 1; mkdir -p \(q(dest)) \(q(base))/.deps || exit 1; touch \(q(dest))/\(Offload.usedStamp); "
        s += "[ -d \(q(mirror)) ] || { git init -q --bare \(q(mirror)) && git --git-dir=\(q(mirror)) config receive.shallowUpdate true; } || exit 1; "
        s += "grep -qx /.rigwatch-out/ \(q(mirror))/info/exclude 2>/dev/null || { mkdir -p \(q(mirror))/info && printf '/%s\\n' \(Offload.usedStamp) .rigwatch-dd/ .rigwatch-out/ >> \(q(mirror))/info/exclude; }; "
        for d in deps { s += "[ -f \(q(base))/.deps/\(d.key)/.complete ] || echo missing \(d.key); " }
        s += "nohup /bin/sh -c \(q(Peers.remote(["trim"]))) </dev/null >/dev/null 2>&1 & true"
        var r = ssh(host, s, timeout: 60)
        guard r.code == 0 else { return fail("could not get \(host) ready: \(r.err.prefix(200))") }
        let missing = Set(r.out.split(separator: "\n").compactMap { $0.hasPrefix("missing ") ? String($0.dropFirst(8)) : nil })

        // 2. The snapshot and whatever history it needs that the mirror doesn't have.
        r = Sh.run("/usr/bin/git", ["-C", root, "-c", "pack.threads=4", "push", "-q", "--force", "--no-verify", host + ":" + mirror, sha + ":" + branch],
                   env: ["GIT_SSH_COMMAND": sshCommand], timeout: 3600, started: { Offload.copyPid = $0 })
        Offload.copyPid = 0
        guard r.code == 0 else { return fail("git push to \(host) failed: \(r.err.prefix(300))") }

        // 3. Each dependency set it lacks, once per lockfile.
        for d in deps where missing.contains(d.key) {
            let store = base + "/.deps/" + d.key
            // React Native packages' Android build output (android/build, .cxx: often most of node_modules) never goes:
            // Gradle rebuilds it there, and a build here rewriting it mid-copy would break the copy.
            let c = rsync(["--exclude", "**/android/build/", "--exclude", "**/android/.cxx/", "--exclude", "**/.cxx/",
                           "--rsync-path", "mkdir -p \(q(store)) && rsync", d.src + "/", host + ":" + store + "/" + d.kind.folder + ".part/"])
            guard c.code == 0 || c.code == 24 else { return fail("could not send \(d.folder) to \(host): \(c.err.prefix(200))") }
            r = ssh(host, "cd \"$HOME\" && cd \(q(store)) && rm -rf \(d.kind.folder) && mv \(d.kind.folder).part \(d.kind.folder) && printf %s \(q(root)) > root && touch .complete", timeout: 300)
            guard r.code == 0 else { return fail("could not store \(d.folder) on \(host): \(r.err.prefix(200))") }
            Rules.log("offload: sent \(d.kind.folder) \(d.key) to \(host) (once for this lockfile)")
        }

        // 4. The copy: a worktree of the mirror at the snapshot. A folder from an older RigWatch's whole-tree copy
        // becomes one in place, keeping its build output. Then each dependency set is cloned in from the store.
        s = "cd \"$HOME\" || exit 1; M=\(q(mirror)); D=\(q(dest)); m=$(cd \"$M\" && pwd -P); "
        s += "c=$(cd \"$D\" && cd \"$(git rev-parse --git-common-dir 2>/dev/null)\" 2>/dev/null && pwd -P); "
        s += "if [ \"$c\" != \"$m\" ] || [ ! -f \"$D/.git\" ]; then rm -rf \"$D/.git\" \"$D.rwtmp\"; git --git-dir=\"$M\" worktree prune; "
        s += "git --git-dir=\"$M\" worktree add -q --no-checkout --detach \"$D.rwtmp\" \(sha) || exit 4; mv \"$D.rwtmp/.git\" \"$D/.git\" && rmdir \"$D.rwtmp\" || exit 4; "
        s += "(cd \"$D\" && git worktree repair >/dev/null 2>&1 && git reset -q) || exit 4; fi; "
        s += "cd \"$D\" && git checkout -q -f --detach \(sha) || exit 5; "
        s += "git clean -fdq" + (ex + ["/" + Offload.usedStamp, "node_modules/", "Pods/"]).map { " -e " + q($0) }.joined() + " || exit 5; "
        for d in deps {
            let store = "\"$HOME\"/\(q(base))/.deps/\(d.key)"
            s += "T=\(q(d.folder)); if [ \"$(cat \"$T/.rigwatch-key\" 2>/dev/null)\" != \(d.key) ]; then rm -rf \"$T\" \"$T.rwtmp\"; mkdir -p \"$(dirname \"$T\")\"; "
            s += "cp -cR \(store)/\(d.kind.folder) \"$T.rwtmp\" && mv \"$T.rwtmp\" \"$T\" && echo \(d.key) > \"$T/.rigwatch-key\" || exit 6; "
            if d.kind == .pods {
                // The store's Pods name the worktree they were sent from: point them at this copy.
                s += "f=$(cat \(store)/root); [ -n \"$f\" ] && LC_ALL=C grep -rlF --null \"$f\" \"$T\" --include='*.xcconfig' --include='*.pbxproj' --include='*.xcfilelist' --include='*.sh' "
                    + "| xargs -0 sed -i '' \"s#$f#$HOME/$D#g\"; "
            }
            s += "fi; touch \(store); "
        }
        s += "true"
        r = ssh(host, s, timeout: 1800)
        guard r.code == 0 else { return fail("could not check out the snapshot on \(host) (exit \(r.code)): \(r.err.prefix(300))") }

        // 5. Ignored files the build needs.
        if !paths.isEmpty {
            let list = Rules.dir + "/send-\(getpid())-\(hash(root)).list"
            FileManager.default.createFile(atPath: list, contents: Data(paths.joined(separator: "\n").utf8))
            defer { try? FileManager.default.removeItem(atPath: list) }
            var a = ["-r", "--files-from=" + list, "--max-size=100m"]
            for x in outputDirs where x != "build" { a += ["--exclude", x + "/"] }
            for x in outputSuffixes { a += ["--exclude", "*" + x] }
            let c = rsync(a + [root + "/", host + ":" + dest + "/"])
            guard c.code == 0 || c.code == 24 else { return c }
        }
        return Sh.Result(code: 0, data: Data(), err: "")
    }
}
