import Foundation

/// Runs a command-line tool with a timeout and returns its output. Used for adb, simctl, git, ps and du.
enum Sh {
    static let home = NSHomeDirectory()
    static let adb: String = {
        let p = home + "/Library/Android/sdk/platform-tools/adb"
        return FileManager.default.isExecutableFile(atPath: p) ? p : "/opt/homebrew/bin/adb"
    }()
    static let env: [String: String] = {
        var e = ProcessInfo.processInfo.environment
        e["PATH"] = "\(home)/Library/Android/sdk/platform-tools:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        // xcode-select points at the Command Line Tools here, which have no simctl.
        e["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
        e["GIT_OPTIONAL_LOCKS"] = "0" // never take index.lock or touch index mtimes in other sessions' worktrees
        return e
    }()

    struct Result { let code: Int32; let data: Data; let err: String
        var out: String { String(decoding: data, as: UTF8.self) } }

    static func run(_ exe: String, _ args: [String], cwd: String? = nil, env extra: [String: String] = [:], timeout: Double = 15) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe.hasPrefix("/") ? exe : "/usr/bin/env")
        p.arguments = exe.hasPrefix("/") ? args : [exe] + args
        p.environment = env.merging(extra) { _, new in new }
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let o = Pipe(), e = Pipe()
        p.standardOutput = o; p.standardError = e; p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return Result(code: -1, data: Data(), err: "\(error)") }
        var out = Data(), err = Data()
        let g = DispatchGroup()
        g.enter(); DispatchQueue.global(qos: .utility).async { out = o.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        g.enter(); DispatchQueue.global(qos: .utility).async { err = e.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        g.wait(); p.waitUntilExit(); killer.cancel()
        return Result(code: p.terminationStatus, data: out, err: String(decoding: err, as: UTF8.self))
    }

    static func git(_ args: [String], in dir: String, timeout: Double = 20) -> Result {
        run("/usr/bin/git", ["-C", dir] + args, timeout: timeout)
    }
}
