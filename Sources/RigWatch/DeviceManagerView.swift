import SwiftUI

/// Every device agents can be given, who holds it, and what RigWatch could boot. The MCP server
/// (`RigWatch mcp`) hands devices out; this page is where a person sees and overrides that.
struct DeviceManagerView: View {
    @ObservedObject private var m = Monitor.shared
    @Environment(\.colorScheme) private var scheme
    @State private var registered = Demo.on || Rules.mcpInstalled()

    enum Hold: Int { case leased, inUse, held, free }
    func hold(_ d: Device) -> Hold { d.lease.map { $0.isImplicit ? .inUse : .leased } ?? (d.claim != nil ? .held : .free) }

    var body: some View {
        let devs = m.devices
            .sorted { (hold($0).rawValue, $0.kind == .phone ? 0 : 1, $0.name) < (hold($1).rawValue, $1.kind == .phone ? 0 : 1, $1.name) }
        // A lease on an emulator still booting has no running device yet.
        let booting = m.leases.filter { l in l.device.hasPrefix("avd:") && !m.devices.contains { l.covers($0) } }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(devs)
                SectionTitle(title: "Devices", aspect: .android, count: devs.count)
                if devs.isEmpty {
                    Text(m.devices.isEmpty ? "Looking for devices…" : "No phone, emulator or simulator is running").hudLabel().padding(.leading, 14)
                } else {
                    Panel(aspect: .android, padding: 12) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(devs.enumerated()), id: \.element.id) { i, d in
                                if i > 0 { Rectangle().fill(HUD(scheme: scheme).line).frame(height: 0.6).padding(.vertical, 10) }
                                row(d)
                            }
                        }
                    }
                }
                if !booting.isEmpty {
                    SectionTitle(title: "Booting for a session", aspect: .android, count: booting.count)
                    Panel(aspect: .android, padding: 12) {
                        VStack(alignment: .leading, spacing: 10) { ForEach(booting, id: \.device) { lease($0, kind: "BOOTING") } }
                    }
                }
                bootableSection
                Text("Agents get devices with the rigwatch MCP tools: acquire_device leases a free phone, then a free running emulator or simulator, and boots one only when none is free. A lease keeps other sessions off the device and the clean-up away from it; commands that name the device renew it, and it ends when the session releases it, lets it run out, or exits.")
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
            }.padding(20)
        }
        .onAppear { registered = Demo.on || Rules.mcpInstalled(); m.loadBootable(force: m.bootable == nil) }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in m.loadBootable() }
    }

    // MARK: header

    /// Running count against the Rules' limit, red once it is passed.
    func capReadout(_ label: String, _ n: Int, _ cap: Int?) -> some View {
        Readout(label: label, value: "\(n)", unit: cap.map { "of \($0)" } ?? "",
                color: cap.map { n > $0 ? Color(hex: 0xFF4D5E).readable(scheme) : .primary } ?? .primary, size: 30)
            .help(cap.map { n > $0 ? "More than the Rules allow (\($0)): something booted one outside RigWatch's reach." : "The Rules allow \($0) at once." } ?? "No limit set on the Rules page.")
    }

    func header(_ devs: [Device]) -> some View {
        let s = Demo.on ? RuleSettings() : RuleSettings.load()
        let leased = devs.filter { hold($0) == .leased }.count, held = devs.filter { hold($0) == .held }.count, free = devs.filter { hold($0) == .free }.count
        let inUse = devs.filter { hold($0) == .inUse }.count
        return Panel(aspect: .android) {
            HStack(alignment: .center, spacing: 26) {
                Readout(label: "Leased", value: "\(leased)", color: Color(hex: 0x3DDC97).readable(scheme), size: 30)
                Readout(label: "In use, no lease", value: "\(inUse)", color: inUse > 0 ? Color(hex: 0xFF8A3D).readable(scheme) : .primary, size: 30)
                Readout(label: "Free", value: "\(free)", size: 30)
                Readout(label: "Held by agent-device", value: "\(held)", color: held > 0 ? Color(hex: 0xFFD23F).readable(scheme) : .primary, size: 30)
                capReadout("Emulators", devs.filter { $0.kind == .emulator }.count, Rules.virtualCap("android", s))
                capReadout("Simulators", devs.filter { $0.kind == .simulator }.count, Rules.virtualCap("ios", s))
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 6) {
                    let idle = m.idleDevices
                    if !idle.isEmpty {
                        Button { m.confirmShutDownIdle() } label: {
                            Label("Shut down \(idle.count) idle · \(Fmt.bytes(idle.reduce(UInt64(0)) { $0 + $1.mem }))", systemImage: "power")
                        }.buttonStyle(HUDButton(color: Color(hex: 0xFF4D5E), filled: true))
                        .help("Every emulator and simulator nobody holds or uses that has been idle 10 minutes or more.")
                    }
                    Chip(text: registered ? "DEVICE MANAGER ON" : "DEVICE MANAGER OFF", icon: "key", color: registered ? Color(hex: 0x3DDC97) : Aspect.process.color, filled: registered)
                    Text(registered ? "Registered with Claude Code: new sessions see the rigwatch tools" : "Not registered: turn the rules on (Rules page) so agents can ask for devices")
                        .hudLabel().multilineTextAlignment(.trailing)
                }
            }
        }
    }

    // MARK: rows

    @ViewBuilder func row(_ d: Device) -> some View {
        let a: Aspect = d.kind == .simulator ? .ios : d.kind == .emulator ? .android : .process
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: d.kind == .phone ? "iphone.gen2" : d.kind == .simulator ? "iphone.gen3" : "candybarphone")
                .font(.system(size: 15)).foregroundStyle(a.color.readable(scheme)).frame(width: 20).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(d.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text([d.kind.rawValue, d.id.count > 20 ? String(d.id.prefix(8)) + "…" : d.id].joined(separator: " · ")).hudLabel().lineLimit(1).help(d.id)
            }.frame(width: 200, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                if let l = d.lease { lease(l, kind: nil) }
                else if let c = d.claim {
                    HStack(spacing: 6) {
                        Chip(text: "HELD BY AGENT-DEVICE", icon: "lock.fill", color: Color(hex: 0xFFD23F)).fixedSize()
                        Text("session \(c.session) · \(Views.tilde(c.workspace)) · since \(Fmt.ago(c.since))")
                            .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    HStack(spacing: 10) {
                        Text("agent-device keeps it for that session; RigWatch doesn't hand it out.").hudLabel()
                        Button("Release") { m.confirmReleaseHold(d) }.buttonStyle(HUDButton(color: Color(hex: 0xFFD23F)))
                            .help("End agent-device's hold but keep the device running. Shut down ends the hold and stops it.")
                    }
                } else {
                    HStack(spacing: 6) {
                        Chip(text: "FREE", icon: "checkmark.circle", color: Color(hex: 0x3DDC97)).fixedSize()
                        Text(d.kind == .phone && RuleSettings.load().physicalFirst ? "agents asking for Android get it before any emulator" : "the next agent asking for one can get it")
                            .hudLabel().lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)
            if d.kind != .phone {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Fmt.cpu(d.cpu)).font(.system(size: 11, design: .monospaced))
                    Text(Fmt.bytes(d.mem)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                }.fixedSize()
                VStack(alignment: .trailing, spacing: 5) {
                    if let idle = m.idleFor(d) {
                        Text("idle \(BuildsView.span(idle))").hudLabel(idle >= Monitor.idleShutDownAfter ? Color(hex: 0xFFD23F).readable(scheme) : nil).fixedSize()
                    } else {
                        Text(d.lease != nil || d.claim != nil ? "held" : "used by a working session").hudLabel().fixedSize()
                    }
                    Button { m.confirmShutDown(d) } label: { Label("Shut down", systemImage: "power") }
                        .buttonStyle(HUDButton(color: Color(hex: 0xFF4D5E)))
                        .help("Asks it to quit and frees its memory; forces it if it doesn't respond. The confirmation says who is using it.")
                }.frame(width: 120, alignment: .trailing)
            }
        }
    }

    /// One lease: who holds it, for what, until when, with Extend and End.
    @ViewBuilder func lease(_ l: Lease, kind: String?) -> some View {
        if l.isImplicit { inUse(l) } else { leased(l, kind: kind) }
    }

    /// A session using the device directly, without acquire_device: RigWatch saw its commands name it.
    @ViewBuilder func inUse(_ l: Lease) -> some View {
        let last = Date().addingTimeInterval(-(Leases.renewOnUse - l.until.timeIntervalSinceNow))
        HStack(spacing: 6) {
            Chip(text: "IN USE", icon: "hand.raised.fill", color: Color(hex: 0xFF8A3D), filled: true).fixedSize()
            SessionLink(id: l.session)
        }
        HStack(spacing: 10) {
            Text("last command on it \(Fmt.ago(last)) · not leased: it used the device directly, so RigWatch holds it for that session until \(Int(Leases.renewOnUse / 60)) min after its last use")
                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 6)
            Button("Mark free") { m.confirmEndLease(l) }.buttonStyle(HUDButton(color: Color(hex: 0xFF4D5E)))
                .help("Let acquire_device hand it to other sessions now. The session using it is not stopped.")
        }
    }

    @ViewBuilder func leased(_ l: Lease, kind: String?) -> some View {
        let left = l.until.timeIntervalSinceNow
        HStack(spacing: 6) {
            Chip(text: kind ?? "LEASED", icon: "key.fill", color: Color(hex: 0x3DDC97), filled: kind == nil).fixedSize()
            SessionLink(id: l.session)
            if l.booted { Chip(text: "BOOTED BY RIGWATCH", color: Aspect.process.color).fixedSize().help("Releasing the lease shuts it down.") }
        }
        HStack(spacing: 10) {
            Text("until \(Leases.time(l.until)) · \(left < 60 ? "under a minute left" : "\(Int(left / 60)) min left")\(l.purpose.isEmpty ? "" : " · " + l.purpose)")
                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(left < 300 ? Color(hex: 0xFF8A3D).readable(scheme) : .secondary)
                .lineLimit(1).truncationMode(.tail).help(l.purpose)
            Spacer(minLength: 6)
            Button("Extend 30 min") { m.extendLease(l) }.buttonStyle(HUDButton(color: Color(hex: 0x3DDC97)))
            Button("End lease") { m.confirmEndLease(l) }.buttonStyle(HUDButton(color: Color(hex: 0xFF4D5E)))
        }
    }

    // MARK: bootable

    @ViewBuilder var bootableSection: some View {
        let running = Set(m.devices.filter { $0.kind == .emulator }.map(\.name))
        let avds = (m.bootable?.avds ?? []).filter { !running.contains($0) }
        let sims = m.bootable?.sims ?? []
        SectionTitle(title: "Can be booted", aspect: .ios, count: m.bootable == nil ? nil : avds.count + sims.count)
        if m.bootable == nil {
            HStack(spacing: 8) { ProgressView().controlSize(.mini); Text("Reading AVDs and simulators…").hudLabel() }.padding(.leading, 14)
        } else {
            HStack(alignment: .top, spacing: 14) {
                bootList("Android AVDs", .android, avds.isEmpty ? ["None" + (DeviceManager.emulatorPath == nil ? ": the Android emulator is not installed" : " left to boot")] : avds)
                bootList("iOS simulators", .ios, sims.isEmpty ? ["None shut down"] : sims.prefix(14).map { "\($0.name) · \($0.runtime)" } + (sims.count > 14 ? ["and \(sims.count - 14) more"] : []))
            }
            Text("RigWatch boots one of these only when an agent asks and nothing suitable is free: the first AVD, or the newest iPhone simulator, unless the agent names one.").hudLabel()
        }
    }

    func bootList(_ title: String, _ a: Aspect, _ items: [String]) -> some View {
        Panel(aspect: a, padding: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).hudLabel(a.color.readable(scheme))
                ForEach(items, id: \.self) { Text($0).font(.system(size: 11.5, design: .monospaced)).lineLimit(1) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
