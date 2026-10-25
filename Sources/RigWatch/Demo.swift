import Foundation

/// `RigWatch.app/Contents/MacOS/RigWatch -demo`: every screen filled with made-up but plausible
/// data, for screenshots and trying the app without touching anything real. Nothing is sampled,
/// scanned or signalled while it is on.
enum Demo {
    static let on = CommandLine.arguments.contains("-demo")

    private static let gb: UInt64 = 1 << 30, mb: UInt64 = 1 << 20
    private static let now = Date()
    private static func ago(_ s: TimeInterval) -> Date { now.addingTimeInterval(-s) }
    private static func wob(_ base: Double, _ tick: Int, _ seed: Int, _ amp: Double = 0.18) -> Double {
        max(0, base * (1 + amp * sin(Double(tick) * 0.9 + Double(seed) * 1.7)))
    }

    // MARK: sessions

    private struct S { let agent: Agent; let id, title, prompt, project, host: String; let age: TimeInterval; let live: Bool; let cpu: Double; let mem: UInt64; let procs: Int }
    private static let sessionSeed: [S] = [
        S(agent: .claude, id: "5f1c2a9e-1b7d-4c55-9a0e-3d2b7e6f8a11", title: "Checkout flow: fix double charge on retry", prompt: "Retry the payment step on a flaky network and confirm only one charge goes through.", project: "acme-shop-android", host: "Desktop", age: 12, live: true, cpu: 22, mem: 1_210 * mb, procs: 14),
        S(agent: .opencode, id: "ses_8a3e0c4d6f21Kb9a8e770c1d", title: "Migrate settings screen to Compose", prompt: "Port SettingsFragment to Compose and keep every preference key.", project: "acme-shop-android", host: "CLI", age: 40, live: true, cpu: 9.5, mem: 860 * mb, procs: 11),
        S(agent: .codex, id: "019a2f3c-7d41-7e20-9b55-c2d3e4f5a6b7", title: "iOS widget for order status", prompt: "Add a lock-screen widget that shows the latest order's delivery window.", project: "acme-shop-ios", host: "CLI", age: 75, live: true, cpu: 6.1, mem: 2_400 * mb, procs: 16),
        S(agent: .claude, id: "1e2d3c4b-5a69-4788-9a6b-5c4d3e2f1a0b", title: "Flaky snapshot tests on CI", prompt: "Find why the dark-mode snapshots differ by one pixel on CI only.", project: "acme-design-system", host: "CLI", age: 640, live: true, cpu: 1.2, mem: 410 * mb, procs: 5),
        S(agent: .claude, id: "9b8a7c6d-5e4f-4a3b-2c1d-0e9f8a7b6c5d", title: "API client: retry with backoff", prompt: "Wrap the generated client so 429s back off and respect Retry-After.", project: "acme-api", host: "CLI", age: 3_900, live: true, cpu: 0.4, mem: 290 * mb, procs: 4),
        S(agent: .claude, id: "2c3d4e5f-6a7b-4c8d-9e0f-1a2b3c4d5e6f", title: "Release notes for 4.12", prompt: "Draft release notes from the merged PRs since the last tag.", project: "acme-shop-android", host: "Desktop", age: 86_400 * 2, live: true, cpu: 0.2, mem: 180 * mb, procs: 4),
        S(agent: .claude, id: "3d4e5f6a-7b8c-4d9e-0f1a-2b3c4d5e6f7a", title: "Accessibility pass on onboarding", prompt: "Check every onboarding control has a label and a 48 dp target.", project: "acme-shop-ios", host: "gone", age: 86_400 * 4, live: false, cpu: 0, mem: 0, procs: 0),
    ]

    static func sessions(_ tick: Int) -> [Session] {
        sessionSeed.enumerated().map { i, s in
            var x = Session(id: s.id, title: s.title, lastPrompt: s.prompt, project: s.project, transcriptAge: s.age,
                            live: s.live, host: s.host, hostId: s.host == "Desktop" ? "local_demo\(i)" : nil)
            x.agent = s.agent
            x.procCount = s.procs; x.cpu = s.live ? wob(s.cpu, tick, i) : 0; x.mem = s.mem
            if i == 0 { x.devices = ["Pixel_8_API_35"]; x.worktrees = 2 }
            if i == 2 { x.devices = ["iPhone 16 Pro"]; x.worktrees = 1 }
            if i == 1 { x.worktrees = 1 }
            return x
        } + [cursor(tick)]
    }

    /// A Basic agent: known only from its processes.
    private static func cursor(_ tick: Int) -> Session {
        var x = Session(id: "pid:20412", title: "Cursor · acme-api", lastPrompt: "", project: "~/code/acme-api", transcriptAge: 0, live: true, host: "App")
        x.agent = .cursor; x.cwd = Sh.home + "/code/acme-api"; x.procCount = 17; x.cpu = wob(14, tick, 41); x.mem = 2_900 * mb
        return x
    }

    // MARK: dev servers

    static func servers(_ tick: Int) -> [DevServer] {
        func d(_ pid: Int32, _ ppid: Int32, _ name: String, _ kind: String, _ ports: [Int], _ dir: String, _ up: TimeInterval, _ cpu: Double, _ mem: UInt64,
               session: String? = nil, title: String? = nil, parent: String? = nil) -> DevServer {
            var x = DevServer(pid: pid, start: UInt64(pid), ppid: ppid, name: name, kind: kind, ports: ports)
            x.cwd = "/Users/demo/code/" + dir; x.started = ago(up); x.cpu = wob(cpu, tick, Int(pid)); x.mem = mem
            x.session = session; x.sessionTitle = title; x.parent = parent
            return x
        }
        return [
            d(20_611, 20_604, "node", "Vite", [5173], "acme-web", 2 * 3600, 3.2, 310 * mb, session: sessionSeed[0].id, title: sessionSeed[0].title),
            d(20_633, 20_630, "python3.12", "uvicorn", [8000], "acme-api", 3_900, 0.8, 120 * mb, session: sessionSeed[4].id, title: sessionSeed[4].title),
            // Its session ended hours ago; the server was left running and launchd adopted it.
            d(20_655, 1, "next-server", "Next.js", [3000], "acme-site", 86_400 + 4 * 3600, 0.4, 540 * mb,
              session: "7a6b5c4d-3e2f-4a1b-9c8d-7e6f5a4b3c2d", title: "Pricing page: annual toggle"),
            d(20_677, 20_670, "node", "Storybook", [6006], "acme-design-system", 5 * 3600, 0.6, 410 * mb, parent: "zsh (20670)"),
        ]
    }

    // MARK: processes

    private struct P { let group, name, path: String; let n: Int; let cpu: Double; let mem: UInt64; let root: Bool }
    private static let procSeed: [P] = [
        P(group: "Android emulators", name: "qemu-system-aarch64", path: "/Users/demo/Library/Android/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64", n: 1, cpu: 118, mem: 6_100 * mb, root: false),
        P(group: "Android Studio", name: "studio", path: "/Applications/Android Studio.app/Contents/MacOS/studio", n: 9, cpu: 34, mem: 5_300 * mb, root: false),
        P(group: "Gradle", name: "java", path: "/Library/Java/JavaVirtualMachines/jdk-21/Contents/Home/bin/java", n: 2, cpu: 61, mem: 4_700 * mb, root: false),
        P(group: "Kotlin daemon", name: "java", path: "/Library/Java/JavaVirtualMachines/jdk-21/Contents/Home/bin/java", n: 1, cpu: 12, mem: 2_100 * mb, root: false),
        P(group: "Xcode / Swift", name: "Xcode", path: "/Applications/Xcode.app/Contents/MacOS/Xcode", n: 7, cpu: 18, mem: 3_900 * mb, root: false),
        // A Swift build an agent session started: the CPU spike the banner and the timeline name.
        P(group: "Xcode / Swift", name: "swift-frontend", path: "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend", n: 14, cpu: 1_000, mem: 3_600 * mb, root: false),
        P(group: "Local models", name: "ollama", path: "/Applications/Ollama.app/Contents/Resources/ollama", n: 2, cpu: 0.6, mem: 9_400 * mb, root: false),
        P(group: "iOS simulators", name: "launchd_sim", path: "/Library/Developer/CoreSimulator/Volumes/iOS_22A/launchd_sim", n: 46, cpu: 21, mem: 2_800 * mb, root: false),
        P(group: "Claude Code sessions", name: "claude", path: "/usr/local/bin/claude", n: 4, cpu: 8, mem: 2_300 * mb, root: false),
        P(group: "OpenCode", name: "opencode", path: "/opt/homebrew/bin/opencode", n: 3, cpu: 4, mem: 640 * mb, root: false),
        P(group: "Codex", name: "codex", path: "/opt/homebrew/bin/codex", n: 2, cpu: 3, mem: 380 * mb, root: false),
        P(group: "Cursor", name: "Cursor Helper", path: "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper", n: 17, cpu: 14, mem: 2_900 * mb, root: false),
        P(group: "Google Chrome", name: "Google Chrome Helper", path: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper", n: 31, cpu: 14, mem: 4_200 * mb, root: false),
        P(group: "Slack", name: "Slack Helper", path: "/Applications/Slack.app/Contents/Frameworks/Slack Helper", n: 6, cpu: 3, mem: 1_100 * mb, root: false),
        P(group: "Figma", name: "Figma Helper", path: "/Applications/Figma.app/Contents/Frameworks/Figma Helper", n: 8, cpu: 4, mem: 2_600 * mb, root: false),
        P(group: "Docker", name: "com.docker.backend", path: "/Applications/Docker.app/Contents/MacOS/com.docker.backend", n: 5, cpu: 9, mem: 3_200 * mb, root: false),
        P(group: "Node", name: "node", path: "/opt/homebrew/bin/node", n: 12, cpu: 7, mem: 1_700 * mb, root: false),
        P(group: "Visual Studio Code", name: "Code Helper", path: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper", n: 10, cpu: 5, mem: 1_900 * mb, root: false),
        P(group: "Spotify", name: "Spotify", path: "/Applications/Spotify.app/Contents/MacOS/Spotify", n: 4, cpu: 2, mem: 520 * mb, root: false),
        P(group: "macOS services", name: "mds_stores", path: "/System/Library/Frameworks/CoreServices.framework/Support/mds_stores", n: 290, cpu: 26, mem: 9_800 * mb, root: false),
        P(group: "System (root)", name: "kernel_task", path: "kernel_task", n: 130, cpu: 31, mem: 4_400 * mb, root: true),
        P(group: "WindowServer", name: "WindowServer", path: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer", n: 1, cpu: 17, mem: 1_300 * mb, root: false),
        P(group: "Safari", name: "Safari", path: "/Applications/Safari.app/Contents/MacOS/Safari", n: 9, cpu: 1.5, mem: 900 * mb, root: false),
        P(group: "Postgres", name: "postgres", path: "/opt/homebrew/opt/postgresql@16/bin/postgres", n: 8, cpu: 0.6, mem: 340 * mb, root: false),
        P(group: "Notion", name: "Notion Helper", path: "/Applications/Notion.app/Contents/Frameworks/Notion Helper", n: 5, cpu: 0.9, mem: 760 * mb, root: false),
        P(group: "zoom.us", name: "zoom.us", path: "/Applications/zoom.us.app/Contents/MacOS/zoom.us", n: 3, cpu: 0.4, mem: 310 * mb, root: false),
        P(group: "Raycast", name: "Raycast", path: "/Applications/Raycast.app/Contents/MacOS/Raycast", n: 1, cpu: 0.3, mem: 240 * mb, root: false),
    ]

    static func procs(_ tick: Int) -> [Proc] {
        var out: [Proc] = []
        var pid: Int32 = 20_000
        let me = getuid()
        for (gi, g) in procSeed.enumerated() {
            for k in 0..<g.n {
                pid += 7
                let share = k == 0 ? 0.55 : 0.45 / Double(max(1, g.n - 1))
                let memShare = k == 0 ? 0.5 : 0.5 / Double(max(1, g.n - 1))
                let name = k == 0 ? g.name : (g.n > 20 ? "\(g.name.split(separator: " ").first ?? "") \(["helper", "agent", "worker", "daemon"][k % 4])" : g.name)
                var p = Proc(pid: pid, ppid: 1, uid: g.root ? 0 : me, path: g.path, name: name,
                             cpu: wob(g.cpu * (g.n == 1 ? 1 : share), tick, gi * 31 + k), mem: UInt64(Double(g.mem) * (g.n == 1 ? 1 : memShare)),
                             diskRead: 0, diskWrite: 0, group: g.group, session: nil, hostSession: nil, args: [])
                if g.group == "Gradle" || g.group == "Android emulators" { p.diskWrite = wob(2_400_000, tick, gi + k, 0.6); p.diskRead = wob(900_000, tick, gi + k + 3, 0.6) }
                if g.group == "Xcode / Swift" && k == 0 { p.diskRead = wob(1_200_000, tick, 5, 0.5) }
                if k == 0, let gpu = ["WindowServer": 9.0, "Local models": 22, "Android emulators": 6, "Google Chrome": 3.2, "Figma": 1.8][g.group] { p.gpu = wob(gpu, tick, gi) }
                if g.name == "swift-frontend" { p.session = sessionSeed[2].id; p.mem = UInt64(Double(g.mem) / Double(g.n)); p.cpu = wob(g.cpu / Double(g.n), tick, gi * 31 + k, 0.08) }
                if g.group == "Claude Code sessions", let c = [0, 3, 4, 5].dropFirst(0).enumerated().first(where: { $0.offset == k })?.element { p.session = sessionSeed[c].id }
                out.append(p)
            }
        }
        out.append(Proc(pid: getpid(), ppid: 1, uid: me, path: Bundle.main.executablePath ?? "RigWatch", name: "RigWatch",
                        cpu: wob(0.6, tick, 99), mem: 140 * mb, diskRead: 0, diskWrite: 0, group: "RigWatch", session: nil, hostSession: nil, args: []))
        return out
    }

    static func groups(_ ps: [Proc]) -> [ProcGroup] {
        var g: [String: ProcGroup] = [:]
        for p in ps {
            var x = g[p.group] ?? ProcGroup(name: p.group, count: 0, cpu: 0, mem: 0, disk: 0, killable: [])
            x.count += 1; x.cpu += p.cpu; x.mem += p.mem; x.disk += p.diskRead + p.diskWrite
            g[p.group] = x
        }
        return Array(g.values)
    }

    // MARK: machine

    static func sys(_ tick: Int, procs: [Proc], real: SysSnapshot) -> SysSnapshot {
        var s = SysSnapshot()
        let cores = max(real.cores.count, ProcessInfo.processInfo.activeProcessorCount)
        let busy = procs.reduce(0) { $0 + $1.cpu }
        s.cpu = min(95, busy / Double(cores))
        s.cores = (0..<cores).map { i in min(100, wob(i < cores / 3 ? 12 : 38, tick, i, 0.7)) }
        s.load = (busy / 100 * 0.9, busy / 100, busy / 100 * 1.1)
        s.memTotal = 64 * gb
        let app = procs.filter { $0.uid != 0 }.reduce(UInt64(0)) { $0 + $1.mem }
        s.memApp = min(app, s.memTotal / 2)
        s.memWired = 12 * gb; s.memCompressed = 2 * gb + 300 * mb
        s.memCached = s.memTotal / 6; s.memPurgeable = 1 * gb + 200 * mb
        s.memFree = s.memTotal - min(s.memTotal, s.memUsed + s.memCached)
        s.pressure = 1
        s.swapUsed = 0; s.swapTotal = 2 * gb
        s.gpu = Int(wob(24, tick, 7, 0.5)); s.gpuMem = 9_800 * mb; s.gpuModel = real.gpuModel.isEmpty ? "Apple M4 Max" : real.gpuModel   // GPU memory: mostly the local model's weights
        s.diskRead = wob(3_800_000, tick, 11, 0.6); s.diskWrite = wob(6_200_000, tick, 13, 0.6)
        s.netIn = wob(1_900_000, tick, 17, 0.7); s.netOut = wob(320_000, tick, 19, 0.7)
        s.volumes = [Volume(name: "Macintosh HD", path: "/", total: 1_000_000_000_000, free: 212_000_000_000)]
        s.thermal = .nominal
        s.tempMax = wob(51, tick, 23, 0.04); s.tempAvg = wob(44, tick, 29, 0.03)
        s.uptime = 3 * 86_400 + 5 * 3600
        return s
    }

    // MARK: devices

    static func devices(_ tick: Int) -> [Device] {
        var a = Device(id: "emulator-5554", kind: .emulator, name: "Pixel_8_API_35", detail: "sdk_gphone64_arm64", state: "device", pid: 20_007)
        a.cpu = wob(118, tick, 1); a.mem = 6_100 * mb; a.started = ago(3 * 3600)
        a.launchedBy = sessionSeed[0].id; a.foreground = "com.acme.shop/com.acme.shop.CheckoutActivity"; a.screen = "Awake"; a.guestLoad = "1.84 1.62 1.40"
        a.recentUsers = [sessionSeed[0].id: ago(30), sessionSeed[1].id: ago(1_800)]
        a.lastAction = (sessionSeed[0].id, "adb -s emulator-5554 shell am start -n com.acme.shop/.CheckoutActivity", ago(30))
        var b = Device(id: "B1A2C3D4-E5F6-4789-A0B1-C2D3E4F5A6B7", kind: .simulator, name: "iPhone 16 Pro", detail: "iOS 18.2", state: "Booted", pid: 21_000)
        b.cpu = wob(21, tick, 2); b.mem = 2_800 * mb; b.started = ago(5_400)
        b.launchedBy = sessionSeed[2].id; b.foreground = "AcmeShop, OrderWidgetExtension"
        b.recentUsers = [sessionSeed[2].id: ago(90)]
        b.lastAction = (sessionSeed[2].id, "xcrun simctl launch booted com.acme.shop", ago(90))
        // Left running from yesterday; nothing has used it since.
        var t = Device(id: "emulator-5556", kind: .emulator, name: "Pixel_Tablet_API_34", detail: "sdk_gtablet_arm64", state: "device", pid: 20_009)
        t.cpu = wob(9, tick, 3); t.mem = 4_300 * mb; t.started = ago(26 * 3600); t.screen = "Asleep"; t.guestLoad = "0.31 0.28 0.30"
        var c = Device(id: "R5CT1234ABC", kind: .phone, name: "Galaxy S24", detail: "SM_S921B", state: "device")
        c.foreground = "com.acme.shop/com.acme.shop.HomeActivity"; c.screen = "Asleep"
        b.claim = AgentDevice.Claim(session: "widget-snapshots", workspace: "/Users/demo/code/acme-shop-ios", since: ago(2_400))
        var out = [a, b, t, c]
        for i in out.indices { out[i].lease = leases().first { $0.covers(out[i]) } }
        return out
    }

    /// The Pixel lent through the device manager; the Galaxy in use by a session that drives it with adb directly.
    static func leases() -> [Lease] {
        [Lease(device: "emulator-5554", name: "Pixel_8_API_35", platform: "android", session: sessionSeed[0].id, ownerPid: 0, ownerStart: 0,
               purpose: "Checkout retry on a flaky network", since: ago(1_500), until: now.addingTimeInterval(1_260), booted: true),
         Lease(device: "R5CT1234ABC", name: "R5CT1234ABC", platform: "android", physical: true, session: sessionSeed[1].id, ownerPid: 0, ownerStart: 0,
               since: ago(600), until: now.addingTimeInterval(Leases.renewOnUse - 140), implicit: true)]
    }

    static func bootable() -> (avds: [String], sims: [DeviceManager.Sim]) {
        let v = [18, 2]
        return (["Pixel_8_API_35", "Pixel_Tablet_API_34", "Pixel_Fold_API_35", "Medium_Phone_API_35"],
                ["iPhone 16", "iPhone 16 Pro Max", "iPhone SE (3rd generation)", "iPad Air 11-inch (M2)"].enumerated().map { i, n in
                    DeviceManager.Sim(udid: String(format: "C0FFEE%02d-0000-4000-8000-0000000000%02d", i, i), name: n, runtime: "iOS 18.2", version: v, state: "Shutdown") })
    }

    /// Agent sessions other than Claude Code own their processes by tree, not by environment.
    static func agentOwner(_ ps: [Proc]) -> [Int32: String] {
        var o: [Int32: String] = [:]
        for p in ps {
            switch p.group {
            case "Cursor": o[p.pid] = "pid:20412"
            case "OpenCode": o[p.pid] = sessionSeed[1].id
            case "Codex": o[p.pid] = sessionSeed[2].id
            default: break
            }
        }
        return o
    }

    // MARK: spike history

    /// Fifteen minutes of samples: a Gradle build 11 minutes ago, memory pressure at 7, the Swift build now.
    static func history() -> [Moment] {
        let gradle = Culprit(name: "java", count: 2, group: "Gradle", cpu: 1_310, mem: 6_900 * mb, owner: "started by \(sessionSeed[1].title)")
        let swift = Culprit(name: "swift-frontend", count: 14, group: "Xcode / Swift", cpu: 1_020, mem: 3_600 * mb, owner: "started by \(sessionSeed[2].title)")
        let emu = Culprit(name: "qemu-system-aarch64", count: 1, group: "Android emulators", cpu: 118, mem: 6_100 * mb, owner: "Android emulator")
        let mds = Culprit(name: "mds_stores", count: 1, group: "macOS services", cpu: 180, mem: 9_800 * mb, owner: "macOS")
        let chrome = Culprit(name: "Google Chrome Helper", count: 31, group: "Google Chrome", cpu: 14, mem: 4_200 * mb, owner: "app Google Chrome")
        let model = Culprit(name: "ollama", count: 2, group: "Local models", cpu: 0.6, mem: 9_400 * mb, owner: "started by you")
        var out: [Moment] = []
        for i in stride(from: 900, to: 0, by: -5) {
            let t = Double(i)
            var cpu = 18 + 6 * sin(t / 23)
            var pressure: Int32 = 1
            if (640...690).contains(t) { cpu = 78 + 10 * sin(t / 7) }           // Gradle build
            if (400...440).contains(t) { pressure = 2; cpu = 34 }                 // memory pressure while the build cache was written
            if (300...330).contains(t) { cpu = 58 + 8 * sin(t / 5) }
            if t <= 25 { cpu = 84 + 4 * sin(t / 3) }                             // the Swift build running now
            var mo = Moment(at: now.addingTimeInterval(-t), cpu: cpu, memUsed: 41 * gb + UInt64(t) * 4 * mb, pressure: pressure)
            if cpu >= Moment.hotCPU || pressure >= 2 || i % 30 == 0 {
                mo.topCPU = (640...690).contains(t) ? [gradle, emu, mds, chrome] : t <= 25 ? [swift, emu, mds, chrome] : [emu, mds, chrome]
                mo.topMem = [model, mds, gradle, emu, chrome]
            }
            out.append(mo)
        }
        return out
    }

    // MARK: worktrees

    static func worktrees() -> [Worktree] {
        let h = Sh.home
        func w(_ repo: String, _ path: String, _ branch: String, main: Bool, _ s: String?, _ act: TimeInterval, _ gbs: Double, used: [String] = []) -> Worktree {
            Worktree(path: h + path, repo: repo, repoPath: h + "/code/" + repo, branch: branch, head: String(abs(path.hashValue) % 0xfffffff, radix: 16),
                     exists: true, isMain: main, locked: false, prunable: false, session: s, lastActivity: ago(act), usedBy: used,
                     sizeKB: Int64(gbs * 1_048_576))
        }
        return [
            w("acme-shop-android", "/code/acme-shop-android", "main", main: true, nil, 300, 9.4, used: ["Android Studio (20114)"]),
            w("acme-shop-android", "/code/acme-shop-android/.worktrees/fix-double-charge", "fix/double-charge", main: false, sessionSeed[0].id, 60, 3.1, used: ["claude (20301)", "java (20084)"]),
            w("acme-shop-android", "/code/acme-shop-android/.worktrees/compose-settings", "feat/compose-settings", main: false, sessionSeed[1].id, 900, 2.8, used: ["claude (20308)"]),
            w("acme-shop-android", "/code/acme-shop-android/.worktrees/release-4.11", "release/4.11", main: false, nil, 86_400 * 9, 3.0),
            w("acme-shop-ios", "/code/acme-shop-ios", "main", main: true, nil, 1_200, 6.2),
            w("acme-shop-ios", "/code/acme-shop-ios/.worktrees/order-widget", "feat/order-widget", main: false, sessionSeed[2].id, 120, 1.9, used: ["claude (20315)", "Xcode (20140)"]),
            w("acme-shop-ios", "/code/acme-shop-ios/.worktrees/a11y-onboarding", "chore/a11y-onboarding", main: false, sessionSeed[6].id, 86_400 * 4, 1.4),
            w("acme-design-system", "/code/acme-design-system", "main", main: true, nil, 600, 1.1),
            w("acme-api", "/code/acme-api", "main", main: true, nil, 3_900, 0.8),
            w("acme-api", "/code/acme-api/.worktrees/spike-graphql", "spike/graphql", main: false, nil, 86_400 * 21, 0.6),
        ]
    }

    // MARK: rules

    static func jobs() -> [BuildJob] {
        let c = "/Users/demo/code/"
        return [
            BuildJob(pid: 20_901, start: 0, kind: "gradle", weight: 2, cwd: c + "acme-shop-android/.worktrees/fix-double-charge",
                     cmd: "./gradlew --max-workers=6 :app:assembleDebug", state: "running", since: ago(140), session: sessionSeed[0].id, queuedAt: ago(150)),
            BuildJob(pid: 20_944, start: 0, kind: "xcodebuild", weight: 2, cwd: c + "acme-shop-ios/.worktrees/order-widget",
                     cmd: "xcodebuild -jobs 6 -scheme AcmeShop -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build", state: "running", since: ago(65), session: sessionSeed[2].id, queuedAt: ago(70)),
            BuildJob(pid: 20_958, start: 0, kind: "gradle", weight: 2, cwd: c + "acme-shop-android/.worktrees/release-notes",
                     cmd: "./gradlew --max-workers=6 :app:bundleRelease", state: "running", since: ago(30), session: sessionSeed[5].id, queuedAt: ago(95)),
            BuildJob(pid: 20_970, start: 0, kind: "gradle", weight: 2, cwd: c + "acme-shop-android/.worktrees/compose-settings",
                     cmd: "./gradlew --max-workers=6 testDebugUnitTest", state: "waiting", since: ago(38), session: sessionSeed[1].id, queuedAt: ago(38)),
            BuildJob(pid: 20_985, start: 0, kind: "xcodebuild", weight: 2, cwd: c + "acme-design-system",
                     cmd: "xcodebuild -jobs 6 -scheme DesignSystem test", state: "waiting", since: ago(21), session: sessionSeed[3].id, queuedAt: ago(21)),
        ]
    }

    /// A Swift build an agent started inside a script, which the hook can't see into.
    static func outside() -> [Rules.OutsideBuild] {
        [Rules.OutsideBuild(pid: 20_990, kind: "xcodebuild", cwd: "/Users/demo/code/acme-shop-ios", session: sessionSeed[2].id, since: ago(260), cpu: 310,
                            reason: "started inside a script or tool the hook can't see into")]
    }

    static func buildCPU(_ pid: Int32) -> Double? { [20_901: 412, 20_944: 520, 20_958: 365, 20_990: 310][pid] }

    static func buildHistory() -> [BuildRecord] {
        let c = "/Users/demo/code/"
        func r(_ kind: String, _ dir: String, _ s: Int, _ endedAgo: TimeInterval, waited: TimeInterval, ran: TimeInterval,
               overflow: Bool = false, forced: Bool = false, early: Bool = false, exit: Int32 = 0) -> BuildRecord {
            let end = ago(endedAgo), start = end.addingTimeInterval(-ran)
            return BuildRecord(kind: kind, pool: kind == "xcodebuild" ? "ios" : "android", cwd: c + dir, cmd: "", session: sessionSeed[s].id,
                               queuedAt: start.addingTimeInterval(-waited), startedAt: start, endedAt: end, waited: waited,
                               overflow: overflow, forced: forced, releasedEarly: early, exit: exit)
        }
        return [
            r("gradle", "acme-shop-android/.worktrees/fix-double-charge", 0, 300, waited: 14, ran: 182, early: true),
            r("xcodebuild", "acme-shop-ios/.worktrees/order-widget", 2, 720, waited: 0, ran: 410),
            r("gradle", "acme-shop-android/.worktrees/compose-settings", 1, 1_380, waited: 600, ran: 240, overflow: true),
            r("install", "acme-web", 4, 1_900, waited: 3, ran: 48),
            r("xcodebuild", "acme-design-system", 3, 2_600, waited: 95, ran: 300, forced: true, exit: 65),
            r("gradle", "acme-shop-android", 5, 3_400, waited: 0, ran: 156),
            r("xcodebuild", "acme-shop-ios", 2, 5_200, waited: 210, ran: 388, early: true),
        ]
    }

    static func reapReport() -> ReapReport {
        var r = ReapReport(at: ago(240), applied: true)
        r.actions = [
            ReapAction(kind: "Shut down", target: "Pixel_Tablet_API_34", key: "emulator-5556", detail: "Android emulator, idle 26.0 h · Galaxy S24 connected", bytes: Int64(4_300 * mb), result: "Shut down Pixel_Tablet_API_34.", outcome: "done"),
            ReapAction(kind: "Remove worktree", target: "~/code/acme-shop-android/.worktrees/release-4.11", key: "wt1", detail: "release/4.11, clean, idle 9 d. The branch and its commits stay.", bytes: Int64(3 * gb), result: "Removed.", outcome: "done"),
            ReapAction(kind: "Strip build output", target: "~/code/acme-shop-ios/.worktrees/a11y-onboarding", key: "wt2", detail: "source kept (2 uncommitted change(s), e.g. Onboarding/Welcome.swift); idle 4 d; deletes build, node_modules", bytes: Int64(1_200 * mb), result: "Deleted 2 folder(s).", outcome: "done"),
            ReapAction(kind: "Remove worktree", target: "~/code/acme-api/.worktrees/spike-graphql", key: "wt3", detail: "spike/graphql, clean, idle 21 d. The branch and its commits stay.", bytes: Int64(600 * mb), result: "Kept: untracked files appeared. ", outcome: "kept"),
            ReapAction(kind: "Delete DerivedData", target: "AcmeShop-bqzkxnhgfyyqwe", key: "dd1", detail: "its project ~/code/acme-shop-ios/.worktrees/old-cart/AcmeShop.xcodeproj no longer exists", bytes: Int64(7_400 * mb), result: "Could not delete.", outcome: "failed"),
        ]
        r.kept = ["Pixel_8_API_35 (emulator-5554): used 1 min ago", "iPhone 16 Pro (B1A2C3D4-E5F6-4789-A0B1-C2D3E4F5A6B7): used 2 min ago"]
        return r
    }

    static func ruleLog() -> [String] {
        let f = Rules.stamp
        return [
            f.string(from: ago(240)) + " shut down Pixel_Tablet_API_34 (emulator-5556): Android emulator, idle 26.0 h · Galaxy S24 connected",
            f.string(from: ago(238)) + " remove /Users/demo/code/acme-shop-android/.worktrees/release-4.11: Removed.",
            f.string(from: ago(236)) + " cached node_modules 5c1e9a07d2b4f310 from ~/code/acme-shop-ios/.worktrees/a11y-onboarding",
            f.string(from: ago(235)) + " strip /Users/demo/code/acme-shop-ios/.worktrees/a11y-onboarding: build, node_modules",
            f.string(from: ago(233)) + " remove /Users/demo/code/acme-api/.worktrees/spike-graphql: Removed.",
            f.string(from: ago(232)) + " delete DerivedData AcmeShop-bqzkxnhgfyyqwe",
        ].reversed()
    }

    // MARK: disk

    static func folders() -> [Folder] {
        let h = Sh.home
        func f(_ l: String, _ p: String, _ g: Double) -> Folder { Folder(label: l, path: p, kb: Int64((g * 0.72).rounded() * 1_048_576)) }
        return [
            f("Emulators", h + "/.android/avd", 96), f("Android SDK", h + "/Library/Android/sdk", 58),
            f("Simulators", h + "/Library/Developer/CoreSimulator", 74), f("DerivedData", h + "/Library/Developer/Xcode", 81),
            f("Gradle", h + "/.gradle", 47), f("code", h + "/code", 112), f("Docker", h + "/Library/Containers/com.docker.docker", 64),
            // Only folders the real scan measures: nothing macOS guards with a privacy prompt (Worktrees.privateHome).
            f("App caches", h + "/Library/Caches", 38), f("Applications", "/Applications", 41),
            f("Ollama models", h + "/.ollama", 72), f("Hugging Face cache", h + "/.cache/huggingface", 44),
            f("node_modules cache", h + "/.npm", 9.5), f("Homebrew", "/opt/homebrew", 14),
            f("Slack", h + "/Library/Application Support/Slack", 3.2), f("Figma", h + "/Library/Application Support/Figma", 2.4),
            f("Zoom", h + "/Library/Application Support/zoom.us", 1.6), f("Xcode archives", h + "/Library/Developer/Xcode/Archives-old", 4.4),
            f("Simulator caches", h + "/Library/Developer/CoreSimulator/Caches", 2.9), f("Rust toolchains", h + "/.rustup", 5.7),
            f("Go cache", h + "/Library/Caches/go-build", 3.8), f("pip cache", h + "/Library/Caches/pip", 1.2),
        ]
    }

    static func children(of path: String) -> [Folder] {
        let names = ["build", "src", "assets", "node_modules", ".git", "docs", "fixtures", "vendor", "tools", "scripts", "screenshots", "logs"]
        let base = Double(abs(path.hashValue % 7) + 3)
        return names.enumerated().map { i, n in
            Folder(label: n, path: path + "/" + n, kb: Int64(base * 1_048_576 / pow(1.55, Double(i))))
        }
    }
}
