import SwiftUI

/// Every Gradle, xcodebuild and install build on the Mac: what holds a slot, what waits and how long it can
/// wait at most, what runs outside the queue (and is held to a lower priority), and how recent builds went.
struct BuildsView: View {
    @ObservedObject private var m = Monitor.shared
    @Environment(\.colorScheme) private var scheme
    private let green = Color(hex: 0x3DDC97), amber = Color(hex: 0xFFD23F), orange = Color(hex: 0xFF8A3D), red = Color(hex: 0xFF4D5E)

    var body: some View {
        let s = Demo.on ? RuleSettings() : RuleSettings.load()
        let running = m.jobs.filter { $0.state == "running" }.sorted { $0.since < $1.since }
        let waiting = m.jobs.filter { $0.state == "waiting" }.sorted { ($0.queuedAt ?? $0.since) < ($1.queuedAt ?? $1.since) }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(s, running, waiting)
                SectionTitle(title: "Building in the queue", aspect: .cpu, count: running.count)
                if running.isEmpty { Text("No queued build is running").hudLabel().padding(.leading, 14) }
                else { rows { ForEach(running) { runningRow($0) } } }
                SectionTitle(title: "Waiting", aspect: .cpu, count: waiting.count)
                if waiting.isEmpty { Text("Nothing is waiting for a slot").hudLabel().padding(.leading, 14) }
                else { rows { ForEach(waiting) { waitingRow($0, waiting, s) } } }
                SectionTitle(title: "Running outside the queue", aspect: .process, count: m.outside.count)
                if m.outside.isEmpty { Text("Every running build goes through the queue").hudLabel().padding(.leading, 14) }
                else {
                    rows { ForEach(m.outside) { outsideRow($0) } }
                    Text(BuildGovernor.active
                         ? "These run at lower priority (nice \(BuildGovernor.nice)), with everything they start, so they can't take the Mac over; they don't wait for a slot."
                         : "Their priority is not lowered: \(s.lowerOutside ? "the rules are off or paused" : "\"Lower the priority of builds outside the queue\" is off on the Rules page").")
                        .hudLabel()
                }
                SectionTitle(title: "Recent builds", aspect: .cpu, count: m.buildHistory.count)
                if m.buildHistory.isEmpty { Text("No queued build has finished yet").hudLabel().padding(.leading, 14) }
                else { rows { ForEach(m.buildHistory.prefix(30)) { historyRow($0) } } }
                Text("Agents' Gradle, xcodebuild and npm, yarn or pod installs wait for a slot of their platform (set on the Rules page), first come first served. A slot is held only while the build tool runs, not while the rest of the command does, and nothing waits longer than \(s.maxWaitMinutes) min: then it starts anyway at background priority.")
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
            }.padding(20)
        }
    }

    // MARK: header

    func header(_ s: RuleSettings, _ running: [BuildJob], _ waiting: [BuildJob]) -> some View {
        let used = { (p: String) in running.filter { Rules.pool($0) == p && $0.overflow != true }.reduce(0) { $0 + $1.weight } / 2 }
        let pressure = Demo.on ? 1 : Rules.pressure()
        return Panel(aspect: .cpu) {
            HStack(alignment: .center, spacing: 26) {
                Readout(label: "Android", value: "\(used("android"))", unit: "of \(s.androidBuilds)", color: Aspect.android.color.readable(scheme), size: 30)
                Readout(label: "iOS", value: "\(used("ios"))", unit: "of \(s.iosBuilds)", color: Aspect.ios.color.readable(scheme), size: 30)
                Readout(label: "Waiting", value: "\(waiting.count)", color: waiting.isEmpty ? .primary : amber.readable(scheme), size: 30)
                Readout(label: "Outside the queue", value: "\(m.outside.count)", color: m.outside.isEmpty ? .primary : orange.readable(scheme), size: 30)
                Readout(label: "Memory pressure", value: Views.pressureName(pressure), color: Views.pressureColor(pressure).readable(scheme), size: 22)
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 6) {
                    Chip(text: "MAX WAIT \(s.maxWaitMinutes) MIN", icon: "timer", color: Aspect.process.color)
                    Chip(text: BuildGovernor.active ? "OUTSIDE BUILDS LOWERED" : "OUTSIDE BUILDS NOT LOWERED", icon: "arrow.down.circle",
                         color: BuildGovernor.active ? green : Aspect.process.color, filled: BuildGovernor.active)
                }
            }
        }
    }

    // MARK: rows

    func rows<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        Panel(aspect: .cpu, padding: 12) { VStack(alignment: .leading, spacing: 10) { content() } }
    }

    func kindChip(_ kind: String) -> some View {
        Chip(text: kind.uppercased(), color: kind == "xcodebuild" ? Aspect.ios.color : kind == "gradle" ? Aspect.android.color : Aspect.process.color).fixedSize()
    }

    func project(_ cwd: String?) -> some View {
        Text(cwd.map { ($0 as NSString).lastPathComponent } ?? "?").font(.system(size: 12.5, weight: .medium)).lineLimit(1).help(cwd.map(Views.tilde) ?? "")
    }

    func runningRow(_ j: BuildJob) -> some View {
        HStack(spacing: 10) {
            kindChip(j.kind)
            project(j.cwd)
            if let s = j.session { SessionLink(id: s) }
            if j.overflow == true { Chip(text: "AFTER MAX WAIT · BACKGROUND", color: amber).fixedSize().help("It waited the longest allowed and started anyway, at background priority.") }
            if j.force == true { Chip(text: "STARTED NOW", color: Aspect.process.color).fixedSize() }
            Text(j.cmd).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(j.cmd)
            Spacer(minLength: 8)
            Text(Fmt.cpu(m.treeCPU(j.pid))).font(.system(size: 11, design: .monospaced)).fixedSize()
            Text("for \(Self.span(Date().timeIntervalSince(j.since)))").hudLabel().fixedSize()
            Button("Stop") { m.confirmStopBuild(j) }.buttonStyle(HUDButton(color: red))
        }
    }

    func waitingRow(_ j: BuildJob, _ all: [BuildJob], _ s: RuleSettings) -> some View {
        let q = j.queuedAt ?? j.since
        let pos = all.filter { Rules.pool($0) == Rules.pool(j) }.firstIndex { $0.pid == j.pid }.map { $0 + 1 } ?? 1
        let by = q.addingTimeInterval(TimeInterval(s.maxWaitMinutes * 60))
        return HStack(spacing: 10) {
            kindChip(j.kind)
            Text("#\(pos) \(Rules.pool(j) == "ios" ? "iOS" : "Android")").hudLabel(amber.readable(scheme)).fixedSize()
            project(j.cwd)
            if let s = j.session { SessionLink(id: s) }
            Spacer(minLength: 8)
            Text("waiting \(Self.span(Date().timeIntervalSince(q))) · starts by \(by.formatted(date: .omitted, time: .shortened))").hudLabel().fixedSize()
            Button("Start now") { m.startBuildNow(j) }.buttonStyle(HUDButton(color: green))
                .help("Start it at once, ahead of the line, beside the builds already running.")
            Button("Cancel") { m.confirmStopBuild(j) }.buttonStyle(HUDButton(color: red))
        }
    }

    func outsideRow(_ b: Rules.OutsideBuild) -> some View {
        HStack(spacing: 10) {
            kindChip(b.kind)
            project(b.cwd)
            if let s = b.session { SessionLink(id: s) }
            if m.governed.contains(b.pid) { Chip(text: "PRIORITY LOWERED", icon: "arrow.down.circle", color: green).fixedSize() }
            Text(b.reason).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(orange.readable(scheme)).lineLimit(1).truncationMode(.tail).help(b.reason)
            Spacer(minLength: 8)
            Text(Fmt.cpu(m.treeCPU(b.pid))).font(.system(size: 11, design: .monospaced)).fixedSize()
            Text("for \(Self.span(Date().timeIntervalSince(b.since ?? Date())))").hudLabel().fixedSize()
            Button("Stop") { m.confirmStopOutside(b) }.buttonStyle(HUDButton(color: red))
        }
    }

    func historyRow(_ r: BuildRecord) -> some View {
        HStack(spacing: 10) {
            kindChip(r.kind)
            project(r.cwd)
            if let s = r.session { SessionLink(id: s) }
            if r.overflow { Chip(text: "MAX WAIT", color: amber).fixedSize() }
            if r.forced { Chip(text: "STARTED NOW", color: Aspect.process.color).fixedSize() }
            if r.releasedEarly { Chip(text: "SLOT FREED EARLY", color: green).fixedSize().help("The build tool finished before the rest of its command; the slot went to the next build then.") }
            Spacer(minLength: 8)
            Text(r.endedAt.formatted(date: .omitted, time: .shortened)).hudLabel().fixedSize()
            Text("waited \(Self.span(r.waited)) · ran \(Self.span(r.ran))").font(.system(size: 10.5, design: .monospaced)).fixedSize()
            Chip(text: r.exit == 0 ? "OK" : "EXIT \(r.exit)", color: r.exit == 0 ? green : red).fixedSize()
        }
    }

    static func span(_ t: TimeInterval) -> String {
        t < 60 ? "\(Int(t)) s" : t < 3600 ? "\(Int(t / 60)) min" : String(format: "%.1f h", t / 3600)
    }
}
