import Foundation

/// How far a Gradle or xcodebuild run has got, read from its output: the task (or build step) it is on, how many
/// it has done, and how many the last successful run of the same tasks did, which makes "done / total" an estimate
/// (the task graph changes with the code, and a first run has nothing to compare with).
struct BuildProgress: Codable, Equatable {
    var task: String?
    var done = 0
    var total: Int?
    var finished = false   // the tool said BUILD SUCCESSFUL / ** BUILD SUCCEEDED **

    static let gradleTask = try! NSRegularExpression(pattern: #"^> Task (:\S+)"#)
    static let xcodeStep = try! NSRegularExpression(pattern: #"^(?:SwiftCompile|CompileSwift|CompileC|Ld|CompileAssetCatalog|CompileStoryboard|CompileXIB|ProcessInfoPlistFile|CodeSign|PhaseScriptExecution|SwiftEmitModule|CopySwiftLibs|ProcessProductPackaging) (?:\S+ )*?(\S+)$"#)
    static let success = try! NSRegularExpression(pattern: #"^(?:BUILD SUCCESSFUL|\*\* (?:BUILD|TEST) SUCCEEDED \*\*)"#)

    /// One line of output. True when it changed anything.
    mutating func read(_ line: String) -> Bool {
        let s = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = NSRange(s.startIndex..., in: s)
        if let m = Self.gradleTask.firstMatch(in: s, range: r) ?? Self.xcodeStep.firstMatch(in: s, range: r), let t = Range(m.range(at: 1), in: s) {
            task = Self.xcodeStep.firstMatch(in: s, range: r) != nil ? (String(s[t]) as NSString).lastPathComponent : String(s[t])
            done += 1
            return true
        }
        if Self.success.firstMatch(in: s, range: r) != nil { finished = true; return true }
        return false
    }

    /// "412 / ~1085 tasks", "412 tasks" without an earlier run.
    var count: String? {
        guard done > 0 else { return nil }
        return total.map { "\(min(done, $0)) / ~\($0)" } ?? "\(done) tasks"
    }
    var fraction: Double? { total.map { Double(min(done, $0)) / Double(max(1, $0)) } }

    // MARK: totals of earlier runs

    static let totalsFile = Rules.dir + "/progress-totals.json"

    /// What a run does, without where: the Gradle tasks it names, or the Xcode scheme and action.
    static func key(_ args: [String]) -> String? {
        // The wrapper's main class, else gradlew or gradle itself (not -Dorg.gradle.appname=gradlew).
        if let i = args.firstIndex(where: { $0.hasSuffix("GradleWrapperMain") })
            ?? args.firstIndex(where: { !$0.hasPrefix("-") && ($0.hasSuffix("/gradlew") || $0 == "gradlew" || $0.hasSuffix("/gradle") || $0 == "gradle") }) {
            let tasks = args[(i + 1)...].filter { !$0.hasPrefix("-") && !$0.contains("=") }
            return tasks.isEmpty ? nil : "gradle " + tasks.joined(separator: " ")
        }
        if let i = args.firstIndex(where: { $0.hasSuffix("xcodebuild") }) {
            let rest = Array(args[(i + 1)...])
            guard let s = rest.firstIndex(of: "-scheme"), s + 1 < rest.count else { return nil }
            let action = rest.contains("test") ? " test" : rest.contains("build-for-testing") ? " build-for-testing" : ""
            return "xcodebuild " + rest[s + 1] + action
        }
        return nil
    }
    /// The same, from a shell command line (only its first Gradle or xcodebuild run).
    static func key(_ cmd: String) -> String? {
        guard let r = cmd.range(of: #"(?:\S*/)?(?:gradlew?|xcodebuild)\s[^;&|<>]*"#, options: .regularExpression) else { return nil }
        return key(cmd[r].split(separator: " ").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) })
    }

    static func total(_ key: String?) -> Int? {
        guard let key, let d = FileManager.default.contents(atPath: totalsFile), let all = try? JSONDecoder().decode([String: Int].self, from: d) else { return nil }
        return all[key]
    }
    static func saveTotal(_ key: String?, _ n: Int) {
        guard let key, n > 0 else { return }
        var all = (FileManager.default.contents(atPath: totalsFile).flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) }) ?? [:]
        guard all[key] != n else { return }
        all[key] = n
        if all.count > 200 { all = Dictionary(uniqueKeysWithValues: all.prefix(200).map { ($0.key, $0.value) }) }
        Rules.write(try? JSONEncoder().encode(all), to: totalsFile)
    }

    // MARK: builds here, from the file their output goes to

    /// Progress of a build here whose Gradle or xcodebuild writes into a file (`> build.log`): output into a pipe
    /// (`| tail`) or the agent's terminal can't be read back. Read incrementally, one cursor per file.
    final class Reader {
        private struct Cursor { var offset: UInt64; var rest = Data(); var progress: BuildProgress; var size: UInt64 }
        private var cursors: [String: Cursor] = [:]
        private var jobs: [Int32: (path: String, key: String)] = [:]

        /// For a running job: the first process in its tree whose stdout is a regular file and whose argv names a run.
        func progress(job: Int32, procs: [Proc]) -> BuildProgress? {
            var kids: [Int32: [Proc]] = [:]
            for p in procs { kids[p.ppid, default: []].append(p) }
            var stack = kids[job] ?? []
            while let p = stack.popLast() {
                stack += kids[p.pid] ?? []
                guard let key = BuildProgress.key(p.args), let path = Self.stdoutFile(p.pid) else { continue }
                jobs[job] = (path, key)
                return read(path, key: key)
            }
            return nil
        }

        /// Builds that have left the queue: the rest of their output is read once more, so a successful run's
        /// task count is kept as the next run's total even when it ended between two looks.
        func settle(running: Set<Int32>) {
            for (pid, j) in jobs where !running.contains(pid) {
                _ = read(j.path, key: j.key)
                cursors[j.path] = nil; jobs[pid] = nil
            }
        }

        private func read(_ path: String, key: String) -> BuildProgress? {
            guard let h = FileHandle(forReadingAtPath: path) else { return nil }
            defer { try? h.close() }
            let size = (try? h.seekToEnd()) ?? 0
            var c = cursors[path] ?? Cursor(offset: 0, progress: BuildProgress(total: BuildProgress.total(key)), size: 0)
            if size < c.offset { c = Cursor(offset: 0, progress: BuildProgress(total: BuildProgress.total(key)), size: 0) }   // rewritten
            if size > c.offset {
                try? h.seek(toOffset: c.offset)
                let d = c.rest + ((try? h.read(upToCount: Int(min(size - c.offset, 32 << 20)))) ?? Data())
                c.offset += UInt64(d.count - c.rest.count)
                var start = d.startIndex
                while let nl = d[start...].firstIndex(of: 0x0A) { _ = c.progress.read(String(decoding: d[start..<nl], as: UTF8.self)); start = d.index(after: nl) }
                c.rest = Data(d[start...])
                if c.progress.finished { BuildProgress.saveTotal(key, c.progress.done) }
            }
            c.size = size
            cursors[path] = c
            return c.progress
        }

        /// The file a process's stdout goes to, when it is a regular file other than /dev/null.
        static func stdoutFile(_ pid: Int32) -> String? {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, 1, PROC_PIDFDVNODEPATHINFO, &info, size) == size,
                  info.pvip.vip_vi.vi_type == Int32(VREG.rawValue) else { return nil }
            let path = withUnsafeBytes(of: info.pvip.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            return path.isEmpty || path == "/dev/null" ? nil : path
        }
    }
}
