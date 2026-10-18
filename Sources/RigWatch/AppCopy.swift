import AppKit

/// Homebrew builds RigWatch inside its own folder, where Spotlight and Launchpad never look, and
/// Spotlight skips a symlinked app. So a Homebrew install keeps a real copy in ~/Applications:
/// launched from Homebrew (the `rigwatch` command), RigWatch installs or refreshes that copy and
/// reopens from it; launched from the copy, it refreshes itself once `brew upgrade` has built a newer
/// version. The copy is made on this Mac, so it carries no quarantine flag.
enum AppCopy {
    /// RIGWATCH_APP_COPY moves the copy elsewhere (used to test this without touching ~/Applications).
    static let copy = ProcessInfo.processInfo.environment["RIGWATCH_APP_COPY"] ?? Sh.home + "/Applications/RigWatch.app"
    static let brewBuilds = ["/opt/homebrew/opt/rigwatch/RigWatch.app", "/usr/local/opt/rigwatch/RigWatch.app"]

    /// Called first thing at launch. Hands over to the copy and exits when this process should not run.
    static func sync() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("-snap") { return }
        let fm = FileManager.default
        let me = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let copyPath = URL(fileURLWithPath: copy).resolvingSymlinksInPath().path

        if me.contains("/Cellar/rigwatch/") {
            // Running from Homebrew: make sure the copy exists, is a real app and is not older.
            let isLink = (try? fm.destinationOfSymbolicLink(atPath: copy)) != nil
            if isLink || !fm.fileExists(atPath: copy) || build(copy) < build(me) {
                guard install(from: me) else { return }   // could not copy: just run from Homebrew
            }
            handOver(args)
        } else if me == copyPath, let brew = brewBuilds.first(where: { fm.fileExists(atPath: $0) }), build(brew) > build(me) {
            // Running from the copy, and `brew upgrade` has built a newer RigWatch: refresh and restart.
            if install(from: brew) { handOver(args) }
        }
    }

    /// CFBundleVersion of an app bundle, 0 when unreadable.
    static func build(_ app: String) -> Int {
        let plist = NSDictionary(contentsOfFile: app + "/Contents/Info.plist")
        return Int(plist?["CFBundleVersion"] as? String ?? "") ?? 0
    }

    /// Copies the app next to the copy first and swaps it in, so a failed copy never leaves a half app.
    private static func install(from src: String) -> Bool {
        let fm = FileManager.default
        let dir = (copy as NSString).deletingLastPathComponent
        let fresh = dir + "/.RigWatch-new.app", old = dir + "/.RigWatch-old.app"
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? fm.removeItem(atPath: fresh); try? fm.removeItem(atPath: old)
        guard Sh.run("/usr/bin/ditto", [src, fresh], timeout: 60).code == 0 else { try? fm.removeItem(atPath: fresh); return false }
        if (try? fm.attributesOfItem(atPath: copy)) != nil {   // also true for a broken symlink
            guard (try? fm.moveItem(atPath: copy, toPath: old)) != nil else { try? fm.removeItem(atPath: fresh); return false }
        }
        guard (try? fm.moveItem(atPath: fresh, toPath: copy)) != nil else { try? fm.moveItem(atPath: old, toPath: copy); return false }
        try? fm.removeItem(atPath: old)
        return true
    }

    /// Opens the copy (a new instance, passing our arguments on) and ends this process.
    private static func handOver(_ args: [String]) -> Never {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.rigwatch.RigWatch")
            .contains { $0.processIdentifier != getpid() && $0.bundleURL?.resolvingSymlinksInPath().path == URL(fileURLWithPath: copy).resolvingSymlinksInPath().path }
        _ = Sh.run("/usr/bin/open", (running ? [] : ["-n"]) + [copy] + (args.isEmpty || running ? [] : ["--args"] + args), timeout: 15)
        exit(0)
    }
}
