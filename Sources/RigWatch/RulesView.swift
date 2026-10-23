import SwiftUI

/// The Rules page: the build queue live, each rule with its settings, what the clean-up will do or
/// last did, and the log of what it has done.
struct RulesView: View {
    @ObservedObject private var m = Monitor.shared
    @Environment(\.colorScheme) private var scheme
    @State private var s = Demo.on ? RuleSettings() : RuleSettings.load()
    @State private var jobs: [BuildJob] = []
    @State private var report: ReapReport?
    @State private var preview = false          // report is a dry run from Preview, not the last real run
    @State private var previewing = false
    @State private var log: [String] = []
    @State private var hook = false
    @State private var agent = false
    @State private var pins: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                SectionTitle(title: "Build queue", aspect: .rules, count: jobs.count)
                queue
                SectionTitle(title: "Rules", aspect: .rules)
                rules
                HStack(spacing: 10) {
                    SectionTitle(title: preview ? "Clean-up preview" : "Last clean-up", aspect: .rules, count: report?.actions.count)
                    let cleaning = m.busy.contains(Self.cleanTitle)
                    Button(previewing ? "Checking" : "Preview") { runPreview() }.buttonStyle(HUDButton(color: Aspect.rules.color)).disabled(previewing || cleaning)
                        .help("What the clean-up would do now. Changes nothing.")
                    Button { confirmCleanup() } label: {
                        if cleaning { HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Cleaning…") } }
                        else { Label("Clean up now", systemImage: "sparkles") }
                    }.buttonStyle(HUDButton(color: Color(hex: 0xFF4D5E))).disabled(cleaning || previewing)
                }
                cleanup
                SectionTitle(title: "Log", aspect: .process, count: log.count)
                Panel(aspect: .process, padding: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(log.enumerated()), id: \.offset) { _, l in
                            Text(l).font(.system(size: 10.5, design: .monospaced)).lineLimit(2).textSelection(.enabled)
                        }
                        if log.isEmpty { Text("Nothing done yet").hudLabel() }
                    }
                }
            }.padding(20)
        }
        .task { while !Task.isCancelled { reload(); try? await Task.sleep(for: .seconds(2)) } }
        .onChange(of: s) { _, new in if !Demo.on { new.save() } }
    }

    func reload() {
        if Demo.on {
            jobs = Demo.jobs(); log = Demo.ruleLog(); hook = true; agent = true
            if report == nil { report = Demo.reapReport() }
            return
        }
        jobs = Rules.jobs().sorted { ($0.state == "running" ? 0 : 1, $0.since) < ($1.state == "running" ? 0 : 1, $1.since) }
        if !preview { report = Rules.lastReport() }
        log = Rules.logTail(40)
        hook = Rules.hookInstalled(); agent = Rules.agentInstalled()
        pins = Rules.pins()
    }

    // MARK: header

    var header: some View {
        let running = jobs.filter { $0.state == "running" }, waiting = jobs.filter { $0.state == "waiting" }
        let on = hook && agent
        let pressure = Demo.on ? 1 : Rules.pressure()
        let allowed = Demo.on ? s.parallelBuilds : max(1, Rules.limit(s) / 2)
        return Panel(aspect: .rules) {
            HStack(alignment: .center, spacing: 26) {
                Readout(label: "Building", value: "\(running.count)", unit: "of \(allowed) at once", color: Aspect.rules.color.readable(scheme), size: 30)
                Readout(label: "Waiting", value: "\(waiting.count)", color: (waiting.isEmpty ? Color.primary : Color(hex: 0xFFD23F).readable(scheme)), size: 30)
                Readout(label: "Memory pressure", value: Views.pressureName(pressure), color: Views.pressureColor(pressure).readable(scheme), size: 22)
                Readout(label: "Last clean-up", value: Fmt.ago(Demo.on ? report?.at : Rules.lastReport()?.at), size: 22)
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 8) {
                    HStack(spacing: 6) {
                        Chip(text: hook ? "HOOK ON" : "HOOK OFF", icon: "link", color: hook ? Color(hex: 0x3DDC97) : Aspect.process.color, filled: hook)
                        Chip(text: agent ? "CLEAN-UP ON" : "CLEAN-UP OFF", icon: "clock.arrow.circlepath", color: agent ? Color(hex: 0x3DDC97) : Aspect.process.color, filled: agent)
                        if s.paused { Chip(text: "PAUSED", icon: "pause.fill", color: Color(hex: 0xFFD23F), filled: true) }
                    }.fixedSize()
                    HStack(spacing: 6) {
                        Button(s.paused ? "Resume" : "Pause") { s.paused.toggle() }.buttonStyle(HUDButton(color: Color(hex: 0xFFD23F)))
                            .help("Paused: builds run straight away and the clean-up only reports")
                        if on || hook || agent {
                            Button("Turn off") { confirmUninstall() }.buttonStyle(HUDButton(color: Color(hex: 0xFF4D5E)))
                        }
                        if !on {
                            Button { confirmInstall() } label: { Label("Turn on", systemImage: "power") }.buttonStyle(HUDButton(color: Aspect.rules.color, filled: true))
                        }
                    }.fixedSize()
                }
            }
        }
    }

    func confirmInstall() {
        let exe = Rules.installExe
        var msg = "Adds a hook to Claude Code (\(Views.tilde(Rules.claudeSettings)); the old file is kept as settings.json.rigwatch-backup). Every session's shell commands then pass through RigWatch:"
        msg += "\n• Gradle, xcodebuild and npm/yarn/pod installs wait for a free build slot."
        msg += "\n• Booting an emulator or simulator is refused while a phone of that kind is connected or another one is already running."
        msg += "\n\nAlso starts a background clean-up every 10 minutes (a LaunchAgent). For its first hour it only reports."
        msg += "\n\nRuns \(Views.tilde(exe))."
        if exe.contains("/Cellar/") || exe.contains("/.build/") { msg += "\n\n⚠️ That path changes when RigWatch is updated: turn the rules on from the copy in ~/Applications instead." }
        m.pending = Pending(title: "Turn on the rules?", message: msg, button: "Turn On") { Rules.install(exe: exe) }
    }

    func confirmUninstall() {
        m.pending = Pending(title: "Turn off the rules?", message: "Removes RigWatch's hook from Claude Code's settings and stops the clean-up agent. Builds already queued still run.", button: "Turn Off") { Rules.uninstall() }
    }

    // MARK: queue

    @ViewBuilder var queue: some View {
        let outside = Demo.on ? [] : Rules.outsideQueue(m.procs)
        if jobs.isEmpty {
            Text(outside.isEmpty ? "No build running or waiting" : "No build is going through the queue right now").hudLabel().padding(.leading, 14)
        } else {
            Panel(aspect: .rules, padding: 12) {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(jobs) { j in
                        HStack(spacing: 10) {
                            Chip(text: j.state.uppercased(), color: j.state == "running" ? Color(hex: 0x3DDC97) : Color(hex: 0xFFD23F), filled: j.state == "running").frame(width: 76, alignment: .leading)
                            Chip(text: j.kind.uppercased(), color: j.kind == "xcodebuild" ? Aspect.ios.color : j.kind == "gradle" ? Aspect.android.color : Aspect.process.color).fixedSize()
                            Text((j.cwd as NSString).lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1).help(Views.tilde(j.cwd))
                            Text(j.cmd).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(j.cmd)
                            Spacer(minLength: 8)
                            Text("\(j.state == "running" ? "for" : "waited") \(Fmt.ago(j.since).replacingOccurrences(of: " ago", with: ""))").hudLabel().fixedSize()
                            Text("pid \(j.pid)").font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.tertiary).fixedSize()
                        }
                    }
                }
            }
        }
        if !outside.isEmpty {
            SectionTitle(title: "Running outside the queue", aspect: .process, count: outside.count)
            Panel(aspect: .process, padding: 12) {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(outside) { b in
                        HStack(spacing: 10) {
                            Chip(text: b.kind.uppercased(), color: b.kind == "xcodebuild" ? Aspect.ios.color : Aspect.android.color).fixedSize()
                            Text(b.cwd.map { ($0 as NSString).lastPathComponent } ?? "pid \(b.pid)").font(.system(size: 12, weight: .medium)).lineLimit(1).help(b.cwd.map(Views.tilde) ?? "")
                            if let id = b.session { SessionLink(id: id) }
                            Text(b.reason).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Color(hex: 0xFFD23F).readable(scheme)).lineLimit(2).help(b.reason)
                            Spacer(minLength: 8)
                            Text(Fmt.cpu(b.cpu)).font(.system(size: 10.5, design: .monospaced)).fixedSize()
                            Text("started \(Fmt.ago(b.since))").hudLabel().fixedSize()
                        }
                    }
                    Text("These builds run at full speed next to the queued ones, so the queue can't keep the Mac responsive while they run.")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: rules

    var rules: some View {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        return Panel(aspect: .rules, padding: 14) {
            VStack(alignment: .leading, spacing: 14) {
                rule("Queue heavy builds", $s.queueBuilds,
                     "Gradle, xcodebuild and npm, yarn or pod installs from every agent session wait for a free slot, first come first served, and run at a priority that leaves the rest of the Mac responsive. Half the builds under a memory pressure warning, one at a time when it is critical.") {
                    Stepper(value: $s.parallelBuilds, in: 1...6) { setting("\(s.parallelBuilds) at once") }
                    Stepper(value: $s.buildThreads, in: 1...max(1, cores)) { setting("\(s.buildThreads) threads each") }
                }
                rule("Physical devices first", $s.physicalFirst,
                     "Booting an emulator or simulator is refused while a phone of that kind is connected, or another virtual one is already running. Putting RIGWATCH_VIRTUAL=1 in front of the command lets it through.") { EmptyView() }
                rule("Shut down idle emulators and simulators", $s.reapDevices,
                     "After this long with no command or device tool naming it. Only ones an agent session started; one you opened yourself is never shut down. Pinned devices are kept.") {
                    Stepper(value: $s.deviceIdleMinutes, in: 10...240, step: 10) { setting("\(s.deviceIdleMinutes) min") }
                    Stepper(value: $s.deviceIdleWithPhoneMinutes, in: 5...240, step: 5) { setting("\(s.deviceIdleWithPhoneMinutes) min with a phone connected") }
                }
                rule("Clean up idle worktrees", $s.reapWorktrees,
                     "Untouched for this long: a clean worktree is removed, its branch and commits stay. One with uncommitted work, commits on no remote or untracked files keeps its source and loses only build folders git ignores (and node_modules, which is kept aside and cloned back into the next worktree with the same lockfile). Never a main checkout, a locked worktree or one a process is using.") {
                    Stepper(value: $s.worktreeIdleHours, in: 6...336, step: 6) { setting("\(s.worktreeIdleHours) h") }
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("Never clean up").font(.system(size: 13, weight: .semibold))
                    Text("Folders the clean-up leaves alone completely: no worktree, build output or DerivedData of a project in them. Separate with commas, e.g. ~/work, ~/clients. Worktrees Claude Code manages itself are always left alone.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    TextField("~/work, ~/clients", text: Binding(
                        get: { s.neverClean.joined(separator: ", ") },
                        set: { s.neverClean = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
                        .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced)).frame(maxWidth: 420)
                }.padding(.leading, 46)
                rule("Delete orphaned DerivedData", $s.reapDerivedData,
                     "Xcode build folders untouched for a day whose project is provably gone: its folder can be read and no longer holds it. Projects on external drives or in folders macOS guards are left alone.") { EmptyView() }
            }
        }
    }

    func setting(_ t: String) -> some View { Text(t).font(.system(size: 11, weight: .semibold, design: .monospaced)).monospacedDigit() }

    func rule<Extra: View>(_ title: String, _ on: Binding<Bool>, _ text: String, @ViewBuilder extra: () -> Extra) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: on).toggleStyle(.switch).labelsHidden().controlSize(.small)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(on.wrappedValue ? .primary : .secondary)
                Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 18) { extra() }.disabled(!on.wrappedValue)
            }
        }
    }

    // MARK: clean-up

    @ViewBuilder var cleanup: some View {
        Panel(aspect: .rules, padding: 12) {
            VStack(alignment: .leading, spacing: 9) {
                if m.busy.contains(Self.cleanTitle) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Cleaning up now. Worktrees are measured and removed one at a time, so this can take a few minutes; the result shows here when it is done.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(.bottom, 4)
                }
                if let r = report {
                    HStack(spacing: 8) {
                        Text(Rules.stamp.string(from: r.at)).font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        let failures = r.actions.filter(\.failed).count
                        Chip(text: preview ? "PREVIEW" : r.applied ? "APPLIED" : "REPORTED ONLY", color: r.applied ? Color(hex: 0x3DDC97) : Color(hex: 0xFFD23F), filled: r.applied)
                        if !preview && failures > 0 { Chip(text: "\(failures) FAILED", color: Color(hex: 0xFF4D5E), filled: true) }
                        let total = r.actions.filter { $0.kind != "Shut down" }.compactMap(\.bytes).reduce(0, +)
                        if total > 0 { Text("\(r.applied ? "freed" : "would free") ~\(Fmt.bytes(total)) of disk").hudLabel(Color(hex: 0x3DDC97).readable(scheme)) }
                    }
                    ForEach(r.notes, id: \.self) { Text($0).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary) }
                    ForEach(r.actions) { a in actionRow(a) }
                    if r.actions.isEmpty { Text("Nothing to clean up").hudLabel() }
                    if !r.kept.isEmpty {
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(r.kept, id: \.self) { Text($0).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2) }
                            }.padding(.top, 4)
                        } label: { Text("Checked and kept (\(r.kept.count))").hudLabel() }
                    }
                } else {
                    Text(agent ? "The clean-up has not run yet" : "Turn the rules on to clean up on a schedule, or press Preview to see what it would do").hudLabel()
                }
                Text("The clean-up runs every 10 minutes; worktrees and DerivedData are checked once an hour.").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
    }

    func actionRow(_ a: ReapAction) -> some View {
        let device = a.kind == "Shut down"
        let color = device ? Aspect.android.color : a.kind == "Remove worktree" || a.kind == "Prune" ? Aspect.worktree.color : Aspect.disk.color
        return HStack(spacing: 10) {
            Chip(text: a.kind.uppercased(), color: color).fixedSize()
            Text(a.target).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
            Text(a.detail).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2).help(a.detail)
            Spacer(minLength: 8)
            if let b = a.bytes, b > 0 { Text(Fmt.bytes(b) + (device ? " RAM" : "")).font(.system(size: 11, weight: .semibold, design: .monospaced)).fixedSize() }
            if let res = a.result {
                let (icon, color): (String, Color) = a.outcome == "failed" ? ("xmark", Color(hex: 0xFF4D5E)) : a.outcome == "kept" ? ("minus", Color(hex: 0xFFD23F)) : ("checkmark", Color(hex: 0x3DDC97))
                if a.outcome == "failed" || a.outcome == "kept" {
                    Text(res).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(color.readable(scheme)).lineLimit(2).help(res)
                }
                Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundStyle(color).help(res)
            }
            if device {
                let pinned = pins.contains(a.key)
                Button(pinned ? "Unpin" : "Pin") { if !Demo.on { Rules.setPin(a.key, !pinned); pins = Rules.pins() } }
                    .buttonStyle(HUDButton(color: Aspect.rules.color, filled: pinned)).help("A pinned device is never shut down by the clean-up")
            }
        }
    }

    func runPreview() {
        if Demo.on { report = Demo.reapReport(); preview = true; return }
        previewing = true
        Task {
            let r = await Task.detached(priority: .utility) { Rules.reap(apply: false, explicit: true) }.value
            report = r; preview = true; previewing = false
        }
    }

    static let cleanTitle = "Clean up now?"

    func confirmCleanup() {
        var msg = "Runs every rule that is on, now: shuts down idle emulators and simulators, removes clean idle worktrees, strips build output from the rest and deletes orphaned DerivedData. Nothing with uncommitted or unpushed work is removed."
        if preview, let r = report { msg += r.actions.isEmpty ? "\n\nThe preview found nothing to do." : "\n\nThe preview found \(r.actions.count): " + r.actions.prefix(6).map { "\($0.kind.lowercased()) \($0.target)" }.joined(separator: "; ") + (r.actions.count > 6 ? "; …" : "") }
        else { msg += "\n\nPress Preview first to see the list." }
        if s.paused { msg = "Rules are paused, so this only reports what it would do: nothing is shut down, removed or deleted.\n\n" + msg }
        m.pending = Pending(title: Self.cleanTitle, message: msg, button: "Clean Up") {
            let r = Rules.reap(apply: true, explicit: true)
            Rules.saveReport(r)
            if let note = r.notes.first(where: { $0.hasPrefix("Another") || $0.hasPrefix("Rules are paused") }) { return note }
            if r.actions.isEmpty { return "Clean-up finished: nothing to clean up." }
            let failed = r.actions.filter(\.failed).count, kept = r.actions.filter { $0.outcome == "kept" }.count
            var msg = "Clean-up finished: \(r.actions.count - failed - kept) done"
            if kept > 0 { msg += ", \(kept) kept by a safety check" }
            if failed > 0 { msg += ", \(failed) FAILED" }
            return msg + ". Details under Last clean-up."
        }
        preview = false
    }
}
