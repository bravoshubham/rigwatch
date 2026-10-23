import SwiftUI

struct RigWatchApp: App {   // started from main.swift
    @ObservedObject private var m: Monitor
    @AppStorage("appearance") private var appearance = "system"

    init() {
        AppCopy.sync()   // may hand over to the ~/Applications copy and exit before anything starts
        m = Monitor.shared
    }

    var body: some Scene {
        Window("RigWatch", id: "main") {
            RootView().frame(minWidth: 1080, minHeight: 680)
                .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        }
        .defaultSize(width: 1280, height: 820)

        MenuBarExtra {
            MenuView()
        } label: {
            Text("CPU \(Int(m.sys.cpu))% · GPU \(m.sys.gpu)% · \(Fmt.bytes(m.sys.memUsed))")
        }
    }
}

struct MenuView: View {
    @ObservedObject private var m = Monitor.shared
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        let s = m.sys
        Text("CPU \(Fmt.pct(s.cpu)) · load \(String(format: "%.1f", s.load.0))")
        Text("Memory \(Fmt.bytes(s.memUsed)) of \(Fmt.bytes(s.memTotal)) · \(Views.pressureName(s.pressure))")
        Text("GPU \(s.gpu)% · Swap \(Fmt.bytes(s.swapUsed))")
        if !m.devices.isEmpty { Text("\(m.devices.filter { $0.kind != .phone }.count) emulators/simulators running") }
        Divider()
        Text("RigWatch \(AppCopy.ownVersion)")
        if let v = m.updateReady { Button("Restart to use RigWatch \(v)") { AppCopy.restartIntoNewest() } }
        Button("Open RigWatch") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button("Quit RigWatch") { NSApp.terminate(nil) }
    }
}
