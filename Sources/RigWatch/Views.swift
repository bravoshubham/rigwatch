import SwiftUI

enum Views {
    static func pressureName(_ p: Int32) -> String { p >= 4 ? "Critical" : p >= 2 ? "Warning" : "Normal" }
    static func pressureColor(_ p: Int32) -> Color { p >= 4 ? Color(hex: 0xFF4D5E) : p >= 2 ? Color(hex: 0xFF8A3D) : Color(hex: 0x3DDC97) }
    static func tilde(_ p: String) -> String { p.replacingOccurrences(of: Sh.home, with: "~") }
    static func short(_ activity: String) -> (app: String, screen: String) {
        // "com.example.app/com.example.app.MainActivity" -> ("com.example.app", "MainActivity")
        let parts = activity.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return (activity, "") }
        return (parts[0], parts[1].split(separator: ".").last.map(String.init) ?? parts[1])
    }
}

/// macOS's thermal state in plain words: what the machine is actually doing about the heat.
func thermalName(_ t: ProcessInfo.ThermalState) -> String {
    switch t { case .nominal: "Cool"; case .fair: "Warm"; case .serious: "Hot · slowing"; case .critical: "Overheating"; @unknown default: "?" }
}
func thermalHint(_ t: ProcessInfo.ThermalState) -> String {
    switch t {
    case .nominal: "Running cool. Full speed."
    case .fair: "Warm. Fans are working harder; no slowdown yet."
    case .serious: "Hot. macOS is slowing the chip to cool it down."
    case .critical: "Overheating. macOS is slowing the chip hard."
    @unknown default: ""
    }
}
func thermalColor(_ t: ProcessInfo.ThermalState) -> Color {
    switch t { case .nominal: Color(hex: 0x3DDC97); case .fair: Color(hex: 0xFFB020); case .serious: Color(hex: 0xFF8A3D); default: Color(hex: 0xFF4D5E) }
}
func tempText(_ s: SysSnapshot) -> String { s.tempMax.map { String(format: "%.0f°C", $0) } ?? "—" }

extension String { func ifEmpty(_ s: String) -> String { isEmpty ? s : self } }

// MARK: Shell

struct RootView: View {
    @ObservedObject private var m = Monitor.shared
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
            Rectangle().fill(HUD(scheme: scheme).line).frame(width: 0.8)
            VStack(spacing: 0) {
                if let v = m.updateReady {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.down.circle.fill").foregroundStyle(Aspect.worktree.color)
                        Text("RigWatch \(v) is installed. Restart to use it.").font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Button("Restart") { AppCopy.restartIntoNewest() }.buttonStyle(HUDButton(color: Aspect.worktree.color, filled: true))
                    }.padding(.horizontal, 16).padding(.vertical, 8).background(Aspect.worktree.color.opacity(0.12))
                }
                TelemetryBar()
                Rectangle().fill(HUD(scheme: scheme).line).frame(height: 0.8)
                Group {
                    switch m.tab {
                    case .overview: OverviewView()
                    case .devices: DevicesView()
                    case .deviceManager: DeviceManagerView()
                    case .builds: BuildsView()
                    case .sessions: SessionsView()
                    case .servers: DevServersView()
                    case .processes: ProcessesView()
                    case .memory: MemoryView()
                    case .worktrees: WorktreesView()
                    case .disk: DiskView()
                    case .rules: RulesView()
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(GridBackground())
        .alert(m.pending?.title ?? "", isPresented: Binding(get: { m.pending != nil }, set: { if !$0 { m.pending = nil } }), presenting: m.pending) { p in
            if p.blocked {
                Button("OK") {}
            } else {
                Button(p.button, role: .destructive) { m.perform(p.title, p.run) }
                Button("Cancel", role: .cancel) {}
            }
        } message: { p in Text(p.message) }
        .sheet(isPresented: Binding(get: { m.liveView != nil }, set: { if !$0 { m.liveView = nil } })) {
            if let d = m.liveView { LiveView(device: d) }
        }
        .overlay {
            // Top CPU / Top memory: an overlay, not a sheet, so the confirmations behind its actions can show.
            if m.top != nil {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea().onTapGesture { m.top = nil }
                    TopSheet()
                }
            }
        }
        .overlay(alignment: .top) { ActionBar().padding(.top, 8) }
        .overlay(alignment: .bottom) {
            if let t = m.toast {
                Text(t).font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Rectangle().fill(HUD(scheme: scheme).panel))
                    .overlay(Rectangle().strokeBorder(HUD(scheme: scheme).accent.opacity(0.6), lineWidth: 0.8))
                    .overlay(Brackets(len: 7).stroke(HUD(scheme: scheme).accent, lineWidth: 1.4))
                    .padding(22)
                    .onTapGesture { m.toast = nil }
                    .task(id: t) { try? await Task.sleep(for: .seconds(6)); if m.toast == t { m.toast = nil } }
            }
        }
    }
}

struct Sidebar: View {
    @ObservedObject private var m = Monitor.shared
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("interval") private var interval = 5
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let hud = HUD(scheme: scheme)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Rectangle().fill(LinearGradient(colors: [hud.accent, hud.accent2], startPoint: .top, endPoint: .bottom)).frame(width: 4, height: 18)
                    Text("RIGWATCH").font(.system(size: 15, weight: .heavy, design: .monospaced)).tracking(3)
                }
                Text("workstation telemetry").hudLabel()
            }.padding(.leading, 18).padding(.top, 18).padding(.bottom, 22)

            ForEach(Page.allCases) { p in
                let on = m.tab == p
                Button { m.tab = p; m.refresh(worktreesNow: p == .worktrees && m.worktrees.isEmpty) } label: {
                    HStack(spacing: 11) {
                        Rectangle().fill(on ? p.aspect.color : .clear).frame(width: 2.5, height: 18)
                        Image(systemName: p.aspect.icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(on ? p.aspect.color.readable(scheme) : .secondary).frame(width: 18)
                        Text(p.rawValue).font(.system(size: 12, weight: on ? .semibold : .regular)).foregroundStyle(on ? .primary : .secondary).lineLimit(1)
                        Spacer()
                        if let b = badge(p) { Text(b).font(.system(size: 9.5, weight: .bold, design: .monospaced)).foregroundStyle(p.aspect.color.readable(scheme)) }
                    }
                    .padding(.vertical, 8).padding(.trailing, 14)
                    .background(on ? LinearGradient(colors: [p.aspect.color.opacity(0.14), .clear], startPoint: .leading, endPoint: .trailing) : LinearGradient(colors: [.clear], startPoint: .leading, endPoint: .trailing))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                Text("Appearance").hudLabel()
                HStack(spacing: 0) {
                    ForEach([("system", "circle.lefthalf.filled"), ("light", "sun.max"), ("dark", "moon")], id: \.0) { k, icon in
                        Button { appearance = k } label: {
                            Image(systemName: icon).font(.system(size: 11)).frame(maxWidth: .infinity).padding(.vertical, 6)
                                .foregroundStyle(appearance == k ? hud.accent.readable(scheme) : .secondary)
                                .background(Rectangle().fill(appearance == k ? hud.accent.opacity(0.14) : .clear))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).help(k.capitalized)
                    }
                }.overlay(Rectangle().strokeBorder(hud.line, lineWidth: 0.8))
                Text("Refresh every").hudLabel()
                HStack(spacing: 0) {
                    ForEach([3, 5, 10], id: \.self) { n in
                        Button { interval = n } label: {
                            Text("\(n)s").font(.system(size: 10.5, weight: .semibold, design: .monospaced)).frame(maxWidth: .infinity).padding(.vertical, 5)
                                .foregroundStyle(interval == n ? hud.accent.readable(scheme) : .secondary)
                                .background(Rectangle().fill(interval == n ? hud.accent.opacity(0.14) : .clear)).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }.overlay(Rectangle().strokeBorder(hud.line, lineWidth: 0.8))
                Text("RigWatch load").hudLabel()
                HStack(spacing: 6) {
                    Chip(text: Fmt.cpu(m.selfCPU), icon: "cpu", color: Aspect.cpu.color)
                    Chip(text: Fmt.bytes(m.selfMem), icon: "memorychip", color: Aspect.memory.color)
                }
                Text("Version \(AppCopy.ownVersion)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    .textSelection(.enabled).help("The RigWatch version this window is running")
            }.padding(16)
        }
        .frame(width: 228)
        .background(Rectangle().fill(hud.bg.opacity(0.75)))
    }
    func badge(_ p: Page) -> String? {
        switch p {
        case .devices: let n = m.emulatorCount + m.simulatorCount; return n > 0 ? String(format: "%02d", n) : nil
        case .deviceManager: let n = m.leases.count; return n > 0 ? String(format: "%02d", n) : nil
        case .builds: let n = m.jobs.count + m.outside.count; return n > 0 ? String(format: "%02d", n) : nil
        case .sessions: let n = m.sessions.filter(\.live).count; return n > 0 ? String(format: "%02d", n) : nil
        case .worktrees: let n = m.worktrees.filter { !$0.isMain }.count; return n > 0 ? String(format: "%02d", n) : nil
        case .servers: let n = m.servers.count; return n > 0 ? String(format: "%02d", n) : nil
        default: return nil
        }
    }
}

/// Always-visible strip of live numbers, one cell per area. Each cell opens its tab.
struct TelemetryBar: View {
    @ObservedObject private var m = Monitor.shared
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let s = m.sys, hud = HUD(scheme: scheme)
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(m.tab.rawValue).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                HStack(spacing: 5) { Dot(color: Color(hex: 0x3DDC97)); Text("live · \(m.windowVisible ? m.interval : 60) s").hudLabel() }
            }.frame(width: 150, alignment: .leading).padding(.leading, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    cell(.processes, "CPU", "\(Int(s.cpu))", "%", Heat.ratio(s.cpu / 100), s.cpu / 100, top: .cpu).help("What is using the CPU right now")
                    cell(.memory, "MEM", Fmt.bytes(s.memUsed), "", Views.pressureColor(s.pressure), Double(s.memUsed) / Double(max(s.memTotal, 1)), top: .memory).help("What is using memory right now")
                    cell(.overview, "GPU", "\(s.gpu)", "%", Aspect.gpu.color, Double(s.gpu) / 100)
                    cell(.disk, "DISK I/O", Fmt.rate(s.diskRead + s.diskWrite), "", Aspect.disk.color, nil)
                    cell(.overview, "NET", Fmt.rate(s.netIn + s.netOut), "", Aspect.network.color, nil)
                    cell(.devices, "DEVICES", "\(m.emulatorCount)+\(m.simulatorCount)", "", Aspect.android.color, nil)
                    cell(.sessions, "SESSIONS", "\(m.sessions.filter(\.live).count)", "\(m.sessions.filter(\.isWorking).count) active", Aspect.claude.color, nil)
                    cell(.overview, "CHIP TEMP", tempText(s), thermalName(s.thermal), thermalColor(s.thermal), s.tempMax.map { min(1, max(0, ($0 - 30) / 75)) })
                        .help(thermalHint(s.thermal) + (s.tempAvg.map { String(format: "\nAverage across sensors %.0f°C", $0) } ?? ""))
                }
            }
            Button { m.refresh(worktreesNow: m.tab == .worktrees) } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(HUDButton(color: hud.accent)).padding(.horizontal, 16).help("Refresh now")
        }
        .frame(height: 74)
        .background(hud.bg.opacity(0.6))
    }

    func cell(_ t: Page, _ label: String, _ value: String, _ unit: String, _ color: Color, _ ratio: Double?, top: TopKind? = nil) -> some View {
        Button { if let top { m.top = top } else { m.tab = t; m.refresh(worktreesNow: t == .worktrees && m.worktrees.isEmpty) } } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(label).hudLabel().lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value).font(.system(size: 17, weight: .regular, design: .rounded)).monospacedDigit().foregroundStyle(color.readable(scheme))
                    if !unit.isEmpty { Text(unit).font(.system(size: 9.5, weight: .medium, design: .monospaced)).foregroundStyle(.secondary) }
                }.lineLimit(1).fixedSize()
                if let ratio { Meter(value: ratio, color: color, height: 2.5).frame(width: 74) } else { Spacer().frame(height: 2.5) }
            }
            .padding(.horizontal, 16).frame(minWidth: 96, alignment: .leading)
            .overlay(alignment: .leading) { Rectangle().fill(HUD(scheme: scheme).line).frame(width: 0.8, height: 36) }
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

// MARK: Overview

struct OverviewView: View {
    @ObservedObject private var m = Monitor.shared
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let s = m.sys
        let memRatio = Double(s.memUsed) / Double(max(s.memTotal, 1))
        let emu = m.groups.first { $0.name == "Android emulators" }, sim = m.groups.first { $0.name == "iOS simulators" }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if m.hotStreak >= 2 && !m.bannerDismissed, let mo = m.history.last(where: { !$0.topCPU.isEmpty }) { HotBanner(moment: mo) }
                SectionTitle(title: "What is using the machine", aspect: .gpu)
                ProcessDie()

                SpikeTimeline()

                FreeList()

                SectionTitle(title: "Instruments", aspect: .cpu)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14)], spacing: 14) {
                    Gauge(aspect: .cpu, label: "Processor", value: s.cpu / 100, big: "\(Int(s.cpu))", unit: "%", color: Heat.ratio(s.cpu / 100), open: { m.top = .cpu }) {
                        Chip(text: "LOAD \(String(format: "%.0f", s.load.0))", color: Aspect.cpu.color)
                        Chip(text: "\(s.cores.count) CORES", color: Aspect.process.color)
                    }
                    Gauge(aspect: .memory, label: "Memory", value: memRatio, big: "\(Int(memRatio * 100))", unit: "%", color: Aspect.memory.color, open: { m.top = .memory }) {
                        Chip(text: Views.pressureName(s.pressure).uppercased(), color: Views.pressureColor(s.pressure), filled: s.pressure >= 2)
                        Chip(text: "SWAP \(Fmt.bytes(s.swapUsed))", color: Aspect.process.color)
                    }
                    Gauge(aspect: .gpu, label: "Graphics", value: Double(s.gpu) / 100, big: "\(s.gpu)", unit: "%", color: Aspect.gpu.color) {
                        Chip(text: "VRAM \(Fmt.bytes(s.gpuMem))", color: Aspect.gpu.color)
                        if let top = m.gpuUsers.first, top.gpu >= 1 { Chip(text: "\(top.name.uppercased()) \(Int(top.gpu.rounded()))%", color: Aspect.gpu.color).help("Uses the most GPU time right now") }
                    }
                    ForEach(s.volumes) { v in
                        let r = Double(v.used) / Double(max(v.total, 1))
                        Gauge(aspect: .disk, label: v.name, value: r, big: "\(Int(r * 100))", unit: "%", color: Heat.ratio(r)) {
                            Chip(text: "\(Fmt.bytes(v.free)) FREE", color: Aspect.disk.color)
                        }
                    }
                }

                SectionTitle(title: "Fleet", aspect: .android)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14)], spacing: 14) {
                    Tile(aspect: .android, label: "Emulators & simulators", value: "\(m.emulatorCount + m.simulatorCount)", page: .devices) {
                        Chip(text: "\(m.emulatorCount) ANDROID", color: Aspect.android.color)
                        Chip(text: "\(m.simulatorCount) IOS", color: Aspect.ios.color)
                        Chip(text: "CPU \(Fmt.cpu((emu?.cpu ?? 0) + (sim?.cpu ?? 0)))", color: Heat.cpu((emu?.cpu ?? 0) + (sim?.cpu ?? 0)))
                        Chip(text: Fmt.bytes((emu?.mem ?? 0) + (sim?.mem ?? 0)), color: Aspect.memory.color)
                    }
                    Tile(aspect: .claude, label: "Agent sessions", value: "\(m.sessions.filter(\.live).count)", page: .sessions) {
                        Chip(text: "\(m.sessions.filter(\.isWorking).count) WORKING", icon: "bolt.fill", color: Color(hex: 0x3DDC97))
                        Chip(text: "CPU \(Fmt.cpu(m.sessions.reduce(0) { $0 + $1.cpu }))", color: Heat.cpu(m.sessions.reduce(0) { $0 + $1.cpu }))
                        Chip(text: Fmt.bytes(m.sessions.reduce(UInt64(0)) { $0 + $1.mem }), color: Aspect.memory.color)
                    }
                    Tile(aspect: .worktree, label: "Worktrees", value: "\(m.worktrees.filter { !$0.isMain }.count)", page: .worktrees) {
                        Chip(text: "\(m.idleWorktrees) IDLE >1D", color: Color(hex: 0xFFD23F))
                        Chip(text: "\(Set(m.worktrees.map(\.repo)).count) REPOS", color: Aspect.process.color)
                    }
                    Tile(aspect: .network, label: "Network", value: Fmt.rate(s.netIn + s.netOut), page: .overview) {
                        Chip(text: "↓ \(Fmt.rate(s.netIn))", color: Aspect.network.color)
                        Chip(text: "↑ \(Fmt.rate(s.netOut))", color: Aspect.network.color)
                        Chip(text: "CHIP \(tempText(s)) · \(thermalName(s.thermal).uppercased())", icon: "thermometer.medium", color: thermalColor(s.thermal)).help(thermalHint(s.thermal))
                    }
                }

                HStack(alignment: .top, spacing: 14) {
                    RankPanel(title: "CPU consumers · % of whole machine", aspect: .cpu, rows: m.groups.sorted { $0.cpu > $1.cpu }.prefix(8).map { ($0.name, $0.cpu / max(1, m.groups.map(\.cpu).max() ?? 1), Fmt.cpu($0.cpu), $0.count) })
                    RankPanel(title: "Memory consumers", aspect: .memory, rows: m.groups.sorted { $0.mem > $1.mem }.prefix(8).map { ($0.name, Double($0.mem) / Double(max(1, m.groups.map(\.mem).max() ?? 1)), Fmt.bytes($0.mem), $0.count) })
                }
                let gpu = m.gpuUsers.filter { $0.gpu >= 0.5 }.prefix(8)
                RankPanel(title: "GPU users · % of GPU time", aspect: .gpu, rows: gpu.map { ($0.name, $0.gpu / max(1, gpu.first?.gpu ?? 1), String(format: "%.1f%%", $0.gpu), $0.count) })
                    .help("Time each process kept the GPU busy, from the graphics driver's own counters. WindowServer draws the screen, so it is always there; apps with animations or video keep the GPU busy even when idle.")
            }.padding(20)
        }
    }
}

/// The machine as a chip: each block is a process group, sized by memory (or CPU), lit by its CPU load.
/// Click a block to see inside it: a group opens into its processes, "smaller items" into what it holds,
/// A process opens in the Processes tab. Only what is using memory is on the map: what is still
/// available (free, file cache, purgeable) is the bar under it.
struct ProcessDie: View {
    @ObservedObject private var m = Monitor.shared
    @Environment(\.colorScheme) private var scheme
    @State private var byCPU = false
    @State private var hover: String?
    // -drill <group> opens the die inside that group (used to capture screenshots).
    @State private var path: [String] = CommandLine.arguments.firstIndex(of: "-drill").map { ["g:" + CommandLine.arguments[$0 + 1]] } ?? []   // "g:<group>" · "groups:<names>" · "procs:<pids>"
    static let sep = "\u{1}"

    func amount(_ cpu: Double, _ mem: UInt64) -> Int64 { Int64(byCPU ? cpu * 1000 : Double(mem)) }

    func groupBlock(_ g: ProcGroup) -> StorageDie.Block {
        .init(id: "g:" + g.name, label: g.name, bytes: amount(g.cpu, g.mem), color: Aspect.forGroup(g.name).color, path: nil, kind: 0,
              value: byCPU ? Fmt.cpu(g.cpu) : Fmt.bytes(g.mem),
              caption: byCPU ? "\(Fmt.coresUsed(g.cpu)) · \(Fmt.bytes(g.mem))" : "CPU \(Fmt.cpu(g.cpu)) · ×\(g.count)", heat: min(1, g.cpu / 400))
    }
    func procBlock(_ p: Proc) -> StorageDie.Block {
        .init(id: "p:\(p.pid)", label: p.name, bytes: amount(p.cpu, p.mem), color: Aspect.forGroup(p.group).color, path: nil, kind: 0,
              value: byCPU ? Fmt.cpu(p.cpu) : Fmt.bytes(p.mem),
              caption: "pid \(p.pid) · " + (byCPU ? Fmt.bytes(p.mem) : "CPU \(Fmt.cpu(p.cpu))"), heat: min(1, p.cpu / 400))
    }

    /// The blocks for the current level, largest first, and the ids they were picked from.
    func level() -> (blocks: [StorageDie.Block], title: String) {
        let s = m.sys
        let key = path.last ?? ""
        if key.hasPrefix("g:") {
            let name = String(key.dropFirst(2))
            return (m.procs.filter { $0.group == name }.map(procBlock).filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }, name)
        }
        if key.hasPrefix("procs:") {
            let pids = Set(key.dropFirst(6).components(separatedBy: Self.sep).compactMap { Int32($0) })
            return (m.procs.filter { pids.contains($0.pid) }.map(procBlock).filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }, "\(pids.count) smaller items")
        }
        if key.hasPrefix("groups:") {
            let names = Set(key.dropFirst(7).components(separatedBy: Self.sep))
            return (m.groups.filter { names.contains($0.name) }.map(groupBlock).filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }, "\(names.count) smaller items")
        }
        // Top level: every group, plus the system's own pieces.
        var b = m.groups.map(groupBlock).filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
        if !byCPU {
            b.append(.init(id: "wired", label: "Kernel & drivers", bytes: Int64(s.memKernel), color: Color(hex: 0xFFB020), path: nil, kind: 1, value: Fmt.bytes(s.memKernel),
                           caption: s.gpuMem >= 1 << 30 ? "wired, less \(Fmt.bytes(s.gpuMem)) of GPU memory" : "wired: can't be paged out"))
        }
        return (b, "")
    }

    func title(_ key: String) -> String {
        if key.hasPrefix("g:") { return String(key.dropFirst(2)) }
        let n = key.split(separator: ":", maxSplits: 1).last.map { $0.components(separatedBy: Self.sep).count } ?? 0
        return "\(n) smaller items"
    }

    func tap(_ blk: StorageDie.Block, shown: [StorageDie.Block], all: [StorageDie.Block]) {
        let key = path.last ?? ""
        switch blk.id {
        case "rest":
            let shownIds = Set(shown.map(\.id))
            let rest = all.filter { $0.kind == 0 && !shownIds.contains($0.id) }.map { String($0.id.dropFirst(2)) }
            let groupsLevel = key.isEmpty || key.hasPrefix("groups:")
            path.append((groupsLevel ? "groups:" : "procs:") + rest.joined(separator: Self.sep))
        case "wired": m.toast = "Kernel & drivers: wired memory less the GPU's \(Fmt.bytes(m.sys.gpuMem)). GPU memory is counted in the app that allocated it (a local model's weights are in its own block). The rest can't be broken down: macOS doesn't show apps what's inside it."
        default:
            if blk.id.hasPrefix("g:") { path.append(blk.id) }
            else if blk.id.hasPrefix("p:") { m.procSearch = String(blk.id.dropFirst(2)); m.tab = .processes }
        }
    }

    var body: some View {
        let s = m.sys
        let lv = level()
        let all = lv.blocks
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Button(s.gpuModel) { path = [] }.buttonStyle(HUDButton(color: Aspect.gpu.color, filled: path.isEmpty))
                ForEach(Array(path.enumerated()), id: \.offset) { i, k in
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    Button(title(k)) { path = Array(path.prefix(i + 1)) }.buttonStyle(HUDButton(color: Aspect.gpu.color, filled: i == path.count - 1))
                }
                Text(byCPU ? "sized by CPU · 100% = whole machine (\(s.cores.count) cores)" : "sized by memory · \(Fmt.bytes(s.memUsed)) of \(Fmt.bytes(s.memTotal)) used").hudLabel().lineLimit(1).padding(.leading, 6)
                Spacer(minLength: 8)
                HStack(spacing: 0) {
                    Button("Memory") { byCPU = false }.buttonStyle(HUDButton(color: Aspect.memory.color, filled: !byCPU))
                    Button("CPU") { byCPU = true }.buttonStyle(HUDButton(color: Aspect.cpu.color, filled: byCPU))
                }
            }
            GeometryReader { g in
                let outer = CGRect(origin: .zero, size: g.size)
                let laid = Fit.fold(all, in: outer.insetBy(dx: 22, dy: 22), restPath: nil, restValue: { byCPU ? Fmt.cpu(Double($0) / 1000) : Fmt.bytes(UInt64($0)) })
                let total = Double(laid.blocks.reduce(Int64(0)) { $0 + $1.bytes })
                ZStack(alignment: .topLeading) {
                    ChipPins().stroke(LinearGradient(colors: [Color(hex: 0x2EE6D6), Color(hex: 0x2F80ED)], startPoint: .topLeading, endPoint: .bottomTrailing).opacity(0.6), lineWidth: 1)
                    Rectangle().strokeBorder(LinearGradient(colors: [Color(hex: 0x2EE6D6), Color(hex: 0x2F80ED)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 2).padding(10)
                    if all.isEmpty { Text("Nothing here right now").hudLabel().frame(width: g.size.width, height: g.size.height) }
                    ForEach(Array(zip(laid.blocks, laid.rects)), id: \.0.id) { blk, r in
                        DieBlock(block: blk, share: Double(blk.bytes) / max(total, 1), highlighted: hover == blk.id)
                            .frame(width: max(0, r.width - 4), height: max(0, r.height - 4))
                            .position(x: r.midX, y: r.midY)
                            .onHover { hover = $0 ? blk.id : (hover == blk.id ? nil : hover) }
                            .onTapGesture { tap(blk, shown: laid.blocks, all: all) }
                    }
                }
            }
            .frame(height: 380)
            if !byCPU && path.isEmpty { AvailableBar() }
            // Inside a group: its biggest processes as a list, explained, since most fold into "smaller items".
            if path.last?.hasPrefix("g:") == true || path.last?.hasPrefix("procs:") == true {
                let list = all.compactMap { b in m.procs.first { "p:\($0.pid)" == b.id }.map { (b, $0) } }.prefix(6)
                Panel(aspect: .gpu, padding: 10) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Biggest inside \(title(path.last!)) · by \(byCPU ? "CPU" : "memory")").hudLabel(Aspect.gpu.color.readable(scheme))
                        ForEach(list, id: \.0.id) { b, p in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 8) {
                                    Text(b.value ?? "").font(.system(size: 11, weight: .semibold, design: .monospaced)).monospacedDigit().frame(width: 76, alignment: .trailing)
                                    Text(p.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                                    Text("pid \(p.pid) · \(m.owner(p))").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                if let e = Explain.of(p) { ExplainLine(e: e).padding(.leading, 84) }
                            }
                            .background(Rectangle().fill(hover == b.id ? Aspect.gpu.color.opacity(0.08) : .clear))
                            .onHover { hover = $0 ? b.id : (hover == b.id ? nil : hover) }
                        }
                    }
                }
            }
            Text(path.last?.hasPrefix("g:") == true || path.last?.hasPrefix("procs:") == true
                 ? "Click a process to open it in Processes. Hover one to see what it is."
                 : "Click a block to see what's inside it.").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
        }
    }
}

/// What is still available to apps, as a thin bar beside what is used: free, file cache and purgeable
/// app caches, which macOS hands back as soon as something needs the room.
struct AvailableBar: View {
    @ObservedObject private var m = Monitor.shared
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let s = m.sys
        let cache = s.memCached - min(s.memCached, s.memPurgeable)
        let parts: [(String, UInt64, Color)] = [("used", s.memUsed, Aspect.memory.color), ("file cache", cache, Aspect.disk.color),
                                                ("purgeable", s.memPurgeable, Color(hex: 0xA78BFA)), ("free", s.memFree, Color(hex: 0x3DDC97))]
        let total = Double(max(1, parts.reduce(UInt64(0)) { $0 + $1.1 }))
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Text("Available \(Fmt.bytes(s.memFree + s.memCached))").font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(Color(hex: 0x3DDC97).readable(scheme))
                ForEach(parts.dropFirst(), id: \.0) { p in
                    HStack(spacing: 4) { Rectangle().fill(p.2).frame(width: 7, height: 7); Text("\(p.0) \(Fmt.bytes(p.1))").hudLabel() }
                }
                Spacer()
                if s.gpuMem >= 1 << 30 {
                    Text("GPU memory \(Fmt.bytes(s.gpuMem)): in the blocks of the apps using it").hudLabel(Aspect.gpu.color.readable(scheme)).lineLimit(1)
                        .help("GPU memory in use is wired. Your own processes' GPU buffers are part of their footprint, so they are counted in their blocks and taken out of Kernel & drivers.")
                } else {
                    Text("not on the map: macOS gives it to apps as soon as they need it").hudLabel().lineLimit(1)
                }
            }
            GeometryReader { g in
                HStack(spacing: 1) {
                    ForEach(parts, id: \.0) { p in
                        Rectangle().fill(p.2.opacity(p.0 == "used" ? 0.35 : 0.85)).frame(width: max(0, CGFloat(Double(p.1) / total) * (g.size.width - 3)))
                    }
                }
            }.frame(height: 5)
        }
        .help("Used \(Fmt.bytes(s.memUsed)) · file cache \(Fmt.bytes(cache)) · purgeable \(Fmt.bytes(s.memPurgeable)) · free \(Fmt.bytes(s.memFree))")
    }
}

/// Pins around the die edge, like a package outline.
struct ChipPins: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let step: CGFloat = 16, len: CGFloat = 8
        for x in stride(from: r.minX + 24, through: r.maxX - 24, by: step) {
            p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.minY + len))
            p.move(to: CGPoint(x: x, y: r.maxY)); p.addLine(to: CGPoint(x: x, y: r.maxY - len))
        }
        for y in stride(from: r.minY + 24, through: r.maxY - 24, by: step) {
            p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.minX + len, y: y))
            p.move(to: CGPoint(x: r.maxX, y: y)); p.addLine(to: CGPoint(x: r.maxX - len, y: y))
        }
        return p
    }
}

struct Gauge<Extra: View>: View {
    let aspect: Aspect
    let label: String
    let value: Double
    let big: String
    let unit: String
    let color: Color
    var open: (() -> Void)? = nil      // a gauge that opens its Top list when clicked
    @ViewBuilder var extra: Extra
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let panel = Panel(aspect: aspect) {
            HStack(spacing: 14) {
                ZStack {
                    Ring(value: value, color: color.readable(scheme))
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text(big).hudNumber(22)
                        Text(unit).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }.frame(width: 92, height: 92)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(label).hudLabel(aspect.color.readable(scheme)).lineLimit(1)
                        if open != nil { Spacer(); Text("top users").hudLabel(); Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary) }
                    }
                    FlowChips { extra }
                }
                Spacer(minLength: 0)
            }
        }
        if let open { Button(action: open) { panel.contentShape(Rectangle()) }.buttonStyle(.plain) } else { panel }
    }
}

struct Tile<Extra: View>: View {
    let aspect: Aspect
    let label: String
    let value: String
    let page: Page
    @ViewBuilder var extra: Extra
    @ObservedObject private var m = Monitor.shared
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Button { m.tab = page; m.refresh(worktreesNow: page == .worktrees) } label: {
            Panel(aspect: aspect) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text(label).hudLabel(aspect.color.readable(scheme)).lineLimit(1); Spacer(); Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary) }
                    Text(value).hudNumber(30)
                    FlowChips { extra }
                }
            }
        }.buttonStyle(.plain)
    }
}

/// Lays chips out left to right, wrapping onto new lines.
struct FlowChips<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { WrapLayout(spacing: 5) { content } }
}

struct WrapLayout: Layout {
    var spacing: CGFloat = 5
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > w, x > 0 { x = 0; y += row + spacing; row = 0 }
            x += s.width + spacing; row = max(row, s.height)
        }
        return CGSize(width: w, height: y + row)
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = b.minX, y = b.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > b.maxX, x > b.minX { x = b.minX; y += row + spacing; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; row = max(row, s.height)
        }
    }
}

struct RankPanel: View {
    let title: String
    let aspect: Aspect
    let rows: [(String, Double, String, Int)]
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Panel(aspect: aspect) {
            VStack(alignment: .leading, spacing: 9) {
                Text(title).hudLabel(aspect.color.readable(scheme))
                ForEach(Array(rows.enumerated()), id: \.element.0) { i, r in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(String(format: "%02d", i + 1)).font(.system(size: 9.5, weight: .bold, design: .monospaced)).foregroundStyle(.tertiary)
                            Image(systemName: Aspect.forGroup(r.0).icon).font(.system(size: 10)).foregroundStyle(Aspect.forGroup(r.0).color.readable(scheme)).frame(width: 14)
                            Text(r.0).font(.system(size: 12)).lineLimit(1)
                            Spacer()
                            if r.3 > 1 { Text("×\(r.3)").font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.tertiary) }
                            Text(r.2).font(.system(size: 12, weight: .semibold, design: .monospaced)).monospacedDigit().lineLimit(1).fixedSize()
                        }
                        Meter(value: r.1, color: aspect.color, height: 3, segments: 40)
                    }
                }
                if rows.isEmpty { Text("Nothing yet").hudLabel() }
            }
        }
    }
}

// MARK: Devices

struct DevicesView: View {
    @ObservedObject private var m = Monitor.shared
    var body: some View {
        let emus = m.devices.filter { $0.kind == .emulator }.sorted { $0.cpu > $1.cpu }
        let sims = m.devices.filter { $0.kind == .simulator }.sorted { $0.cpu > $1.cpu }
        let phones = m.devices.filter { $0.kind == .phone }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("Android emulators", .android, emus)
                section("iOS simulators", .ios, sims)
                if !phones.isEmpty { section("Physical devices", .process, phones) }
                Text("Launched by = the session in the emulator's own environment. Used by = sessions whose transcript named the device in the last 3 h. Click a session to open it in Claude.")
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
            }.padding(20)
        }
        .overlay { if m.devices.isEmpty { ProgressView().controlSize(.small) } }
    }

    @ViewBuilder func section(_ title: String, _ a: Aspect, _ list: [Device]) -> some View {
        SectionTitle(title: title, aspect: a, count: list.count)
        if list.isEmpty {
            Text(a == .ios ? "No simulator booted" : "None running").hudLabel().padding(.leading, 14)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 420), spacing: 14)], spacing: 14) {
                ForEach(list) { DeviceCard(d: $0) }
            }
        }
    }
}

struct DeviceCard: View {
    @ObservedObject private var m = Monitor.shared
    @Environment(\.colorScheme) private var scheme
    let d: Device
    var aspect: Aspect { d.kind == .simulator ? .ios : d.kind == .emulator ? .android : .process }
    var body: some View {
        let working = d.recentUsers.keys.compactMap { m.session($0) }.filter(\.isWorking)
        Panel(aspect: aspect) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    IconBadge(aspect: aspect, size: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(d.name).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                        Text([d.kind.rawValue, d.serial, d.detail.isEmpty ? nil : d.detail].compactMap { $0 }.joined(separator: " · ")).hudLabel().lineLimit(1)
                    }
                    Spacer()
                    HStack(spacing: 6) { Dot(color: Heat.status(d.state)); Text(d.state == "device" ? "online" : d.state).hudLabel(Heat.status(d.state)) }.fixedSize()
                }
                HStack(spacing: 22) {
                    Readout(label: "CPU", value: Fmt.cpu(d.cpu), color: Heat.cpu(d.cpu).readable(scheme), size: 22)
                    Readout(label: "Memory", value: Fmt.bytes(d.mem), color: Aspect.memory.color.readable(scheme), size: 22)
                    if let s = d.started { Readout(label: "Uptime", value: Fmt.ago(s).replacingOccurrences(of: " ago", with: ""), size: 22) }
                    if !d.guestLoad.isEmpty { Readout(label: "Guest load", value: String(d.guestLoad.split(separator: " ").first ?? ""), size: 22) }
                }
                Meter(value: min(1, d.cpu / 800), color: Heat.cpu(d.cpu), height: 4, segments: 48)
                if !d.foreground.isEmpty || !d.screen.isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        Text("ON SCREEN").hudLabel(aspect.color.readable(scheme)).fixedSize().frame(width: 74, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            if d.kind == .simulator { Text(d.foreground.ifEmpty("Home screen")).font(.system(size: 12.5, weight: .medium)).lineLimit(1) }
                            else {
                                let x = Views.short(d.foreground)
                                Text(x.screen.ifEmpty(x.app.ifEmpty("—"))).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                if !x.screen.isEmpty { Text(x.app).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1) }
                            }
                        }
                        Spacer()
                        if !d.screen.isEmpty { Chip(text: d.screen.uppercased(), icon: d.screen == "Awake" ? "sun.max" : "moon", color: d.screen == "Awake" ? Color(hex: 0xFFD23F) : Aspect.process.color).fixedSize() }
                        if d.headless { Chip(text: "HEADLESS", icon: "eye.slash", color: Aspect.process.color).fixedSize() }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    if let l = d.lease {
                        HStack(spacing: 6) {
                            Chip(text: l.isImplicit ? "IN USE" : "LEASED", icon: l.isImplicit ? "hand.raised.fill" : "key.fill", color: Color(hex: l.isImplicit ? 0xFF8A3D : 0x3DDC97)).fixedSize()
                            SessionLink(id: l.session)
                            Text(l.isImplicit ? "used directly, not through the device manager" : "until \(Leases.time(l.until))\(l.purpose.isEmpty ? "" : " · " + l.purpose)")
                                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                        }.help("Lent to this agent session by RigWatch's device manager (MCP acquire_device). No other session is given it and the clean-up leaves it alone until the lease ends.")
                    }
                    if let c = d.claim {
                        HStack(spacing: 6) {
                            Chip(text: "HELD BY AGENT-DEVICE", icon: "lock.fill", color: Color(hex: 0xFFD23F)).fixedSize()
                            Text("session \(c.session) · \(Views.tilde(c.workspace)) · since \(Fmt.ago(c.since))")
                                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }.help("agent-device boots this device again while that session holds it. Shut Down ends the session's claim so it stays off.")
                    }
                    if let l = d.launchedBy { sessionRow("Launched by", l) }
                    ForEach(d.recentUsers.sorted { $0.value > $1.value }.prefix(3), id: \.key) { u in sessionRow("Used by", u.key, when: u.value) }
                    if d.launchedBy == nil && d.recentUsers.isEmpty && d.claim == nil && d.lease == nil { Text(d.kind == .simulator ? "No agent session linked" : "Started outside an agent session").hudLabel() }
                }
                if let a = d.lastAction {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text("Last command here").hudLabel(Aspect.claude.color.readable(scheme))
                            Text(Fmt.ago(a.at)).hudLabel()
                        }
                        Text("$ " + a.command).font(.system(size: 10.5, design: .monospaced)).lineLimit(3).textSelection(.enabled).help(a.command)
                        if let p = m.session(a.session)?.lastPrompt, !p.isEmpty {
                            Text("“\(p)”").font(.system(size: 11)).italic().foregroundStyle(.secondary).lineLimit(2).help(p)
                        }
                    }
                    .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Rectangle().fill(Aspect.claude.color.opacity(0.06)))
                    .overlay(alignment: .leading) { Rectangle().fill(Aspect.claude.color).frame(width: 2) }
                }
                if !working.isEmpty {
                    Label("\(working.map(\.title).joined(separator: ", ")) is working and recently used this device", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Color(hex: 0xFF8A3D))
                }
                if let a = m.ask(for: d) { askRow(a) }
                HStack {
                    Button { m.openLiveView(d) } label: { Label("Live view", systemImage: "play.rectangle") }
                        .buttonStyle(HUDButton(color: aspect.color))
                        .disabled((d.serial == nil && d.kind != .simulator) || d.state == "offline")
                    Spacer()
                    if d.kind != .phone {
                        if let s = m.askTarget(d), m.ask(for: d).map(\.answered) ?? true {
                            Button { m.askSession(d) } label: { Label("Ask session", systemImage: "questionmark.bubble") }
                                .buttonStyle(HUDButton(color: Aspect.claude.color))
                                .help("Asks \(s.title) whether \(d.name) can be shut down. It sees the question on its next Bash or MCP tool call and answers with `RigWatch answer`. An idle session cannot answer. Nothing is shut down for you.")
                        }
                        Button { m.confirmShutDown(d) } label: { Label("Shut down", systemImage: "power") }
                            .buttonStyle(HUDButton(color: Color(hex: 0xFF4D5E), filled: m.ask(for: d)?.state == .yes))
                    }
                }
            }
        }
    }

    /// Where the question to the session stands. Waiting turns into "idle" after two minutes without a
    /// tool call from it, because only a tool call can carry the question.
    func askRow(_ a: Ask) -> some View {
        let s = m.session(a.session), who = s?.title ?? String(a.session.prefix(8))
        let idle = !(s?.isWorking ?? false) && Date().timeIntervalSince(a.askedAt) > 120
        let waited = Fmt.ago(a.askedAt).replacingOccurrences(of: " ago", with: "")
        let (chip, icon, color, text): (String, String, Color, String) = switch a.state {
        case .yes: ("SAFE TO CLOSE", "checkmark.circle.fill", Color(hex: 0x3DDC97),
                    "\(who) answered \(Fmt.ago(a.answeredAt))" + (a.reason.isEmpty ? "." : ": \(a.reason)"))
        case .no: ("KEEP", "hand.raised.fill", Color(hex: 0xFF8A3D), "\(who) still needs it" + (a.reason.isEmpty ? " (no reason given)." : ": \(a.reason)"))
        case .delivered: ("WAITING \(waited.uppercased())", "hourglass", Color(hex: 0xFFD23F),
                          "\(who) saw the question \(Fmt.ago(a.deliveredAt)) and has not answered yet.")
        case .pending where s?.live != true: ("NO ANSWER", "xmark.octagon", Aspect.process.color,
                                              "\(who) is no longer running, so it cannot see or answer the question. Decide yourself.")
        case .pending where idle: ("WAITING \(waited.uppercased())", "moon.zzz", Aspect.process.color,
                                   "\(who) is idle, so it has not seen the question: it only arrives with the session's next Bash or MCP tool call. Decide yourself, or wait.")
        case .pending: ("ASKED", "questionmark.bubble", Aspect.claude.color, "Waiting for \(who)'s next Bash or MCP tool call to deliver the question.")
        }
        return HStack(alignment: .top, spacing: 8) {
            Chip(text: chip, icon: icon, color: color).fixedSize()
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
            Button { m.forgetAsk(d) } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Forget this question. Unanswered questions lapse 30 min after asking; answers are kept for 30 min.")
        }
        .padding(9)
        .background(Rectangle().fill(color.opacity(0.07)))
        .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 2) }
    }

    func sessionRow(_ label: String, _ id: String, when: Date? = nil) -> some View {
        let s = m.session(id)
        return HStack(spacing: 8) {
            Text(label).hudLabel().fixedSize().frame(width: 80, alignment: .leading)
            SessionLink(id: id).layoutPriority(1)
            if let s { HStack(spacing: 4) { Dot(color: Heat.status(s.status)); Text(s.status).hudLabel(Heat.status(s.status)) }.fixedSize() }
            if let when { Text(Fmt.ago(when)).hudLabel().fixedSize() }
            Spacer(minLength: 0)
        }
    }
}

// MARK: Sessions

struct SessionsView: View {
    @ObservedObject private var m = Monitor.shared
    @State private var showClosed = false
    var body: some View {
        let live = m.sessions.filter(\.live).sorted { ($0.isWorking ? 0 : 1, -$0.cpu) < ($1.isWorking ? 0 : 1, -$1.cpu) }
        let gone = m.sessions.filter { !$0.live }.sorted { $0.cpu > $1.cpu }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionTitle(title: "Live sessions", aspect: .claude, count: live.count)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 400), spacing: 14, alignment: .top)], spacing: 14) { ForEach(live) { SessionCard(s: $0) } }
                if !gone.isEmpty {
                    HStack {
                        SectionTitle(title: "Closed, processes still running", aspect: .process, count: gone.count)
                        Button(showClosed ? "Hide" : "Show") { showClosed.toggle() }.buttonStyle(HUDButton(color: Aspect.process.color))
                    }
                    if showClosed { LazyVGrid(columns: [GridItem(.adaptive(minimum: 400), spacing: 14, alignment: .top)], spacing: 14) { ForEach(gone) { SessionCard(s: $0) } } }
                }
                Text("CPU and memory include every process the session started: Gradle daemons, emulators, MCP servers. Claude Code, OpenCode and Codex show titles and prompts; other agents are recognised from their processes.")
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
            }.padding(20)
        }
    }
}

struct SessionCard: View {
    @ObservedObject private var m = Monitor.shared
    @Environment(\.colorScheme) private var scheme
    let s: Session
    var body: some View {
        Panel(aspect: .claude) {
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(s.title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                        HStack(spacing: 6) {
                            Chip(text: s.agent.rawValue.uppercased(), color: Color(nsColor: s.agent.color)).fixedSize()
                            Text([s.project, s.id.hasPrefix("pid:") ? "pid " + s.id.dropFirst(4) : String(s.id.prefix(8)), s.host].filter { !$0.isEmpty }.joined(separator: " · ")).hudLabel().lineLimit(1)
                        }
                    }
                    Spacer()
                    HStack(spacing: 6) { Dot(color: Heat.status(s.status)); Text(s.status).hudLabel(Heat.status(s.status)) }.fixedSize()
                }
                HStack(spacing: 22) {
                    Readout(label: "CPU", value: Fmt.pct(s.cpu), color: Heat.cpu(s.cpu).readable(scheme), size: 20)
                    Readout(label: "Memory", value: Fmt.bytes(s.mem), color: Aspect.memory.color.readable(scheme), size: 20)
                    Readout(label: "Procs", value: "\(s.procCount)", size: 20)
                    Readout(label: "Active", value: Fmt.age(s.transcriptAge).replacingOccurrences(of: " ago", with: ""), size: 20)
                }
                if !s.devices.isEmpty || s.worktrees > 0 || !s.servers.isEmpty {
                    FlowChips {
                        ForEach(s.devices, id: \.self) { Chip(text: $0, icon: Aspect.android.icon, color: Aspect.android.color) }
                        ForEach(s.servers, id: \.self) { x in
                            Button { m.tab = .servers } label: { Chip(text: x.uppercased(), icon: Aspect.server.icon, color: Aspect.server.color) }
                                .buttonStyle(.plain).help("Dev server this session started. Click to see it on Dev Servers.")
                        }
                        if s.worktrees > 0 { Chip(text: "\(s.worktrees) WORKTREE\(s.worktrees == 1 ? "" : "S")", icon: Aspect.worktree.icon, color: Aspect.worktree.color) }
                    }
                }
                if !s.lastPrompt.isEmpty {
                    Text("“\(s.lastPrompt)”").font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(3).help(s.lastPrompt)
                        .padding(.leading, 9).overlay(alignment: .leading) { Rectangle().fill(Color(nsColor: s.agent.color)).frame(width: 2) }
                }
                HStack(spacing: 8) {
                    OpenSessionButton(session: s)
                    if s.live { QuitSessionButton(session: s) }
                }
            }
        }
    }
}

// MARK: Dev servers

struct DevServersView: View {
    @ObservedObject private var m = Monitor.shared
    var body: some View {
        let agent = m.servers.filter { $0.session != nil }
        let other = m.servers.filter { $0.session == nil }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionTitle(title: "Started by an agent session", aspect: .server, count: agent.count)
                grid(agent, empty: "No agent session has a server listening")
                SectionTitle(title: "Other local servers", aspect: .process, count: other.count)
                grid(other, empty: "None listening")
                Text("Every process of yours with a TCP port open for listening. The session that started a server is remembered, so it still shows after that session ends and the server is left running.")
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
            }.padding(20)
        }
    }

    @ViewBuilder func grid(_ list: [DevServer], empty: String) -> some View {
        if list.isEmpty {
            Text(empty).hudLabel().padding(.leading, 14)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 400), spacing: 14, alignment: .top)], spacing: 14) { ForEach(list) { DevServerCard(d: $0) } }
        }
    }
}

struct DevServerCard: View {
    @ObservedObject private var m = Monitor.shared
    @Environment(\.colorScheme) private var scheme
    let d: DevServer
    var body: some View {
        let s = m.session(d.session)
        let ended = d.session != nil && !(s?.live ?? false)
        Panel(aspect: .server) {
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .top, spacing: 12) {
                    IconBadge(aspect: .server, size: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(d.kind).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                        Text([d.cwd.map { ($0 as NSString).lastPathComponent }, d.name, "pid \(d.pid)"].compactMap { $0 }.joined(separator: " · ")).hudLabel().lineLimit(1)
                    }
                    Spacer()
                    HStack(spacing: 4) {
                        ForEach(d.ports, id: \.self) { p in
                            Button { m.openServer(d, port: p) } label: { Chip(text: ":\(p)", color: Aspect.server.color, filled: true) }
                                .buttonStyle(.plain).help("Open http://localhost:\(p)")
                        }
                    }.fixedSize()
                }
                HStack(spacing: 22) {
                    Readout(label: "CPU", value: Fmt.cpu(d.cpu), color: Heat.cpu(d.cpu).readable(scheme), size: 20)
                    Readout(label: "Memory", value: Fmt.bytes(d.mem), color: Aspect.memory.color.readable(scheme), size: 20)
                    Readout(label: "Uptime", value: d.started.map { Fmt.ago($0).replacingOccurrences(of: " ago", with: "") } ?? "—", size: 20)
                }
                if let c = d.cwd {
                    Text(Views.tilde(c)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(c)
                }
                HStack(spacing: 8) {
                    Text("Started by").hudLabel().fixedSize().frame(width: 80, alignment: .leading)
                    if let id = d.session {
                        if s != nil { SessionLink(id: id).layoutPriority(1) }
                        else { Chip(text: d.sessionTitle ?? String(id.prefix(8)), icon: Aspect.claude.icon, color: Aspect.process.color).layoutPriority(1) }
                        if ended { Chip(text: "SESSION ENDED", color: Color(hex: 0xFFD23F)).fixedSize() }
                        else if let s { HStack(spacing: 4) { Dot(color: Heat.status(s.status)); Text(s.status).hudLabel(Heat.status(s.status)) }.fixedSize() }
                    } else if d.orphaned {
                        Chip(text: "ORPHANED", icon: "exclamationmark.triangle", color: Color(hex: 0xFF8A3D)).fixedSize().help("Its parent exited; launchd adopted it.")
                    } else {
                        Text(m.startedBy(d).replacingOccurrences(of: "parent: ", with: "")).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                HStack {
                    Button { m.openServer(d) } label: { Label("Open", systemImage: "safari") }.buttonStyle(HUDButton(color: Aspect.server.color, filled: true))
                        .help("Open http://localhost:\(d.ports.first ?? 0) in your browser")
                    Spacer()
                    Button { m.confirmStop(d) } label: { Label("Stop", systemImage: "stop.circle") }.buttonStyle(HUDButton(color: Color(hex: 0xFF4D5E)))
                }
            }
        }
    }
}

// MARK: Processes

struct ProcessesView: View {
    @ObservedObject private var m = Monitor.shared
    @Environment(\.colorScheme) private var scheme
    @State private var order = [KeyPathComparator(\Proc.cpu, order: .reverse)]
    @State private var mine = false
    @State private var sel: Proc.ID?
    var body: some View {
        let search = m.procSearch
        let rows = m.procs.filter { (!mine || $0.isOwn) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.group.localizedCaseInsensitiveContains(search) || "\($0.pid)" == search) }
            .sorted(using: order).prefix(250)
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("FILTER  name · group · pid", text: $m.procSearch).textFieldStyle(.plain).font(.system(size: 11.5, design: .monospaced))
                }
                .padding(.horizontal, 10).padding(.vertical, 7).frame(maxWidth: 340)
                .overlay(Rectangle().strokeBorder(HUD(scheme: scheme).line, lineWidth: 0.8))
                Button(mine ? "Only mine ✓" : "Only mine") { mine.toggle() }.buttonStyle(HUDButton(color: HUD(scheme: scheme).accent, filled: mine))
                Spacer()
                Readout(label: "Processes", value: "\(m.procs.count)", size: 18)
            }
            Panel(aspect: .cpu, padding: 1) {
                Table(Array(rows), selection: $sel, sortOrder: $order) {
                    TableColumn("Name", value: \.name) { p in
                        HStack(spacing: 7) { Image(systemName: Aspect.forGroup(p.group).icon).font(.system(size: 10)).foregroundStyle(Aspect.forGroup(p.group).color.readable(scheme)).frame(width: 14); Text(p.name).font(.system(size: 12)).lineLimit(1) }.help(p.path)
                    }.width(min: 140, ideal: 170)
                    TableColumn("PID", value: \.pidSort) { p in Text("\(p.pid)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary) }.width(55)
                    TableColumn("CPU of machine", value: \.cpu) { p in
                        HStack(spacing: 6) {
                            Text(Fmt.cpu(p.cpu)).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(Heat.cpu(p.cpu).readable(scheme)).lineLimit(1).frame(width: 46, alignment: .trailing).help(Fmt.coresUsed(p.cpu) + " busy")
                            Meter(value: min(1, p.cpu / 400), color: Heat.cpu(p.cpu), height: 3).frame(width: 34)
                        }
                    }.width(110)
                    TableColumn("GPU", value: \.gpu) { p in
                        Text(p.gpu >= 0.05 ? String(format: "%.1f%%", p.gpu) : "—").font(.system(size: 11, design: .monospaced)).lineLimit(1)
                            .foregroundStyle(p.gpu >= 10 ? Aspect.gpu.color.readable(scheme) : p.gpu >= 0.05 ? .primary : .secondary)
                    }.width(55)
                    TableColumn("Memory", value: \.mem) { p in Text(Fmt.bytes(p.mem)).font(.system(size: 11, design: .monospaced)).lineLimit(1).foregroundStyle(p.mem > 4_000_000_000 ? Aspect.memory.color.readable(scheme) : .primary) }.width(80)
                    TableColumn("Disk", value: \.diskSort) { p in Text(p.isOwn ? Fmt.rate(p.diskRead + p.diskWrite) : "—").font(.system(size: 10.5, design: .monospaced)).lineLimit(1).foregroundStyle(.secondary) }.width(75)
                    TableColumn("Group", value: \.group) { p in Chip(text: p.group, color: Aspect.forGroup(p.group).color) }.width(min: 90, ideal: 130)
                    TableColumn("Agent session") { p in if let s = p.session { SessionLink(id: s) } }.width(min: 90, ideal: 140)
                    TableColumn("") { p in
                        HStack(spacing: 4) {
                            Button("Quit") { m.confirmQuit(p) }.buttonStyle(HUDButton(color: Aspect.process.color))
                            Button("Kill") { m.confirmQuit(p, force: true) }.buttonStyle(HUDButton(color: Color(hex: 0xFF4D5E)))
                        }.disabled(Safety.processBlock(p) != nil).help(Safety.processBlock(p) ?? "")
                    }.width(min: 110, ideal: 116)
                }
                .scrollContentBackground(.hidden)
                .alternatingRowBackgrounds(.disabled)
            }
        }.padding(20)
    }
}

extension Proc { var pidSort: Int { Int(pid) }; var diskSort: Double { diskRead + diskWrite } }

// MARK: Memory

struct MemoryView: View {
    @ObservedObject private var m = Monitor.shared
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let s = m.sys
        let t = Double(max(s.memTotal, 1))
        let parts: [(String, UInt64, Color)] = [("App", s.memApp, Aspect.memory.color), ("Wired", s.memWired, Color(hex: 0xFFB020)),
                                                 ("Compressed", s.memCompressed, Color(hex: 0xF472B6)), ("Cached files", s.memCached, Aspect.disk.color),
                                                 ("Free", s.memFree, Color(hex: 0x7D8B99))]
        let top = m.groups.sorted { $0.mem > $1.mem }.prefix(24)
        let maxMem = Double(top.first?.mem ?? 1)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Panel(aspect: .memory) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .bottom, spacing: 26) {
                            Readout(label: "Used", value: Fmt.bytes(s.memUsed), color: Aspect.memory.color.readable(scheme), size: 34)
                            Readout(label: "Installed", value: Fmt.bytes(s.memTotal), size: 34)
                            Readout(label: "Swap", value: Fmt.bytes(s.swapUsed), size: 34)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Text("Pressure").hudLabel()
                                Chip(text: Views.pressureName(s.pressure).uppercased(), icon: "gauge.with.dots.needle.67percent", color: Views.pressureColor(s.pressure), filled: true).fixedSize()
                            }
                        }
                        GeometryReader { g in
                            HStack(spacing: 2) {
                                ForEach(parts, id: \.0) { p in
                                    let w = max(0, Double(p.1) / t * (g.size.width - 8))
                                    ZStack(alignment: .topLeading) {
                                        Rectangle().fill(p.2.opacity(0.22))
                                        Rectangle().strokeBorder(p.2, lineWidth: 0.8)
                                        if w > 90 { Text(p.0).hudLabel(p.2.readable(scheme)).lineLimit(1).padding(6) }
                                    }.frame(width: w).help("\(p.0) \(Fmt.bytes(p.1))")
                                }
                            }
                        }.frame(height: 44)
                        FlowChips {
                            ForEach(parts, id: \.0) { p in Chip(text: "\(p.0.uppercased()) \(Fmt.bytes(p.1))", color: p.2) }
                            if s.gpuMem > 0 { Chip(text: "GPU IN USE \(Fmt.bytes(s.gpuMem)) · PART OF WIRED", icon: Aspect.gpu.icon, color: Aspect.gpu.color).help("GPU memory in use is wired. A local model's weights are GPU memory: they are in wired and in the footprint of the process that loaded them.") }
                        }
                    }
                }
                FreeList()
                SectionTitle(title: "Consumers", aspect: .memory, count: m.groups.count)
                Panel(aspect: .memory) {
                    VStack(spacing: 11) {
                        ForEach(Array(top.enumerated()), id: \.element.id) { i, g in
                            HStack(spacing: 10) {
                                Text(String(format: "%02d", i + 1)).font(.system(size: 9.5, weight: .bold, design: .monospaced)).foregroundStyle(.tertiary)
                                Image(systemName: Aspect.forGroup(g.name).icon).font(.system(size: 11)).foregroundStyle(Aspect.forGroup(g.name).color.readable(scheme)).frame(width: 16)
                                Text(g.name).font(.system(size: 12)).frame(width: 210, alignment: .leading).lineLimit(1)
                                Meter(value: Double(g.mem) / maxMem, color: Aspect.memory.color, height: 7, segments: 50)
                                Text(Fmt.bytes(g.mem)).font(.system(size: 12, weight: .semibold, design: .monospaced)).lineLimit(1).frame(width: 82, alignment: .trailing)
                                Text(Fmt.cpu(g.cpu)).font(.system(size: 10.5, design: .monospaced)).lineLimit(1).foregroundStyle(Heat.cpu(g.cpu).readable(scheme)).frame(width: 60, alignment: .trailing)
                                Text("×\(g.count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary).frame(width: 40, alignment: .trailing)
                                Button("Quit all") { m.confirmQuitGroup(g) }.buttonStyle(HUDButton(color: Color(hex: 0xFF4D5E))).disabled(g.killable.isEmpty)
                            }
                        }
                    }
                }
                Text("Your processes: physical footprint (Activity Monitor's “Memory”). System processes: resident size.")
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
            }.padding(20)
        }
    }
}

// MARK: Worktrees

struct WorktreesView: View {
    @ObservedObject private var m = Monitor.shared
    @Environment(\.colorScheme) private var scheme
    @State private var sel = Set<Worktree.ID>()
    @State private var order = [KeyPathComparator(\Worktree.activitySort)]
    var body: some View {
        let rows = m.worktrees.sorted(using: order)
        let measured = m.worktrees.filter { !$0.isMain }.compactMap(\.sizeKB).reduce(0, +)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom, spacing: 26) {
                Readout(label: "Linked", value: "\(m.worktrees.filter { !$0.isMain }.count)", color: Aspect.worktree.color.readable(scheme), size: 30)
                Readout(label: "Idle > 1 day", value: "\(m.idleWorktrees)", color: Color(hex: 0xFFD23F).readable(scheme), size: 30)
                Readout(label: "In use", value: "\(m.worktrees.filter { !$0.usedBy.isEmpty }.count)", color: Color(hex: 0x3DDC97).readable(scheme), size: 30)
                Readout(label: "Missing", value: "\(m.worktrees.filter { !$0.exists }.count)", color: Color(hex: 0xFF4D5E).readable(scheme), size: 30)
                Readout(label: "Measured", value: measured > 0 ? Fmt.bytes(measured * 1024) : "—", size: 30)
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 8) {
                    Text("\(sel.count) selected").hudLabel()
                    HStack(spacing: 6) {
                        Button("Select idle") {
                            sel = Set(m.worktrees.filter { w in !w.isMain && w.usedBy.isEmpty && (w.lastActivity.map { Date().timeIntervalSince($0) > 86400 } ?? true) && !(m.session(w.session)?.live ?? false) }.map(\.id))
                        }.buttonStyle(HUDButton(color: Color(hex: 0xFFD23F)))
                        Button(m.busy.contains("size") ? "Measuring" : "Measure") { m.measure(sel.isEmpty ? m.worktrees : m.worktrees.filter { sel.contains($0.id) }) }
                            .buttonStyle(HUDButton(color: Aspect.disk.color)).disabled(m.busy.contains("size"))
                        Button { m.confirmRemove(m.worktrees.filter { sel.contains($0.id) }) } label: { Label(m.busy.contains("check") ? "Checking" : "Remove", systemImage: "trash") }
                            .buttonStyle(HUDButton(color: Color(hex: 0xFF4D5E), filled: !sel.isEmpty)).disabled(sel.isEmpty || m.busy.contains("check"))
                    }.fixedSize()
                }
            }
            Panel(aspect: .worktree, padding: 1) {
                Table(rows, selection: $sel, sortOrder: $order) {
                    TableColumn("Worktree", value: \.path) { w in
                        VStack(alignment: .leading, spacing: 1) {
                            Text((w.path as NSString).lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text(Views.tilde(w.path)).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }.width(min: 220, ideal: 300)
                    TableColumn("Repo", value: \.repo) { w in Chip(text: w.repo, color: Aspect.process.color) }.width(min: 90, ideal: 160)
                    TableColumn("Branch", value: \.branch) { w in Text(w.branch).font(.system(size: 10.5, design: .monospaced)).lineLimit(1) }.width(min: 100, ideal: 170)
                    TableColumn("Session") { w in
                        if let id = w.session { SessionLink(id: id) } else if w.isMain { Chip(text: "MAIN CHECKOUT", color: Aspect.disk.color) }
                    }.width(min: 120, ideal: 200)
                    TableColumn("Last activity", value: \.activitySort) { w in
                        Text(Fmt.ago(w.lastActivity)).font(.system(size: 10.5, design: .monospaced)).lineLimit(1)
                            .foregroundStyle((w.lastActivity.map { Date().timeIntervalSince($0) > 86400 } ?? true) ? Color(hex: 0xFFD23F).readable(scheme) : .primary)
                    }.width(90)
                    TableColumn("Size", value: \.sizeSort) { w in Text(w.sizeKB.map { Fmt.bytes($0 * 1024) } ?? "—").font(.system(size: 10.5, design: .monospaced)).lineLimit(1) }.width(70)
                    TableColumn("State") { w in
                        HStack(spacing: 4) {
                            if !w.usedBy.isEmpty { Chip(text: "IN USE", color: Color(hex: 0x3DDC97)).help(w.usedBy.joined(separator: "\n")) }
                            if !w.exists { Chip(text: "MISSING", color: Color(hex: 0xFF4D5E)) }
                            if w.locked { Chip(text: "LOCKED", icon: "lock.fill", color: Color(hex: 0xFF8A3D)) }
                            if w.prunable { Chip(text: "PRUNABLE", color: Aspect.process.color) }
                        }
                    }.width(min: 80, ideal: 120)
                }
                .scrollContentBackground(.hidden)
                .alternatingRowBackgrounds(.disabled)
            }
            Text("Remove checks each worktree first and keeps any with uncommitted changes, untracked files (other than build/setup files), commits found on no remote, a process inside, or a session working right now.")
                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
        }.padding(20)
    }
}

extension Worktree {
    var activitySort: Double { -(lastActivity?.timeIntervalSince1970 ?? 0) }
    var sizeSort: Int64 { sizeKB ?? -1 }
}

// MARK: Disk

struct DiskView: View {
    @ObservedObject private var m = Monitor.shared
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let s = m.sys
        let vol = s.volumes.max { $0.total < $1.total }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let v = vol {
                    HStack(alignment: .bottom, spacing: 26) {
                        Readout(label: v.name, value: Fmt.bytes(v.used), unit: "used", color: Aspect.disk.color.readable(scheme), size: 34)
                        Readout(label: "Free", value: Fmt.bytes(v.free), color: (v.free < 20_000_000_000 ? Color(hex: 0xFF4D5E) : Color(hex: 0x3DDC97)).readable(scheme), size: 34)
                        Readout(label: "Capacity", value: Fmt.bytes(v.total), size: 34)
                        Readout(label: "Read", value: Fmt.rate(s.diskRead), size: 20)
                        Readout(label: "Write", value: Fmt.rate(s.diskWrite), size: 20)
                        Spacer(minLength: 12)
                        VStack(alignment: .trailing, spacing: 6) {
                            Text(m.busy.contains("folders") ? "Scanning folders…" : m.foldersScannedAt.map { "Scanned \(Fmt.ago($0))" } ?? "Not scanned").hudLabel().fixedSize()
                            Button(m.busy.contains("folders") ? "Scanning" : "Rescan") { m.scanFolders(force: true) }
                                .buttonStyle(HUDButton(color: Aspect.disk.color)).disabled(m.busy.contains("folders"))
                        }
                    }
                    SectionTitle(title: "Storage die", aspect: .disk)
                    StorageDie(volume: v).frame(height: 480)
                }
                HStack(alignment: .top, spacing: 14) {
                    let busy = m.procs.filter { $0.isOwn && $0.diskSort >= 1024 }.sorted { $0.diskSort > $1.diskSort }.prefix(8)
                    RankPanel(title: "Disk I/O right now", aspect: .disk,
                              rows: busy.map { ("\($0.name) · \($0.pid)", $0.diskSort / max(1, busy.first?.diskSort ?? 1), Fmt.rate($0.diskSort), 1) })
                    ForEach(s.volumes.filter { $0.path != vol?.path }) { v in
                        Gauge(aspect: .disk, label: v.name, value: Double(v.used) / Double(max(v.total, 1)), big: "\(Int(Double(v.used) / Double(max(v.total, 1)) * 100))", unit: "%", color: Aspect.disk.color) {
                            Chip(text: "\(Fmt.bytes(v.free)) FREE", color: Aspect.disk.color)
                        }
                    }
                }
            }.padding(20)
        }
        .onAppear { m.scanFolders() }
    }
}

/// The disk as a die: a block per folder sized by what it holds. Click a block to open it and see
/// its folders and files the same way; the path bar goes back up.
struct StorageDie: View {
    let volume: Volume
    @ObservedObject private var m = Monitor.shared
    @State private var hover: String?
    @Environment(\.colorScheme) private var scheme

    struct Block: Identifiable {   // kind 0 item, 1 other, 2 free
        let id: String; let label: String; let bytes: Int64; let color: Color; let path: String?; let kind: Int
        var value: String? = nil; var caption: String? = nil; var heat: Double = 0
    }

    static let palette: [UInt32] = [0x2EE6D6, 0x22D3EE, 0x2F80ED, 0x60A5FA, 0x818CF8, 0xA78BFA, 0x3DDC97, 0x34D399, 0xF472B6, 0xFFB020, 0xE5866A, 0x5AC8FA]

    var current: String? { m.drill.last }

    var blocks: [Block] {
        let items = current.map { m.children[$0] ?? [] } ?? m.folders
        var b: [Block] = []
        let known = items.compactMap { f -> (Folder, Int64)? in guard let kb = f.kb, kb > 0 else { return nil }; return (f, kb * 1024) }.sorted { $0.1 > $1.1 }
        let mapTotal = Double(known.reduce(Int64(0)) { $0 + $1.1 } + (current == nil ? max(0, volume.used - known.reduce(0) { $0 + $1.1 }) + volume.free : 0))
        let shown = known.prefix(current == nil ? 40 : 30).filter { Double($0.1) >= mapTotal * 0.003 }
        for (i, k) in shown.enumerated() {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: k.0.path, isDirectory: &isDir)
            let name = k.0.label.hasPrefix("Other in") || !k.0.label.contains("/") ? k.0.label : (k.0.path as NSString).lastPathComponent
            b.append(Block(id: k.0.path, label: name + (isDir.boolValue || Demo.on ? "" : " (file)"), bytes: k.1, color: Color(hex: Self.palette[i % Self.palette.count]), path: k.0.path, kind: 0))
        }
        let rest = known.dropFirst(shown.count).reduce(Int64(0)) { $0 + $1.1 }
        let restNames = known.dropFirst(shown.count).prefix(4).map(\.0.label).joined(separator: ", ")
        if rest > 0 { b.append(Block(id: "rest", label: "\(known.count - shown.count) smaller items", bytes: rest, color: Color(hex: 0x7D8B99), path: Self.restKey(current), kind: 1, caption: restNames)) }
        // Keep the grouped items on hand so clicking the block opens them as their own map.
        let key = Self.restKey(current)
        let grouped = Array(known.dropFirst(shown.count).map(\.0))
        if m.children[key + "#grouped"]?.map(\.path) != grouped.map(\.path) { DispatchQueue.main.async { m.children[key + "#grouped"] = grouped } }
        if current == nil {
            let other = volume.used - known.reduce(0) { $0 + $1.1 }
            if other > 0 { b.append(Block(id: "other", label: "System & protected", bytes: other, color: Color(hex: 0x7D8B99), path: nil, kind: 1,
                                          caption: m.busy.contains("folders") ? "still measuring…" : "sealed system volume, snapshots, root-only folders")) }
            b.append(Block(id: "free", label: "Free", bytes: volume.free, color: Color(hex: 0x3DDC97), path: nil, kind: 2))
        }
        return b.filter { $0.bytes > 0 }
    }

    static func restKey(_ parent: String?) -> String { (parent ?? "") + "/Smaller items" }

    /// The "smaller items" block opens as its own map: it holds what the builder grouped plus what the
    /// layout folded to keep every label readable.
    func keepFolded(_ folded: [Block]) -> Bool {
        let key = Self.restKey(current)
        let items = (current.map { m.children[$0] ?? [] } ?? m.folders).filter { f in folded.contains { $0.id == f.path } }
        let grouped = m.children[key + "#grouped"] ?? []
        let all = items + grouped.filter { g in !items.contains { $0.path == g.path } }
        if m.children[key]?.map(\.path) != all.map(\.path) { DispatchQueue.main.async { m.children[key] = all } }
        return true
    }

    func open(_ blk: Block) {
        guard let p = blk.path else { return }
        if blk.id == "rest" { m.drill.append(p); return }
        var isDir: ObjCBool = false
        if Demo.on || (FileManager.default.fileExists(atPath: p, isDirectory: &isDir) && isDir.boolValue) { m.openFolder(p) }
        else { NSWorkspace.shared.selectFile(p, inFileViewerRootedAtPath: "") }
    }

    var body: some View {
        let list = blocks
        let total = Double(list.reduce(Int64(0)) { $0 + $1.bytes })
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Button { m.drill = [] } label: { Label(volume.name, systemImage: "internaldrive") }.buttonStyle(HUDButton(color: Aspect.disk.color, filled: current == nil))
                ForEach(Array(m.drill.enumerated()), id: \.offset) { i, p in
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    Button((p as NSString).lastPathComponent) { m.drill = Array(m.drill.prefix(i + 1)) }.buttonStyle(HUDButton(color: Aspect.disk.color, filled: i == m.drill.count - 1))
                }
                Spacer()
                if m.busy.contains("drill") { ProgressView().controlSize(.small); Text("Measuring…").hudLabel() }
                if let c = current {
                    Button { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: c) } label: { Label("Finder", systemImage: "folder") }.buttonStyle(HUDButton(color: Aspect.disk.color))
                    Button { m.children[c] = nil; m.drill.removeLast(); m.openFolder(c) } label: { Label("Rescan", systemImage: "arrow.clockwise") }.buttonStyle(HUDButton(color: Aspect.disk.color))
                }
            }
            HStack(alignment: .top, spacing: 14) {
                GeometryReader { g in
                    let outer = CGRect(origin: .zero, size: g.size)
                    let laid = Fit.fold(list, in: outer.insetBy(dx: 22, dy: 22), restPath: Self.restKey(current))
                    let shownList = laid.blocks, rects = laid.rects
                    let _ = keepFolded(laid.folded)
                    ZStack(alignment: .topLeading) {
                        ChipPins().stroke(LinearGradient(colors: [Color(hex: 0x2EE6D6), Color(hex: 0x2F80ED)], startPoint: .topLeading, endPoint: .bottomTrailing).opacity(0.6), lineWidth: 1)
                        Rectangle().strokeBorder(LinearGradient(colors: [Color(hex: 0x2EE6D6), Color(hex: 0x2F80ED)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 2).padding(10)
                        ForEach(Array(zip(shownList, rects)), id: \.0.id) { blk, r in
                            DieBlock(block: blk, share: Double(blk.bytes) / Double(max(current == nil ? volume.total : Int64(total), 1)), highlighted: hover == blk.id, of: current == nil ? "of disk" : "of folder")
                                .frame(width: max(0, r.width - 4), height: max(0, r.height - 4))
                                .position(x: r.midX, y: r.midY)
                                .onHover { hover = $0 ? blk.id : (hover == blk.id ? nil : hover) }
                                .onTapGesture { open(blk) }
                                .contextMenu { if let p = blk.path { Button("Show in Finder") { NSWorkspace.shared.selectFile(p, inFileViewerRootedAtPath: "") } } }
                        }
                    }
                }
                Panel(aspect: .disk) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 9) {
                            Text(current == nil ? "Allocation" : "Inside \((current! as NSString).lastPathComponent)").hudLabel(Aspect.disk.color.readable(scheme))
                            ForEach(list) { blk in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 7) {
                                        Rectangle().fill(blk.color).frame(width: 8, height: 8)
                                        Text(blk.label).font(.system(size: 11.5)).lineLimit(1)
                                        Spacer(minLength: 4)
                                        Text(Fmt.bytes(blk.bytes)).font(.system(size: 11, weight: .semibold, design: .monospaced)).lineLimit(1).fixedSize()
                                    }
                                    Meter(value: Double(blk.bytes) / Double(max(list.map(\.bytes).max() ?? 1, 1)), color: blk.color, height: 2.5)
                                }
                                .padding(.vertical, 1)
                                .background(Rectangle().fill(hover == blk.id ? blk.color.opacity(0.1) : .clear))
                                .contentShape(Rectangle())
                                .onHover { hover = $0 ? blk.id : (hover == blk.id ? nil : hover) }
                                .onTapGesture { open(blk) }
                            }
                            if current == nil && m.folders.allSatisfy({ $0.kb == nil }) { Text("Measuring folders… first scan takes a minute.").hudLabel() }
                        }
                    }
                }.frame(width: 320)
            }
            let measured = m.folders.compactMap(\.kb).reduce(Int64(0), +) * 1024
            if current == nil && measured > volume.used {
                Label("Folders add up to \(Fmt.bytes(measured)) on a disk with \(Fmt.bytes(volume.used)) used. APFS clones shared between folders are counted in each folder, so deleting one copy frees less than its block shows.", systemImage: "info.circle")
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Color(hex: 0xFF8A3D))
            }
            Text("Click a block to open it. Right-click to show it in Finder.").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
        }
    }
}

struct DieBlock: View {
    let block: StorageDie.Block
    let share: Double
    let highlighted: Bool
    var of = "of disk"
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let c = block.color, ink = c.readable(scheme)
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let fit = Fit.vertical(block, CGSize(width: w + 4, height: h + 4))   // same box the layout checked
            let vertical = fit ?? (h > w * 1.25)   // reads across when it fits, else up the side
            let long = vertical ? h : w, short = vertical ? w : h
            ZStack(alignment: .topLeading) {
                Rectangle().fill(LinearGradient(colors: [c.opacity(block.kind == 2 ? 0.05 : (highlighted ? 0.34 : 0.16 + 0.3 * block.heat)),
                                                         c.opacity(block.kind == 2 ? 0.01 : (highlighted ? 0.16 : 0.05))],
                                                startPoint: .topLeading, endPoint: .bottomTrailing))
                BlockTraces(kind: block.kind, color: c)
                Rectangle().strokeBorder(c.opacity(highlighted ? 1 : 0.7), lineWidth: highlighted ? 1.6 : 0.9)
                // Accent bar on the edge the text starts from.
                if vertical { Rectangle().fill(c).frame(width: w, height: 2).frame(maxHeight: .infinity, alignment: .bottom) }
                else { Rectangle().fill(c).frame(width: 2, height: h) }
                if highlighted { Brackets(len: 8).stroke(ink, lineWidth: 1.6) }
                if fit != nil {
                    BlockLabel(block: block, share: share, of: of, ink: ink, long: long, short: short)
                        .frame(width: long, height: short)
                        .rotationEffect(.degrees(vertical ? -90 : 0))
                        .frame(width: w, height: h)
                } else if block.kind != 0 {
                    // Fixed blocks are never folded away, so one too small for its name still shows its size.
                    Text(block.value ?? Fmt.bytes(block.bytes))
                        .font(.system(size: BlockLabel.minFont, weight: .semibold, design: .monospaced))
                        .foregroundStyle(ink).lineLimit(1).minimumScaleFactor(0.8)
                        .padding(4)
                        .rotationEffect(.degrees(vertical ? -90 : 0))
                        .frame(width: w, height: h)
                }
            }
        }
        .help("\(block.label): \(block.value ?? Fmt.bytes(block.bytes))\(block.path.map { "\n" + Views.tilde($0) } ?? "")")
    }
}

/// Name, figure and share, laid out along the block's long side; the figure grows to fill what is left.
struct BlockLabel: View {
    let block: StorageDie.Block
    let share: Double
    let of: String
    let ink: Color
    let long: CGFloat
    let short: CGFloat
    static let minFont: CGFloat = 9.5      // nothing on the map is drawn smaller than this
    var body: some View {
        // Every size is clamped and derived from the block, so text keeps a margin on all sides.
        let pad = min(18, max(8, short * 0.08))
        let inner = long - 2 * pad
        let valueText = block.value ?? Fmt.bytes(block.bytes)
        let nameSize = min(14, max(Self.minFont, min(short * 0.09, inner / (CGFloat(block.label.count) * 0.68))))
        let showValue = short >= 44
        let captionText = block.caption ?? String(format: "%.1f%% ", share * 100) + of
        let showCaption = short >= 90 && long >= CGFloat(captionText.count) * Fit.charName + Fit.pad
        let bigSize = min(52, max(13, min(short * (showCaption ? 0.3 : 0.36), inner * 0.7 / (CGFloat(valueText.count) * 0.58))))
        VStack(alignment: .leading, spacing: max(1, short * 0.02)) {
            Text(block.label.uppercased())
                .font(.system(size: nameSize, weight: .semibold, design: .monospaced)).tracking(nameSize * 0.1)
                .foregroundStyle(ink).lineLimit(1).minimumScaleFactor(Self.minFont / nameSize)
            if showValue {
                Spacer(minLength: 0)
                Text(valueText)
                    .font(.system(size: bigSize, weight: .thin, design: .rounded)).monospacedDigit()
                    .foregroundStyle(LinearGradient(colors: [.primary, ink], startPoint: .leading, endPoint: .trailing))
                    .lineLimit(1).minimumScaleFactor(min(1, 13 / bigSize))
            }
            if showCaption {
                HStack(spacing: 6) {
                    Text(captionText)
                        .font(.system(size: Self.minFont, weight: .medium, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    // The mini bar only when the caption still has its full width beside it.
                    if block.caption == nil && long >= CGFloat(captionText.count) * Fit.charName + Fit.pad + 60 { Meter(value: share, color: ink, height: 2).frame(width: 50) }
                }
            }
        }
        .padding(pad)
        .frame(width: long, height: short, alignment: .topLeading)
    }
}

/// Faint circuit traces inside a block; hatching for free space.
struct BlockTraces: View {
    let kind: Int
    let color: Color
    var body: some View {
        Canvas { ctx, size in
            if kind == 2 {
                var p = Path()
                for x in stride(from: -size.height, through: size.width, by: 9) { p.move(to: CGPoint(x: x, y: size.height)); p.addLine(to: CGPoint(x: x + size.height, y: 0)) }
                ctx.stroke(p, with: .color(color.opacity(0.16)), lineWidth: 0.6)
            } else {
                let cols = max(1, Int(size.width / 34)), rows = max(1, Int(size.height / 34))
                let w = size.width / CGFloat(cols), h = size.height / CGFloat(rows)
                for i in 0..<cols { for j in 0..<rows where (i + j) % 2 == 0 {
                    let r = CGRect(x: CGFloat(i) * w, y: CGFloat(j) * h, width: w, height: h).insetBy(dx: w * 0.32, dy: h * 0.32)
                    ctx.stroke(Path(r), with: .color(color.opacity(0.13)), lineWidth: 0.6)
                } }
            }
        }
    }
}

/// Makes a treemap readable by construction: every block it returns can show its name and figure on one
/// line at a readable size (across, or up its side). Blocks that can't are folded, smallest first, into
/// the "smaller items" block, and the layout runs again until everything left fits.
enum Fit {
    static let charName: CGFloat = 7.1, charValue: CGFloat = 7.8, pad: CGFloat = 28, minShort: CGFloat = 40

    static func need(_ b: StorageDie.Block) -> CGFloat {
        max(CGFloat(b.label.count) * charName, CGFloat((b.value ?? Fmt.bytes(b.bytes)).count) * charValue) + pad
    }
    /// false = reads across, true = reads up the side, nil = can't hold its text at a readable size.
    static func vertical(_ b: StorageDie.Block, _ size: CGSize) -> Bool? {
        let w = size.width - 4, h = size.height - 4, n = need(b)
        if w >= n && h >= minShort { return false }
        if h >= n && w >= minShort { return true }
        return nil
    }

    static func fold(_ blocks: [StorageDie.Block], in rect: CGRect, restPath: String?, restValue: (Int64) -> String? = { _ in nil })
        -> (blocks: [StorageDie.Block], rects: [CGRect], folded: [StorageDie.Block]) {
        var items = blocks.filter { $0.kind == 0 }
        let fixed = blocks.filter { $0.kind != 0 && $0.id != "rest" }
        let baseRest = blocks.first { $0.id == "rest" }
        var folded: [StorageDie.Block] = []
        while true {
            var list = items
            let restBytes = (baseRest?.bytes ?? 0) + folded.reduce(Int64(0)) { $0 + $1.bytes }
            if restBytes > 0 {
                let count = folded.count + (Int(baseRest?.label.split(separator: " ").first ?? "") ?? 0)
                let names = (folded.map(\.label) + [baseRest?.caption].compactMap { $0 }).prefix(4).joined(separator: ", ")
                list.append(.init(id: "rest", label: "\(count) smaller items", bytes: restBytes, color: Color(hex: 0x7D8B99), path: restPath ?? baseRest?.path, kind: 1,
                                  value: restValue(restBytes), caption: names))
            }
            list += fixed
            list.sort { $0.bytes > $1.bytes }     // squarified layout only stays square when fed largest first
            let rects = Squarify.layout(list.map { Double($0.bytes) }, in: rect)
            let failing = Set(zip(list, rects).filter { $0.kind == 0 && vertical($0, $1.size) == nil }.map(\.0.id))
            guard let drop = items.lastIndex(where: { failing.contains($0.id) }) else { return (list, rects, folded) }
            folded.append(items.remove(at: drop))   // the smallest block that can't hold its text
        }
    }
}

/// Squarified treemap (Bruls, Huijsen, van Wijk): blocks as close to square as possible.
enum Squarify {
    static func layout(_ values: [Double], in rect: CGRect) -> [CGRect] {
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return values.map { _ in .zero } }
        let scale = rect.width * rect.height / total
        let areas = values.map { $0 * scale }
        var out = [CGRect](repeating: .zero, count: values.count)
        var r = rect, i = 0
        func worst(_ row: ArraySlice<Double>, _ side: Double) -> Double {
            let s = row.reduce(0, +), mx = row.max() ?? 0, mn = row.min() ?? 0
            guard s > 0, mn > 0 else { return .infinity }
            return max(side * side * mx / (s * s), s * s / (side * side * mn))
        }
        while i < areas.count {
            let side = Double(min(r.width, r.height))
            var j = i + 1
            while j < areas.count && worst(areas[i...j], side) <= worst(areas[i..<j], side) { j += 1 }
            let row = areas[i..<j], sum = row.reduce(0, +)
            if r.width >= r.height {
                let w = CGFloat(sum) / r.height
                var y = r.minY
                for (k, a) in row.enumerated() { let h = CGFloat(a) / w; out[i + k] = CGRect(x: r.minX, y: y, width: w, height: h); y += h }
                r = CGRect(x: r.minX + w, y: r.minY, width: r.width - w, height: r.height)
            } else {
                let h = CGFloat(sum) / r.width
                var x = r.minX
                for (k, a) in row.enumerated() { let w = CGFloat(a) / h; out[i + k] = CGRect(x: x, y: r.minY, width: w, height: h); x += w }
                r = CGRect(x: r.minX, y: r.minY + h, width: r.width, height: r.height - h)
            }
            i = j
        }
        return out
    }
}

// MARK: Session links and live view

/// What clicking a session does: open it in the Claude desktop app, copy the tool's resume
/// command, or show its folder.
enum SessionAction {
    case open, copy(String), folder, none
    static func of(_ s: Session?, id: String) -> SessionAction {
        let agent = s?.agent ?? .claude
        if agent == .claude, s?.hostId != nil { return .open }
        if !id.hasPrefix("pid:"), let c = agent.resumeCommand(id) { return .copy(c) }
        return s?.cwd != nil ? .folder : .none
    }
    var title: String { switch self { case .open: "Open in Claude"; case .copy: "Copy resume command"; case .folder: "Show folder"; case .none: "No session file" } }
    var icon: String { switch self { case .open: "arrow.up.forward.app"; case .copy: "doc.on.doc"; case .folder: "folder"; case .none: "questionmark.circle" } }
    var help: String { switch self { case .open: "Open this session in the Claude desktop app"; case .copy(let c): "Copies `\(c)`"; case .folder: "Shows the folder it works in"; case .none: "" } }
}

/// A session chip that opens or resumes the session when clicked.
struct SessionLink: View {
    @ObservedObject private var m = Monitor.shared
    let id: String
    var body: some View {
        let s = m.session(id)
        let act = SessionAction.of(s, id: id)
        let c = Color(nsColor: (s?.agent ?? .claude).color)
        Button { m.openSession(id) } label: {
            HStack(spacing: 3) {
                Chip(text: s?.title ?? String(id.prefix(8)), icon: Aspect.claude.icon, color: c)
                Image(systemName: act.icon).font(.system(size: 9)).foregroundStyle(c)
            }
        }
        .buttonStyle(.plain)
        .help(act.help)
    }
}

struct OpenSessionButton: View {
    @ObservedObject private var m = Monitor.shared
    let session: Session
    var body: some View {
        let act = SessionAction.of(session, id: session.id)
        Button { m.openSession(session.id) } label: { Label(act.title, systemImage: act.icon) }
            .buttonStyle(HUDButton(color: Color(nsColor: session.agent.color), filled: { if case .open = act { true } else { false } }()))
            .disabled({ if case .none = act { true } else { false } }())
            .help(act.help)
    }
}

/// Ends a live session's own agent process, after the confirmation in Monitor.confirmQuitSession.
struct QuitSessionButton: View {
    @ObservedObject private var m = Monitor.shared
    let session: Session
    var body: some View {
        let s = session
        let can = Demo.on ? s.host != "Desktop" : !s.pids.isEmpty   // demo cards follow the real rule
        let help = can ? "Quits this session's \(s.agent.rawValue) process (SIGTERM), after asking." + (s.agent.resumeCommand(s.id) != nil && !s.id.hasPrefix("pid:") ? " Its conversation stays saved." : "")
            : s.host == "Desktop" ? "This session runs inside the Claude app. Archive it in the Claude app to end it."
            : "RigWatch can't tell which process runs this session; find it on Processes."
        Button { m.confirmQuitSession(s) } label: { Label("Quit session", systemImage: "xmark.circle") }
            .buttonStyle(HUDButton(color: Color(hex: 0xFF4D5E)))
            .disabled(!can)
            .help(help)
    }
}

/// The device's screen, refreshed every few seconds while the sheet is open.
struct LiveView: View {
    @ObservedObject private var m = Monitor.shared
    @Environment(\.colorScheme) private var scheme
    let device: Device
    @State private var image: NSImage?
    @State private var failed = false
    @State private var live = true
    @State private var background = false
    @State private var at: Date?
    var body: some View {
        let d = m.devices.first { $0.id == device.id } ?? device
        let aspect: Aspect = d.kind == .simulator ? .ios : .android
        HStack(alignment: .top, spacing: 20) {
            if let image {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 420, maxHeight: 780)
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                    .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(aspect.color.opacity(0.6), lineWidth: 1))
            } else {
                // Until the first frame: a quiet device shape that says what is happening, not an empty frame.
                let waiting = !live || background
                VStack(spacing: 14) {
                    Image(systemName: d.kind == .simulator ? "iphone" : "candybarphone").font(.system(size: 44, weight: .ultraLight))
                        .foregroundStyle(aspect.color.opacity(0.45))
                    HStack(spacing: 7) {
                        if !waiting && !failed { ProgressView().controlSize(.mini) }
                        Text(failed ? "Could not capture the screen" : !live ? "Paused" : background ? "Waiting" : "Capturing the screen").hudLabel(failed ? Color(hex: 0xFF8A3D) : nil)
                    }
                    Text(failed ? "Trying again every 3 s." : !live ? "Resume to see the screen." : background ? "Frames are taken only while RigWatch is the app in front." : "The first frame can take a few seconds on a busy Mac.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(width: 200)
                }
                .frame(width: 300, height: 650)
                .background(RoundedRectangle(cornerRadius: 40).fill(aspect.color.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 40).strokeBorder(HUD(scheme: scheme).line, lineWidth: 1))
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack { Dot(color: live && !background ? Color(hex: 0x3DDC97) : Aspect.process.color); Text(!live ? "Paused" : background ? "Paused while RigWatch is in the background" : "Live · every 3 s").hudLabel() }
                Text(d.name).font(.system(size: 22, weight: .semibold)).lineLimit(1)
                HStack(spacing: 20) {
                    Readout(label: "CPU", value: Fmt.cpu(d.cpu), color: Heat.cpu(d.cpu).readable(scheme), size: 20)
                    Readout(label: "Memory", value: Fmt.bytes(d.mem), color: Aspect.memory.color.readable(scheme), size: 20)
                }
                if !d.foreground.isEmpty {
                    Text("On screen").hudLabel()
                    Text(d.kind == .simulator ? d.foreground : Views.short(d.foreground).screen + " · " + Views.short(d.foreground).app).font(.system(size: 12))
                }
                if let l = d.launchedBy { Text("Launched by").hudLabel(); SessionLink(id: l) }
                if !d.recentUsers.isEmpty {
                    Text("Used by").hudLabel()
                    ForEach(d.recentUsers.sorted { $0.value > $1.value }.prefix(3), id: \.key) { u in
                        HStack { SessionLink(id: u.key); Text(Fmt.ago(u.value)).hudLabel().fixedSize() }
                    }
                }
                if let a = d.lastAction {
                    Text("Last command here").hudLabel(Aspect.claude.color.readable(scheme))
                    Text("$ " + a.command).font(.system(size: 10.5, design: .monospaced)).lineLimit(6).textSelection(.enabled)
                }
                if let s = m.session(d.lastAction?.session ?? d.recentUsers.max { $0.value < $1.value }?.key ?? d.launchedBy) {
                    Text("Session's last ask").hudLabel()
                    Text(s.lastPrompt.ifEmpty("—")).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(6)
                    OpenSessionButton(session: s)
                }
                Spacer()
                HStack {
                    Button(live ? "Pause" : "Resume") { live.toggle() }.buttonStyle(HUDButton(color: aspect.color))
                    Text(at.map { "Updated \($0.formatted(date: .omitted, time: .standard))" } ?? "No frame yet").hudLabel().lineLimit(1)
                    Spacer()
                    Button("Close") { m.liveView = nil }.buttonStyle(HUDButton(color: Aspect.process.color)).keyboardShortcut(.defaultAction)
                }
            }.frame(width: 340)
        }
        .padding(22)
        .background(GridBackground())
        // A frame every 3 s, the first at once. Each capture makes the device render and encode its screen,
        // so nothing is captured while RigWatch is not the app in front.
        .task(id: live) {
            var due = Date.distantPast
            while live && !Task.isCancelled {
                background = !NSApp.isActive
                if !background && Date() >= due {
                    let dev = device
                    let data = await Task.detached(priority: .utility) { DeviceSampler.screenshot(dev) }.value
                    guard live, !Task.isCancelled else { break }
                    if let data, let img = NSImage(data: data) { image = img; failed = false; at = Date() } else if image == nil { failed = true }
                    due = Date().addingTimeInterval(3)
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }
}

/// What a confirmed action is doing: a spinner while it runs, then its result. A success fades after a
/// few seconds; a failure stays until dismissed, so it can't go unnoticed.
struct ActionBar: View {
    @ObservedObject private var m = Monitor.shared
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let hud = HUD(scheme: scheme)
        VStack(spacing: 6) {
            ForEach(m.working, id: \.self) { t in
                row {
                    ProgressView().controlSize(.small)
                    Text("\(t) · working…").font(.system(size: 12, weight: .semibold))
                }.overlay(Rectangle().strokeBorder(hud.accent.opacity(0.6), lineWidth: 0.8))
            }
            if let o = m.outcome {
                let color = o.failed ? Color(hex: 0xFF4D5E) : Color(hex: 0x3DDC97)
                row {
                    Image(systemName: o.failed ? "xmark.octagon.fill" : "checkmark.circle.fill").foregroundStyle(color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(o.failed ? "\(o.title) failed" : o.title).font(.system(size: 12, weight: .semibold))
                        Text(o.text).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    Spacer(minLength: 8)
                    Button { m.outcome = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Dismiss")
                }
                .overlay(Rectangle().strokeBorder(color.opacity(0.8), lineWidth: 1))
                .task(id: o.id) {
                    guard !o.failed else { return }
                    try? await Task.sleep(for: .seconds(8))
                    if m.outcome?.id == o.id { m.outcome = nil }
                }
            }
        }
        .frame(maxWidth: 620)
        .animation(.easeOut(duration: 0.2), value: m.working)
        .animation(.easeOut(duration: 0.2), value: m.outcome)
    }

    func row<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 10) { c() }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Rectangle().fill(HUD(scheme: scheme).panel))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
    }
}
