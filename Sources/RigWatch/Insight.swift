import AppKit
import SwiftUI

/// Which list the Top sheet shows.
enum TopKind: String, Identifiable { case cpu, memory; var id: String { rawValue } }

/// What can be done about a process, using the same confirmations as the rest of the app.
enum Fix {
    case quitSession(Session), stop(DevServer), shutDown(Device), openDevices, quitApp(String), quit(Proc)
    var label: String {
        switch self {
        case .quitSession: "Quit session"; case .stop: "Stop"; case .shutDown: "Shut down"; case .openDevices: "Open"
        case .quitApp: "Quit app"; case .quit: "Quit"
        }
    }
    var icon: String {
        switch self {
        case .quitSession: "xmark.circle"; case .stop: "stop.circle"; case .shutDown: "power"; case .openDevices: "arrow.up.right"
        case .quitApp: "xmark.app"; case .quit: "xmark"
        }
    }
}

// MARK: who started what

extension Monitor {
    /// The agent session a process belongs to: the id it inherited, or the agent tree it runs in.
    func sessionId(_ p: Proc) -> String? { p.session ?? agentOwner[p.pid] }

    func sessionTitle(_ id: String) -> String { session(id)?.title ?? String(id.prefix(8)) }

    /// Who started a process, in plain words.
    func owner(_ p: Proc) -> String {
        if let id = sessionId(p) { return "started by \(sessionTitle(id))" }
        if let d = servers.first(where: { $0.pid == p.pid }) { return "dev server \(d.label) · \(startedBy(d))" }
        if p.group == "Android emulators" { return "Android emulator" }
        if p.group == "iOS simulators" { return "iOS simulator" }
        if p.path.contains(".app/") { return "app \(p.group)" }
        if p.uid == 0 { return "macOS (runs as root)" }
        if p.group == "macOS services" { return "macOS" }
        return p.ppid == 1 ? "started by launchd" : "started by you"
    }

    /// Who started most of a group: the session behind over half its load, else its top process's owner.
    func owner(_ g: ProcGroup, byCPU: Bool) -> String {
        let ps = procs.filter { $0.group == g.name }
        func load(_ p: Proc) -> Double { byCPU ? p.cpu : Double(p.mem) }
        let total = ps.reduce(0) { $0 + load($1) }
        var bySession: [String: Double] = [:]
        for p in ps { if let id = sessionId(p) { bySession[id, default: 0] += load(p) } }
        if let (id, v) = bySession.max(by: { $0.value < $1.value }), total > 0, v / total > 0.5 { return "started by \(sessionTitle(id))" }
        return ps.max { load($0) < load($1) }.map(owner) ?? ""
    }

    /// The most useful single action for a process, or nil when it should be left alone.
    func fix(_ p: Proc) -> Fix? {
        if let s = sessions.first(where: { $0.live && ($0.pids[p.pid] != nil || (Demo.on && p.name == "claude" && p.session == $0.id)) }) { return .quitSession(s) }
        if let d = servers.first(where: { $0.pid == p.pid }) { return .stop(d) }
        if p.name.hasPrefix("qemu-system") || p.name == "launchd_sim" {
            return devices.first { $0.pid == p.pid }.map { .shutDown($0) } ?? .openDevices
        }
        if p.group == "Android emulators" || p.group == "iOS simulators" { return .openDevices }
        if p.path.contains(".app/"), appRunning(p.group) { return .quitApp(p.group) }
        if Safety.processBlock(p) == nil { return .quit(p) }
        return nil
    }

    func run(_ f: Fix) {
        switch f {
        case .quitSession(let s): confirmQuitSession(s)
        case .stop(let d): confirmStop(d)
        case .shutDown(let d): confirmShutDown(d)
        case .openDevices: top = nil; tab = .devices; refresh()
        case .quitApp(let name): confirmQuitApp(name)
        case .quit(let p): confirmQuit(p)
        }
    }

    // MARK: quitting an app

    /// Apps that are never quit from here: macOS itself, the Claude app (it hosts desktop sessions) and RigWatch.
    static let keepApps: Set<String> = ["Finder", "Claude", "RigWatch", "loginwindow", "Dock", "SystemUIServer", "ControlCenter", "WindowServer"]

    func runningApp(_ name: String) -> NSRunningApplication? {
        guard !Self.keepApps.contains(name) else { return nil }
        return NSWorkspace.shared.runningApplications.first { $0.activationPolicy == .regular && $0.bundleURL?.deletingPathExtension().lastPathComponent == name }
    }

    func appRunning(_ name: String) -> Bool { Demo.on ? !Self.keepApps.contains(name) : runningApp(name) != nil }

    /// Quit app = what ⌘Q does: the app is asked to quit and may ask to save first.
    func confirmQuitApp(_ name: String) {
        if Demo.on { toast = "Demo mode: nothing was changed."; return }
        guard let app = runningApp(name) else { toast = "\(name) is not running as an app RigWatch can quit."; return }
        let g = groups.first { $0.name == name }
        var msg = "\(name)" + (g.map { " · \($0.count) process(es) · CPU \(Fmt.cpu($0.cpu)) · \(Fmt.bytes($0.mem))" } ?? "")
        let hosted = sessions.filter { s in s.live && procs.contains { $0.group == name && sessionId($0) == s.id } }
        if let s = hosted.first(where: \.isWorking) { msg += "\n\n⚠️ \(s.title) runs in \(name) and is working right now." }
        else if !hosted.isEmpty { msg += "\n\n⚠️ Agent sessions run in \(name): \(hosted.map(\.title).joined(separator: ", "))." }
        msg += "\n\nQuit asks \(name) to quit, the same as ⌘Q: it may ask to save open work first."
        pending = Pending(title: "Quit \(name)?", message: msg, button: "Quit App") {
            DispatchQueue.main.sync { app.terminate() } ? "Asked \(name) to quit." : "\(name) did not accept the request to quit."
        }
    }
}

// MARK: Top CPU / Top memory

/// What is using the CPU (or memory) right now: the top groups, their biggest processes, who started
/// each one and what can be done about it.
struct TopSheet: View {
    @ObservedObject private var m = Monitor.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let byCPU = m.top != .memory
        let s = m.sys
        let groups = m.groups.filter { byCPU ? $0.cpu > 0 : $0.mem > 0 }.sorted { byCPU ? $0.cpu > $1.cpu : $0.mem > $1.mem }.prefix(8)
        let maxV = groups.map { byCPU ? $0.cpu : Double($0.mem) }.max() ?? 1
        let aspect: Aspect = byCPU ? .cpu : .memory
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom, spacing: 22) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(byCPU ? "Top CPU right now" : "Top memory right now").font(.system(size: 20, weight: .semibold))
                    Text(byCPU ? "share of the whole machine · 100% = all \(s.cores.count) cores busy" : "your processes: physical footprint · others: resident size").hudLabel()
                }
                Spacer()
                if byCPU { Readout(label: "Machine", value: "\(Int(s.cpu))", unit: "%", color: Heat.ratio(s.cpu / 100).readable(scheme), size: 26) }
                else { Readout(label: "Used", value: Fmt.bytes(s.memUsed), unit: "of \(Fmt.bytes(s.memTotal))", color: Views.pressureColor(s.pressure).readable(scheme), size: 26) }
                HStack(spacing: 0) {
                    Button("CPU") { m.top = .cpu }.buttonStyle(HUDButton(color: Aspect.cpu.color, filled: byCPU))
                    Button("Memory") { m.top = .memory }.buttonStyle(HUDButton(color: Aspect.memory.color, filled: !byCPU))
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(groups.enumerated()), id: \.element.id) { i, g in
                        groupRow(i, g, byCPU: byCPU, ratio: (byCPU ? g.cpu : Double(g.mem)) / max(maxV, 1), aspect: aspect)
                    }
                    if groups.isEmpty { Text("Nothing measured yet").hudLabel() }
                }
            }
            HStack {
                Text("Every action asks first. System processes are explained, not quit.").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Button { m.top = nil; m.tab = byCPU ? .processes : .memory } label: { Label(byCPU ? "All processes" : "Memory page", systemImage: "arrow.up.right") }
                    .buttonStyle(HUDButton(color: aspect.color))
                Button("Close") { m.top = nil }.buttonStyle(HUDButton(color: Aspect.process.color)).keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 820, height: 640)
        .background(GridBackground())
        .overlay(Rectangle().strokeBorder(Aspect.cpu.color.opacity(0.5), lineWidth: 0.8))
        .overlay(Brackets(len: 12).stroke(Aspect.cpu.color.readable(scheme), lineWidth: 1.6))
        .shadow(color: .black.opacity(0.35), radius: 30)
    }

    func value(_ cpu: Double, _ mem: UInt64, byCPU: Bool) -> String { byCPU ? Fmt.cpu(cpu) : Fmt.bytes(mem) }

    @ViewBuilder func groupRow(_ i: Int, _ g: ProcGroup, byCPU: Bool, ratio: Double, aspect: Aspect) -> some View {
        let ps = m.procs.filter { $0.group == g.name }.sorted { byCPU ? $0.cpu > $1.cpu : $0.mem > $1.mem }.prefix(3)
        let a = Aspect.forGroup(g.name)
        Panel(aspect: aspect, padding: 11) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(String(format: "%02d", i + 1)).font(.system(size: 9.5, weight: .bold, design: .monospaced)).foregroundStyle(.tertiary)
                    Image(systemName: a.icon).font(.system(size: 11)).foregroundStyle(a.color.readable(scheme)).frame(width: 16)
                    Text(g.name).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                    if g.count > 1 { Text("×\(g.count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary) }
                    Text(m.owner(g, byCPU: byCPU)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(value(g.cpu, g.mem, byCPU: byCPU)).font(.system(size: 14, weight: .semibold, design: .monospaced)).monospacedDigit().lineLimit(1).fixedSize()
                    Text(value(g.cpu, g.mem, byCPU: !byCPU)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                }
                Meter(value: ratio, color: aspect.color, height: 3, segments: 60)
                ForEach(ps) { p in procRow(p, byCPU: byCPU) }
            }
        }
    }

    @ViewBuilder func procRow(_ p: Proc, byCPU: Bool) -> some View {
        let f = m.fix(p)
        HStack(spacing: 8) {
            Text("└").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary).padding(.leading, 26)
            Text(p.name).font(.system(size: 11.5)).lineLimit(1).help(p.path)
            Text("pid \(p.pid)").font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.tertiary).fixedSize()
            Text(m.owner(p)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            Text(value(p.cpu, p.mem, byCPU: byCPU)).font(.system(size: 11, weight: .semibold, design: .monospaced)).monospacedDigit().lineLimit(1).fixedSize()
            if let f {
                Button { m.run(f) } label: { Label(f.label, systemImage: f.icon) }
                    .buttonStyle(HUDButton(color: { if case .openDevices = f { Aspect.android.color } else { Color(hex: 0xFF4D5E) } }()))
            } else {
                Text(Safety.processBlock(p).map { "leave: \($0)" } ?? "").font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1).fixedSize()
            }
            Button { m.top = nil; m.procSearch = "\(p.pid)"; m.tab = .processes } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(HUDButton(color: Aspect.process.color)).help("Show in Processes")
        }
    }
}
