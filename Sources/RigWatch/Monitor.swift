import AppKit
import Foundation

enum Page: String, CaseIterable, Identifiable {
    case overview = "Overview", devices = "Emulators & Simulators", sessions = "Agent Sessions", servers = "Dev Servers",
         processes = "Processes", memory = "Memory", worktrees = "Worktrees", disk = "Disk"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"; case .devices: "iphone.gen3"; case .sessions: "bubble.left.and.text.bubble.right"; case .servers: "server.rack"
        case .processes: "cpu"; case .memory: "memorychip"; case .worktrees: "arrow.triangle.branch"; case .disk: "internaldrive"
        }
    }
}

struct ProcGroup: Identifiable, Hashable {
    let name: String; var count: Int; var cpu: Double; var mem: UInt64; var disk: Double; var killable: [Int32]
    var id: String { name }
}

struct Folder: Identifiable, Hashable { let label: String; let path: String; var kb: Int64?; var id: String { path } }

struct Pending: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let button: String
    var blocked = false
    let run: () -> String
}

@MainActor
final class Monitor: ObservableObject {
    static let shared = Monitor()
    @Published var tab: Page = .overview
    @Published var procSearch = ""          // Processes tab filter; the Overview map sets it to jump to a process
    @Published var sys = SysSnapshot()
    @Published var procs: [Proc] = [] { didSet { procIndex = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a }) } }
    private(set) var procIndex: [Int32: Proc] = [:]
    @Published var groups: [ProcGroup] = []
    @Published var devices: [Device] = []
    @Published var sessions: [Session] = []
    @Published var servers: [DevServer] = []
    @Published var worktrees: [Worktree] = []
    @Published var folders: [Folder] = Demo.on ? Demo.folders() : Monitor.defaultFolders()
    @Published var pending: Pending?
    @Published var toast: String?
    @Published var screenshot: (device: Device, image: NSImage)?
    @Published var busy: Set<String> = []
    @Published var selfCPU = 0.0
    @Published var selfMem: UInt64 = 0
    @Published var agentOwner: [Int32: String] = [:]   // pid -> session id, for agents other than Claude Code
    @Published var top: TopKind?                         // the Top CPU / Top memory sheet, when open
    @Published var history: [Moment] = []                // the last 15 minutes, in memory only
    @Published var hotStreak = 0                         // samples in a row with CPU >= 70%
    @Published var bannerDismissed = false
    private var lastProbe = Date.distantPast
    private var lastHiddenProcs = Date.distantPast

    private let q = DispatchQueue(label: "rigwatch.sample", qos: .utility, autoreleaseFrequency: .workItem)
    /// du and other minute-long scans: kept off the sampling queue so live numbers never stall behind them.
    private let slow = DispatchQueue(label: "rigwatch.scan", qos: .utility, attributes: .concurrent, autoreleaseFrequency: .workItem)
    private let procSampler = ProcSampler()
    private let sysSampler = SystemSampler()
    private let devSampler = DeviceSampler()
    private let index = SessionIndex()
    private let agents = AgentIndex()
    private let serverScanner = DevServerScanner()
    private var running = false
    private var tick = 0
    private var lastFull = Date.distantPast
    private var lastWorktrees = Date.distantPast
    private var lastMentions = Date.distantPast
    private var timer: Timer?

    init() {
        if let i = CommandLine.arguments.firstIndex(of: "-page"), i + 1 < CommandLine.arguments.count,
           let p = Page.allCases.first(where: { "\($0)" == CommandLine.arguments[i + 1] }) {
            tab = p
            if let k = CommandLine.arguments.firstIndex(of: "-top"), k + 1 < CommandLine.arguments.count { top = TopKind(rawValue: CommandLine.arguments[k + 1]) }
            // Opened on a given page (used to capture screenshots): bring the window to the main display.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.windows.first { $0.canBecomeMain }?.center() }
            if let j = CommandLine.arguments.firstIndex(of: "-snap"), j + 1 < CommandLine.arguments.count {
                let out = CommandLine.arguments[j + 1]
                DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                    guard let v = NSApp.windows.first(where: { $0.canBecomeMain })?.contentView?.superview,
                          let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.heartbeat() } }
        timer?.tolerance = 0.5
        DispatchQueue.main.async { self.heartbeat(force: true) }   // NSApp does not exist yet during App.init
    }

    private let snapshotting = CommandLine.arguments.contains("-snap")
    var windowVisible: Bool {
        if snapshotting { return true }
        guard let app = NSApp as NSApplication? else { return false }
        return app.windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) && $0.canBecomeMain && !($0 is NSPanel) }
    }

    /// Seconds between samples while the window is on screen (Sidebar picker; 3, 5 or 10).
    var interval: Int { let v = UserDefaults.standard.integer(forKey: "interval"); return v == 0 ? 5 : v }

    private func heartbeat(force: Bool = false) {
        tick += 1
        let visible = windowVisible
        // Hidden: a cheap CPU/memory check every 5 s keeps the spike history going; processes are
        // listed only while the machine is busy, so the culprits of a spike are on record.
        if !visible, !force, !Demo.on, !running, Date().timeIntervalSince(lastProbe) >= 5, Date().timeIntervalSince(lastFull) < 55 { probe(); return }
        let interval: TimeInterval = visible ? TimeInterval(self.interval) : 60
        guard force || Date().timeIntervalSince(lastFull) >= interval, !running else { return }
        lastFull = Date()
        refresh(visible: visible || force)
    }

    func refresh(visible: Bool = true, worktreesNow: Bool = false) {
        guard !running else { return }
        if Demo.on {
            let ps = Demo.procs(tick)
            sys = Demo.sys(tick, procs: ps, real: sys.memTotal > 0 ? sys : sysSampler.sample())
            procs = ps; groups = Demo.groups(ps); devices = Demo.devices(tick)
            servers = Demo.servers(tick); sessions = Self.attach(servers, to: Demo.sessions(tick))
            if worktrees.isEmpty { worktrees = Demo.worktrees() }
            selfCPU = 0.5; selfMem = 140 << 20
            record(sys, procs, groups)
            return
        }
        running = true
        let tab = self.tab
        let wantDevices = visible && (tab == .devices || tab == .sessions)
        let wantMentions = visible && (tab == .devices || tab == .sessions) && Date().timeIntervalSince(lastMentions) > 30
        let wantWorktrees = worktreesNow || (visible && (tab == .worktrees || tab == .sessions || (tab == .overview && worktrees.isEmpty)) && (Date().timeIntervalSince(lastWorktrees) > 60 || worktrees.isEmpty))
        if wantMentions { lastMentions = Date() }
        if wantWorktrees { lastWorktrees = Date() }
        let oldWorktrees = worktrees
        q.async { [procSampler, sysSampler, devSampler, index, agents, serverScanner] in
            let s = sysSampler.sample()
            guard visible else {
                DispatchQueue.main.async { self.sys = s; self.record(s, nil, nil); self.running = false }
                return
            }
            let ps = procSampler.sample()
            let devs = wantDevices ? devSampler.sample(procs: ps, deep: tab == .devices) : nil
            if wantMentions, let devs { index.scanMentions(keys: devs.map(\.id).filter { !$0.hasPrefix("pid:") }) }
            // The worktree listing runs git across every repo; it goes to the slow queue so it never
            // holds back the live numbers.
            if wantWorktrees { self.listWorktrees(ps: ps, old: oldWorktrees) }
            let wts: [Worktree]? = oldWorktrees   // last listing, for per-session worktree counts
            var sess = (Self.buildSessions(ps, devs, wts, index, procSampler) + agents.sessions(ps))
                .sorted { ($0.live ? 0 : 1, $0.transcriptAge ?? .infinity) < ($1.live ? 0 : 1, $1.transcriptAge ?? .infinity) }
            let servers = serverScanner.scan(ps, sessions: sess, agentOwner: agents.owner)
            sess = Self.attach(servers, to: sess)
            let groups = Self.group(ps)
            let own = ps.first { $0.pid == getpid() }
            let owner = agents.owner
            let mentions = index.mentions
            let actions = index.lastAction
            DispatchQueue.main.async {
                self.sys = s; self.procs = ps; self.groups = groups; self.sessions = sess; self.servers = servers; self.agentOwner = owner
                if var devs {
                    for i in devs.indices { devs[i].recentUsers = mentions[devs[i].id] ?? [:]; devs[i].lastAction = actions[devs[i].id] }
                    self.devices = devs
                }
                self.selfCPU = own?.cpu ?? 0; self.selfMem = own?.mem ?? 0
                self.record(s, ps, groups)
                self.running = false
            }
        }
    }

    private func probe() {
        lastProbe = Date()
        running = true
        let listProcs = Date().timeIntervalSince(lastHiddenProcs) >= 10
        q.async { [sysSampler, procSampler] in
            let s = sysSampler.light()
            let hot = s.cpu >= Moment.hotCPU || s.pressure >= 2
            let ps = hot && listProcs ? procSampler.sample() : nil
            let groups = ps.map(Self.group)
            DispatchQueue.main.async {
                if let ps, let groups { self.lastHiddenProcs = Date(); self.record(s, ps, groups) } else { self.record(s, nil, nil) }
                self.running = false
            }
        }
    }

    /// Adds a sample to the 15-minute history and keeps the high-CPU streak.
    func record(_ s: SysSnapshot, _ ps: [Proc]?, _ groups: [ProcGroup]?) {
        hotStreak = s.cpu >= Moment.hotCPU ? hotStreak + 1 : 0
        if hotStreak == 0 { bannerDismissed = false }
        var mo = Moment(at: Date(), cpu: s.cpu, memUsed: s.memUsed, pressure: s.pressure)
        if let ps, let groups {
            mo.topCPU = culprits(ps, groups, byCPU: true)
            mo.topMem = culprits(ps, groups, byCPU: false)
        }
        history.append(mo)
        let cutoff = Date().addingTimeInterval(-Moment.window)
        if let i = history.firstIndex(where: { $0.at >= cutoff }), i > 0 { history.removeFirst(i) }
        if history.count > 600 { history.removeFirst(history.count - 600) }
    }

    /// The top five groups by CPU or memory, each named by its biggest process: "swift-frontend ×14".
    func culprits(_ ps: [Proc], _ groups: [ProcGroup], byCPU: Bool) -> [Culprit] {
        func load(_ p: Proc) -> Double { byCPU ? p.cpu : Double(p.mem) }
        let top = groups.sorted { byCPU ? $0.cpu > $1.cpu : $0.mem > $1.mem }.prefix(5).filter { byCPU ? $0.cpu >= 1 : $0.mem > 0 }
        return top.map { g in
            let members = ps.filter { $0.group == g.name }
            let index = Dictionary(ps.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
            var byName: [String: (Double, Int)] = [:]
            for p in members { byName[p.name, default: (0, 0)].0 += load(p); byName[p.name, default: (0, 0)].1 += 1 }
            let lead = byName.max { $0.value.0 < $1.value.0 }
            var bySession: [String: Double] = [:]
            for p in members { if let id = sessionId(p, index) { bySession[id, default: 0] += load(p) } }
            let total = members.reduce(0) { $0 + load($1) }
            var owner = ""
            if let (id, v) = bySession.max(by: { $0.value < $1.value }), total > 0, v / total > 0.5 { owner = "started by \(sessionTitle(id))" }
            else if let p = members.max(by: { load($0) < load($1) }) { owner = self.owner(p) }
            return Culprit(name: lead?.key ?? g.name, count: lead?.value.1 ?? g.count, group: g.name, cpu: g.cpu, mem: g.mem, owner: owner)
        }
    }

    /// Lists each dev server on the card of the session that started it.
    nonisolated private static func attach(_ servers: [DevServer], to sess: [Session]) -> [Session] {
        var sess = sess
        for d in servers {
            if let id = d.session, let i = sess.firstIndex(where: { $0.id == id }) { sess[i].servers.append(d.label) }
        }
        return sess
    }

    nonisolated private static func group(_ ps: [Proc]) -> [ProcGroup] {
        var g: [String: ProcGroup] = [:]
        let me = getuid()
        for p in ps {
            var x = g[p.group] ?? ProcGroup(name: p.group, count: 0, cpu: 0, mem: 0, disk: 0, killable: [])
            x.count += 1; x.cpu += p.cpu; x.mem += p.mem; x.disk += p.diskRead + p.diskWrite
            if p.uid == me && Safety.processBlock(p) == nil { x.killable.append(p.pid) }
            g[p.group] = x
        }
        return Array(g.values)
    }

    nonisolated private static func buildSessions(_ ps: [Proc], _ devs: [Device]?, _ wts: [Worktree]?, _ index: SessionIndex, _ sampler: ProcSampler) -> [Session] {
        var live: [String: String] = [:]   // id -> host
        var cliPids: [String: [Int32: UInt64]] = [:]   // id -> its terminal `claude` processes, the ones Quit session may end
        let byPid = Dictionary(uniqueKeysWithValues: ps.map { ($0.pid, $0) })
        var kids: [Int32: [Int32]] = [:]
        for p in ps { kids[p.ppid, default: []].append(p.pid) }
        for p in ps where p.group == "Claude Code sessions" && p.name == "claude" {
            var id: String?
            // Children carry the exact id in their environment.
            id = (kids[p.pid] ?? []).compactMap { byPid[$0]?.session }.first
            if id == nil, let h = sampler.hostSession(p.pid) { id = index.cliId(forHost: h) }
            if id == nil, let i = p.args.firstIndex(where: { $0.hasPrefix("--resume") }) {
                let a = p.args[i]
                id = a.contains("=") ? String(a.split(separator: "=")[1]) : (i + 1 < p.args.count ? p.args[i + 1] : nil)
            }
            guard let id else { continue }
            if sampler.hostSession(p.pid) != nil { live[id] = "Desktop" }   // run by the Claude app: left to the app
            else {
                if live[id] == nil { live[id] = "CLI" }
                if p.start != 0 { cliPids[id, default: [:]][p.pid] = p.start }
            }
        }
        var ids = Set(live.keys)
        for p in ps { if let s = p.session { ids.insert(s) } }
        var hosts: [String: String] = [:]   // cli id -> local_… id, from any process that inherited both
        for p in ps { if let s = p.session, let h = p.hostSession { hosts[s] = h } }
        for p in ps where p.name == "claude" { if let h = sampler.hostSession(p.pid), let c = index.cliId(forHost: h) { hosts[c] = h } }
        var out: [String: Session] = [:]
        for id in ids {
            out[id] = index.describe(id, live: live[id] != nil, host: live[id] ?? "gone")
            out[id]!.hostId = hosts[id] ?? index.hostId(forCli: id)
            out[id]!.pids = cliPids[id] ?? [:]
        }
        // Attribute every process to the session whose id it inherited.
        for p in ps { if let s = p.session, out[s] != nil { out[s]!.procCount += 1; out[s]!.cpu += p.cpu; out[s]!.mem += p.mem } }
        for d in devs ?? [] {
            if let l = d.launchedBy, out[l] != nil { out[l]!.devices.append(d.name) }
        }
        for w in wts ?? [] { if let s = w.session, out[s] != nil { out[s]!.worktrees += 1 } }
        return out.values.sorted { ($0.live ? 0 : 1, $0.transcriptAge ?? .infinity) < ($1.live ? 0 : 1, $1.transcriptAge ?? .infinity) }
    }

    var emulatorCount: Int { procs.filter { $0.name.hasPrefix("qemu-system") }.count }
    var simulatorCount: Int { procs.filter { $0.name == "launchd_sim" }.count }
    var idleWorktrees: Int { worktrees.filter { !$0.isMain && ($0.lastActivity.map { Date().timeIntervalSince($0) > 86400 } ?? true) }.count }

    func session(_ id: String?) -> Session? { id.flatMap { i in sessions.first { $0.id == i } } }
    func sessionLabel(_ id: String?) -> String {
        guard let id else { return "—" }
        if let s = session(id) { return "\(s.title) · \(s.status)" }
        return String(id.prefix(8))
    }

    // MARK: actions (always behind a confirmation)

    func perform(_ key: String, _ work: @escaping () -> String) {
        if Demo.on { toast = "Demo mode: nothing was changed."; return }
        busy.insert(key)
        q.async {
            let msg = work()
            DispatchQueue.main.async {
                self.busy.remove(key)
                self.toast = msg
                self.lastWorktrees = .distantPast
                self.refresh(worktreesNow: key.hasPrefix("wt:"))
                // A quit process can take a moment to exit: look again so its card goes promptly.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.refresh() }
            }
        }
    }

    func confirmQuit(_ p: Proc, force: Bool = false) {
        if let why = Safety.processBlock(p) { toast = "Not allowed: \(why)"; return }
        var msg = "\(p.name) (pid \(p.pid)) · CPU \(Fmt.cpu(p.cpu)) · \(Fmt.bytes(p.mem))\n\(p.path)"
        if let s = p.session { msg += "\n\nStarted by agent session: \(sessionLabel(s))" }
        if let w = Safety.processWarning(p, sessions: sessions) { msg += "\n\n⚠️ \(w)" }
        msg += force ? "\n\nForce Quit (SIGKILL) gives it no chance to save anything." : "\n\nQuit sends SIGTERM so it can shut down cleanly."
        pending = Pending(title: force ? "Force quit \(p.name)?" : "Quit \(p.name)?", message: msg, button: force ? "Force Quit" : "Quit") {
            kill(p.pid, force ? SIGKILL : SIGTERM) == 0 ? "Sent \(force ? "SIGKILL" : "SIGTERM") to \(p.name) (\(p.pid))." : "Could not signal \(p.pid): \(String(cString: strerror(errno)))"
        }
    }

    /// Quit session: SIGTERM to the session's own agent process(es), never the Claude app.
    func confirmQuitSession(_ s: Session) {
        if Demo.on { toast = "Demo mode: nothing was changed."; return }
        let targets = s.pids.compactMap { pid, start in procs.first { $0.pid == pid && $0.start == start } }.sorted { $0.pid < $1.pid }
        guard !targets.isEmpty else {
            toast = s.host == "Desktop" ? "Desktop sessions run inside the Claude app: archive this one there." : "\(s.title) is no longer running."
            return
        }
        for p in targets {
            if let why = Safety.processBlock(p) { toast = "Not allowed: \(why)"; return }
            if p.path.hasSuffix("Claude.app/Contents/MacOS/Claude") { toast = "Not allowed: that is the Claude desktop app."; return }
        }
        let host = s.host == "Desktop" ? "CLI" : s.host   // a Desktop card only lists its terminal processes here
        var msg = "\(s.agent.rawValue) · \(s.title)"
        msg += "\n" + targets.map { "\($0.name) (pid \($0.pid)) · \(host) · CPU \(Fmt.cpu($0.cpu)) · \(Fmt.bytes($0.mem))" }.joined(separator: "\n")
        if targets.count > 1 { msg += "\n\nThis session is open in \(targets.count) processes (a resume runs alongside the original): all of them are quit." }
        if s.host == "Desktop" { msg += "\n\nThe Claude app's own process for this session is left alone; archive the session in the Claude app to end it there." }
        if s.host == "App", let p = targets.first { msg += "\n\n⚠️ This quits \(p.name) itself, with all of its windows." }
        if s.isWorking { msg += "\n\n⚠️ This session is working right now: quitting stops it mid-turn." }
        if !s.id.hasPrefix("pid:"), let cmd = s.agent.resumeCommand(s.id) {
            msg += "\n\nThe conversation is saved. Resume it later with:\n\(cmd)"
        } else {
            msg += "\n\nWhat \(s.agent.rawValue) keeps after quitting is up to it; RigWatch has no resume command for it."
        }
        let mine = Set(targets.map(\.pid))
        let kids = procs.filter { !mine.contains($0.pid) && $0.session == s.id }.count
        if kids > 0 { msg += "\n\nThe \(kids) process(es) it started (MCP servers, dev servers, builds) are not stopped here. Any that keep running stay on Processes and Dev Servers." }
        msg += "\n\nQuit sends SIGTERM so it can shut down cleanly."
        let list = targets.map { ($0.pid, $0.start) }, name = s.agent.rawValue
        pending = Pending(title: "Quit session \(s.title.prefix(40))?", message: msg, button: "Quit Session") {
            var sent: [Int32] = [], gone = 0, failed: [String] = []
            for (pid, start) in list {
                // The pid may have been reused since the dialog opened: only signal the same process.
                guard ProcSampler.startTime(pid) == start else { gone += 1; continue }
                if kill(pid, SIGTERM) == 0 { sent.append(pid) } else { failed.append("\(pid): \(String(cString: strerror(errno)))") }
            }
            if !failed.isEmpty { return "Could not signal " + failed.joined(separator: ", ") }
            if sent.isEmpty { return "\(name) had already exited." }
            return "Sent SIGTERM to \(name) (pid \(sent.map(String.init).joined(separator: ", ")))." + (gone > 0 ? " \(gone) had already exited." : "")
        }
    }

    /// Started-by line for a dev server: the live session, the remembered one, or its parent.
    func startedBy(_ d: DevServer) -> String {
        if let id = d.session {
            let s = session(id)
            let title = s?.title ?? d.sessionTitle ?? String(id.prefix(8))
            return (s?.live ?? false) ? "started by \(title)" : "started by \(title) (session ended)"
        }
        if d.orphaned { return "orphaned" }
        return d.parent.map { "parent: \($0)" } ?? "parent: pid \(d.ppid)"
    }

    func openServer(_ d: DevServer, port: Int? = nil) {
        guard let p = port ?? d.ports.first, let url = URL(string: "http://localhost:\(p)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Stop = Quit (SIGTERM) for the server's process, with the same rules and confirmation.
    func confirmStop(_ d: DevServer) {
        if Demo.on { toast = "Demo mode: nothing was changed."; return }
        guard let p = procs.first(where: { $0.pid == d.pid && $0.start == d.start }) else { toast = "\(d.kind) is no longer running."; return }
        if let why = Safety.processBlock(p) { toast = "Not allowed: \(why)"; return }
        var msg = "\(d.label) · \(p.name) (pid \(p.pid)) · CPU \(Fmt.cpu(p.cpu)) · \(Fmt.bytes(p.mem))"
        if let c = d.cwd { msg += "\n\(Views.tilde(c))" }
        msg += "\n\n" + startedBy(d).prefix(1).uppercased() + startedBy(d).dropFirst()
        if let w = Safety.processWarning(p, sessions: sessions) { msg += "\n\n⚠️ \(w)" }
        msg += "\n\nStop sends SIGTERM so it can shut down cleanly."
        let pid = d.pid, start = d.start, name = d.kind
        pending = Pending(title: "Stop \(d.kind)?", message: msg, button: "Stop") {
            // The pid may have been reused since the dialog opened: only signal the same process.
            guard ProcSampler.startTime(pid) == start else { return "\(name) had already stopped." }
            return kill(pid, SIGTERM) == 0 ? "Sent SIGTERM to \(name) (\(pid))." : "Could not signal \(pid): \(String(cString: strerror(errno)))"
        }
    }

    func confirmQuitGroup(_ g: ProcGroup) {
        guard !g.killable.isEmpty else { toast = "Nothing in \(g.name) can be quit from here."; return }
        pending = Pending(title: "Quit \(g.killable.count) process(es) in \(g.name)?",
                          message: "Sends SIGTERM to \(g.killable.count) of \(g.count) processes (\(Fmt.bytes(g.mem)), CPU \(Fmt.cpu(g.cpu))). System processes are skipped.",
                          button: "Quit All") {
            let n = g.killable.filter { kill($0, SIGTERM) == 0 }.count
            return "Sent SIGTERM to \(n) process(es) in \(g.name)."
        }
    }

    func confirmShutDown(_ d: Device) {
        guard d.kind != .phone else { toast = "Physical devices are not shut down from here."; return }
        var msg = "\(d.kind.rawValue) \(d.name) · CPU \(Fmt.cpu(d.cpu)) · \(Fmt.bytes(d.mem))"
        if let l = d.launchedBy { msg += "\nLaunched by: \(sessionLabel(l))" }
        let working = d.recentUsers.keys.compactMap { session($0) }.filter { $0.isWorking }
        if let a = d.lastAction { msg += "\nLast command there (\(sessionLabel(a.session)), \(Fmt.ago(a.at))):\n\(a.command.prefix(200))" }
        let recent = d.recentUsers.sorted { $0.value > $1.value }.prefix(4).map { "• \(sessionLabel($0.key)) — \(Fmt.ago($0.value))" }
        if !recent.isEmpty { msg += "\nRecently used by:\n" + recent.joined(separator: "\n") }
        if !d.foreground.isEmpty { msg += "\nShowing: \(d.foreground)" }
        if !working.isEmpty { msg += "\n\n⚠️ \(working.map(\.title).joined(separator: ", ")) is working right now and mentioned this device in the last few hours. Shutting it down may break that session's run." }
        msg += d.kind == .simulator ? "\n\nRuns `simctl shutdown`." : "\n\nAsks the emulator to quit through its console (adb emu kill). SIGTERM only if it does not answer in 15 s."
        pending = Pending(title: "Shut down \(d.name)?", message: msg, button: "Shut Down") { DeviceSampler.shutDown(d) }
    }

    func takeScreenshot(_ d: Device) {
        if Demo.on { toast = "Demo mode: no real device to capture."; return }
        busy.insert("shot:\(d.id)")
        q.async {
            let data = DeviceSampler.screenshot(d)
            DispatchQueue.main.async {
                self.busy.remove("shot:\(d.id)")
                if let data, let img = NSImage(data: data) { self.screenshot = (d, img) } else { self.toast = "Could not capture \(d.name)." }
            }
        }
    }

    /// Opens a Claude desktop session in the app; otherwise copies the tool's resume command, or
    /// shows the session's folder when the tool has no resume command.
    func openSession(_ id: String) {
        let s = session(id)
        let agent = s?.agent ?? .claude
        if agent == .claude, let h = s?.hostId, let url = URL(string: "claude://code/continue?session=\(h)&source=desktop_action") {
            NSWorkspace.shared.open(url)
        } else if !id.hasPrefix("pid:"), let cmd = agent.resumeCommand(id) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cmd, forType: .string)
            toast = "Copied: \(cmd)"
        } else if let c = s?.cwd {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: c)
        } else {
            toast = "\(agent.rawValue) does not say which session this process is running."
        }
    }

    func confirmRemove(_ ws: [Worktree]) {
        let ws = ws.filter { !$0.isMain }
        guard !ws.isEmpty else { toast = "The main checkout is never removed."; return }
        busy.insert("check")
        if Demo.on { toast = "Demo mode: nothing was changed."; return }
        let working = Set(sessions.filter(\.isWorking).map(\.id))
        q.async {
            let checks = ws.map { ($0, Worktrees.check($0, sessionWorking: $0.session.map(working.contains) ?? false)) }
            DispatchQueue.main.async {
                self.busy.remove("check")
                let ok = checks.filter { $0.1.safe }, bad = checks.filter { !$0.1.safe }
                var msg = ""
                if !ok.isEmpty { msg += "Safe to remove (\(ok.count)):\n" + ok.prefix(12).map { "• \($0.0.path.replacingOccurrences(of: Sh.home, with: "~"))" }.joined(separator: "\n") + (ok.count > 12 ? "\n• …" : "") }
                if !bad.isEmpty { msg += (msg.isEmpty ? "" : "\n\n") + "Kept — would lose something (\(bad.count)):\n" + bad.prefix(8).map { "• \(($0.0.path as NSString).lastPathComponent): \($0.1.reasons.joined(separator: " "))" }.joined(separator: "\n") }
                self.pending = Pending(title: ok.isEmpty ? "Nothing here is safe to remove" : "Remove \(ok.count) worktree(s)?", message: msg,
                                       button: ok.isEmpty ? "OK" : "Remove \(ok.count)", blocked: ok.isEmpty) {
                    ok.map { Worktrees.remove($0.0, force: $0.1.force) }.last.map { ok.count > 1 ? "Removed \(ok.count) worktrees." : $0 } ?? ""
                }
            }
        }
    }

    func measure(_ ws: [Worktree]) {
        if Demo.on { return }
        let paths = ws.filter(\.exists).map(\.path)
        busy.insert("size")
        slow.async {
            for p in paths {
                let kb = Worktrees.sizeKB(p)
                DispatchQueue.main.async { if let i = self.worktrees.firstIndex(where: { $0.path == p }) { self.worktrees[i].sizeKB = kb } }
            }
            DispatchQueue.main.async { self.busy.remove("size") }
        }
    }

    @Published var foldersScannedAt: Date? = UserDefaults.standard.object(forKey: "foldersScannedAt") as? Date

    /// Sizes each folder with du (in the background, one at a time) and remembers the result, so the
    /// storage map shows instantly next launch. Skips if a scan finished in the last 10 minutes.
    func scanFolders(force: Bool = false) {
        guard !busy.contains("folders"), !Demo.on else { return }
        if !force, let at = foldersScannedAt, Date().timeIntervalSince(at) < 6 * 3600 { return }   // auto-rescan at most every 6 h
        busy.insert("folders")
        // Only the curated list is measured here; everything else is found again by discoverFolders.
        let curated = Set(Self.curatedFolders().map(\.path))
        let fs = folders.filter { curated.contains($0.path) && FileManager.default.fileExists(atPath: $0.path) }
        slow.async {
            DispatchQueue.concurrentPerform(iterations: fs.count) { i in   // folders don't overlap; Worktrees.sizeKB caps how many du run at once
                let kb = Worktrees.sizeKB(fs[i].path)
                DispatchQueue.main.async { if let j = self.folders.firstIndex(where: { $0.path == fs[i].path }) { self.folders[j].kb = kb } }
            }
            let found = Self.discoverFolders(known: fs.map(\.path))
            DispatchQueue.main.async {
                self.folders = fs.map { f in self.folders.first { $0.path == f.path } ?? f } + found
                self.busy.remove("folders")
                self.foldersScannedAt = Date()
                UserDefaults.standard.set(Date(), forKey: "foldersScannedAt")
                UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: self.folders.compactMap { f in f.kb.map { (f.path, $0) } }), forKey: "folderKB")
            }
        }
    }

    nonisolated private func listWorktrees(ps: [Proc], old: [Worktree]) {
        slow.async {
            let me = getuid()
            let cwds = ps.filter { $0.uid == me }.compactMap { p in ProcSampler.cwd(p.pid).map { ("\(p.name) (\(p.pid))", $0) } }
            var list = Worktrees.list(cwds: cwds)
            let sizes = Dictionary(old.compactMap { w in w.sizeKB.map { (w.path, $0) } }, uniquingKeysWith: { a, _ in a })
            for i in list.indices { list[i].sizeKB = sizes[list[i].path] }
            DispatchQueue.main.async { self.worktrees = list }
        }
    }

    // MARK: storage drill-down

    @Published var drill: [String] = []                     // path stack, empty = top-level folders
    @Published var children: [String: [Folder]] = [:]       // path -> its entries with sizes

    func openFolder(_ path: String) {
        guard !Worktrees.isPrivate(path) else { return }
        drill.append(path)
        guard children[path] == nil else { return }
        if Demo.on { children[path] = Demo.children(of: path); return }
        busy.insert("drill")
        slow.async {
            var items: [Folder]
            if Worktrees.holdsPrivate(path) {
                // The home folder (or above): size each child on its own and leave the private ones unopened.
                let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
                let kids = names.map { path == "/" ? "/" + $0 : path + "/" + $0 }.filter { !Worktrees.isPrivate($0) }
                var sizes = [Int64?](repeating: nil, count: kids.count)
                let lock = NSLock()
                DispatchQueue.concurrentPerform(iterations: kids.count) { i in
                    let kb = Worktrees.sizeKB(kids[i])
                    lock.lock(); sizes[i] = kb; lock.unlock()
                }
                items = kids.indices.compactMap { i in sizes[i].map { Folder(label: (kids[i] as NSString).lastPathComponent, path: kids[i], kb: $0) } }
            } else {
                // One du call sizes every child: directories and files, one level down.
                let r = Sh.run("/usr/sbin/taskpolicy", ["-b", "/usr/bin/du", "-k", "-a", "-d", "1"] + Worktrees.duIgnore + [path], timeout: 600)
                items = r.out.split(separator: "\n").compactMap { line -> Folder? in
                    let f = line.split(separator: "\t", maxSplits: 1)
                    guard f.count == 2, let kb = Int64(f[0]), String(f[1]) != path else { return nil }
                    return Folder(label: (String(f[1]) as NSString).lastPathComponent, path: String(f[1]), kb: kb)
                }
            }
            items.sort { ($0.kb ?? 0) > ($1.kb ?? 0) }
            DispatchQueue.main.async { self.children[path] = items; self.busy.remove("drill") }
        }
    }

    static func defaultFolders() -> [Folder] {
        let saved = UserDefaults.standard.dictionary(forKey: "folderKB") as? [String: Int64] ?? [:]
        let curated = curatedFolders().map { var f = $0; f.kb = saved[f.path]; return f }
        let found = (UserDefaults.standard.array(forKey: "foundFolders") as? [[String: Any]] ?? []).compactMap { d -> Folder? in
            guard let l = d["label"] as? String, let p = d["path"] as? String, let kb = d["kb"] as? Int64, !Worktrees.isPrivate(p) else { return nil }
            return Folder(label: l, path: p, kb: kb)
        }
        return curated + found
    }

    /// Non-overlapping on purpose: each byte belongs to one block of the storage map. No folder macOS
    /// guards with a privacy prompt (see Worktrees.privateHome).
    static func curatedFolders() -> [Folder] {
        let h = Sh.home
        return [
            Folder(label: "Emulators", path: h + "/.android/avd"),
            Folder(label: "Android SDK", path: h + "/Library/Android/sdk"),
            Folder(label: "Simulators", path: h + "/Library/Developer/CoreSimulator"),
            Folder(label: "DerivedData", path: h + "/Library/Developer/Xcode"),
            Folder(label: "Gradle", path: h + "/.gradle"),
            Folder(label: "Claude tmp", path: "/private/tmp/claude-\(getuid())"),
            Folder(label: "~/.claude", path: h + "/.claude"),
            Folder(label: "App caches", path: h + "/Library/Caches"),
            Folder(label: "Containers", path: h + "/Library/Containers"),
            Folder(label: "Applications", path: "/Applications"),
        ]
    }

    /// Everything the curated list doesn't name: each child of the folders that hold the curated ones
    /// (and of the other big system places) is measured on its own, so the leftover on the map is only
    /// what macOS keeps on its sealed system volume or won't let us read.
    nonisolated static func discoverFolders(known: [String]) -> [Folder] {
        let h = Sh.home, fm = FileManager.default
        let parents = [h, h + "/.android", h + "/Library", h + "/Library/Android", h + "/Library/Developer", "/private/tmp", "/Library", "/opt", "/usr/local", "/private/var"]
        let skip = Set(known + parents + ["/private/var/folders"])   // var/folders is per-user temp, owned by root; counted in the residual
        var jobs: [(parent: String, path: String)] = []
        for parent in parents {
            guard let names = try? fm.contentsOfDirectory(atPath: parent) else { continue }
            for n in names {
                let p = parent + "/" + n
                guard !skip.contains(p), !Worktrees.isPrivate(p), !known.contains(where: { $0.hasPrefix(p + "/") }),
                      let v = try? URL(fileURLWithPath: p).resourceValues(forKeys: [.isSymbolicLinkKey]), v.isSymbolicLink != true else { continue }
                jobs.append((parent, p))
            }
        }
        var sizes = [Int64?](repeating: nil, count: jobs.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
            let kb = Worktrees.sizeKB(jobs[i].path)
            lock.lock(); sizes[i] = kb; lock.unlock()
        }
        let gb: Int64 = 1_048_576   // KB in a GB
        var out: [Folder] = []
        var small: [String: (kb: Int64, n: Int, names: [String])] = [:]
        for (i, j) in jobs.enumerated() {
            guard let kb = sizes[i], kb > 0 else { continue }
            if kb >= gb { out.append(Folder(label: Views.tilde(j.path).replacingOccurrences(of: "~/Library/", with: "Library/"), path: j.path, kb: kb)) }
            else { small[j.parent, default: (0, 0, [])].kb += kb; small[j.parent]!.n += 1; small[j.parent]!.names.append((j.path as NSString).lastPathComponent) }
        }
        for (parent, v) in small where v.kb >= gb / 4 {
            out.append(Folder(label: "Other in \(Views.tilde(parent)) · \(v.n) items", path: parent, kb: v.kb))
        }
        UserDefaults.standard.set(out.map { ["label": $0.label, "path": $0.path, "kb": $0.kb ?? 0] }, forKey: "foundFolders")
        return out
    }
}

enum Safety {
    static let protected: Set<String> = ["WindowServer", "loginwindow", "launchd", "Finder", "Dock", "SystemUIServer", "ControlCenter", "kernel_task", "NotificationCenter", "coreaudiod", "mds", "mds_stores", "fseventsd"]

    static func processBlock(_ p: Proc) -> String? {
        if p.pid <= 1 { return "core system process" }
        if p.uid != getuid() { return "owned by the system (\(p.uid == 0 ? "root" : "uid \(p.uid)"))" }
        if p.pid == getpid() { return "this is RigWatch" }
        if protected.contains(p.name) { return "\(p.name) is part of macOS" }
        return nil
    }

    static func processWarning(_ p: Proc, sessions: [Session]) -> String? {
        if p.path.hasSuffix("Claude.app/Contents/MacOS/Claude") { return "This is the Claude desktop app: every desktop session closes with it." }
        if p.name == "claude" { return "This is a Claude Code session process; quitting it ends that session mid-turn." }
        if p.name.hasPrefix("qemu-system") { return "This is an Android emulator. Prefer Shut Down on the Emulators tab." }
        if let s = p.session, let x = sessions.first(where: { $0.id == s }), x.isWorking { return "\(x.title) is working right now and started this process." }
        return nil
    }
}

enum Fmt {
    private static let byteFmt: ByteCountFormatter = { let f = ByteCountFormatter(); f.countStyle = .memory; f.allowsNonnumericFormatting = false; return f }()
    static func bytes<T: BinaryInteger>(_ b: T) -> String { byteFmt.string(fromByteCount: Int64(b)) }   // "0 bytes", never "Zero KB"
    static func rate(_ b: Double) -> String { b < 1024 ? "0 KB/s" : ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file) + "/s" }
    static func pct(_ v: Double) -> String { String(format: v >= 100 ? "%.0f%%" : "%.1f%%", v) }
    static let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
    /// A process's CPU (ps reports 100% per busy core) as a share of the whole machine, the same
    /// scale as the CPU figure at the top: 100% = every core busy.
    static func cpu(_ perCore: Double) -> String { pct(perCore / cores) }
    /// The same amount as a count of busy cores, e.g. "1.1 cores".
    static func coresUsed(_ perCore: Double) -> String { String(format: perCore >= 1000 ? "%.0f cores" : "%.1f cores", perCore / 100) }
    static func ago(_ d: Date?) -> String {
        guard let d else { return "—" }
        let s = Date().timeIntervalSince(d)
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        if s < 86400 { return String(format: "%.1f h ago", s / 3600) }
        return "\(Int(s / 86400)) d ago"
    }
    static func age(_ s: TimeInterval?) -> String { ago(s.map { Date().addingTimeInterval(-$0) }) }
}
