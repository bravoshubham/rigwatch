import SwiftUI

// MARK: Palette

/// One neon colour and icon per thing being watched, used everywhere that thing appears.
enum Aspect: CaseIterable {
    case cpu, memory, gpu, disk, network, android, ios, claude, worktree, process, thermal, server

    var color: Color {
        switch self {
        case .cpu: Color(hex: 0xFFB020)
        case .memory: Color(hex: 0xA78BFA)
        case .gpu: Color(hex: 0x22D3EE)
        case .disk: Color(hex: 0x60A5FA)
        case .network: Color(hex: 0x34D399)
        case .android: Color(hex: 0x3DDC84)
        case .ios: Color(hex: 0x5AC8FA)
        case .claude: Color(hex: 0xE5866A)
        case .worktree: Color(hex: 0xF472B6)
        case .process: Color(hex: 0x94A3B8)
        case .thermal: Color(hex: 0xFF5A4E)
        case .server: Color(hex: 0xA3E635)
        }
    }

    var icon: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .gpu: "square.stack.3d.up"
        case .disk: "internaldrive"
        case .network: "arrow.up.arrow.down"
        case .android: "candybarphone"
        case .ios: "iphone.gen3"
        case .claude: "sparkles"
        case .worktree: "arrow.triangle.branch"
        case .process: "gearshape.2"
        case .thermal: "thermometer.medium"
        case .server: "server.rack"
        }
    }

    static func forGroup(_ g: String) -> Aspect {
        switch g {
        case "Android emulators": .android
        case "iOS simulators", "Xcode / Swift": .ios
        case "Claude Code sessions", "Claude": .claude
        case "Gradle", "Kotlin daemon", "Java", "Android Studio": .cpu
        default: .process
        }
    }
}

extension Page {
    var aspect: Aspect {
        switch self {
        case .overview: .gpu; case .devices: .android; case .sessions: .claude; case .servers: .server; case .processes: .cpu
        case .memory: .memory; case .worktrees: .worktree; case .disk: .disk
        }
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
    /// Neon accents read on black; on a light background the same hue needs to be darker.
    func readable(_ scheme: ColorScheme) -> Color {
        guard scheme == .light else { return self }
        if #available(macOS 15.0, *) { return mix(with: .black, by: 0.42) }
        return self
    }
}

/// Surface colours for the two themes.
struct HUD {
    let scheme: ColorScheme
    var bg: Color { scheme == .dark ? Color(hex: 0x05080C) : Color(hex: 0xEEF2F5) }
    var panel: Color { scheme == .dark ? Color(hex: 0x0A1016) : Color(hex: 0xFFFFFF, opacity: 0.9) }
    var line: Color { scheme == .dark ? Color(hex: 0x1C2833) : Color(hex: 0xC9D3DC) }
    var grid: Color { scheme == .dark ? Color.white.opacity(0.035) : Color.black.opacity(0.045) }
    var dim: Color { scheme == .dark ? Color(hex: 0x7D8B99) : Color(hex: 0x5B6976) }
    var accent: Color { Color(hex: 0x2EE6D6) }
    var accent2: Color { Color(hex: 0x2F80ED) }
}

enum Heat {
    static func cpu(_ v: Double) -> Color { v >= 200 ? Color(hex: 0xFF4D5E) : v >= 100 ? Color(hex: 0xFF8A3D) : v >= 25 ? Color(hex: 0xFFD23F) : Color(hex: 0x3DDC97) }
    static func ratio(_ r: Double) -> Color { r >= 0.9 ? Color(hex: 0xFF4D5E) : r >= 0.75 ? Color(hex: 0xFF8A3D) : r >= 0.5 ? Color(hex: 0xFFD23F) : Color(hex: 0x3DDC97) }
    static func status(_ s: String) -> Color {
        switch s {
        case "Working", "device", "Booted": Color(hex: 0x3DDC97)
        case "Idle", "Live": Color(hex: 0xFFD23F)
        case "offline", "not in adb", "unauthorized": Color(hex: 0xFF4D5E)
        default: Color(hex: 0x7D8B99)
        }
    }
}

// MARK: Typography

extension Text {
    /// Small uppercase monospaced caption: the HUD's label voice.
    func hudLabel(_ color: Color? = nil) -> some View {
        self.font(.system(size: 9.5, weight: .semibold, design: .monospaced)).tracking(1.4).textCase(.uppercase).foregroundStyle(color ?? .secondary)
    }
    func hudNumber(_ size: CGFloat = 30) -> Text {
        self.font(.system(size: size, weight: .light, design: .rounded)).monospacedDigit()
    }
}

// MARK: Pieces

struct Chip: View {
    @Environment(\.colorScheme) private var scheme
    let text: String
    var icon: String? = nil
    var color: Color = Color(hex: 0x94A3B8)
    var filled = false

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 8.5, weight: .bold)) }
            Text(text).font(.system(size: 10, weight: .semibold, design: .monospaced)).monospacedDigit().lineLimit(1)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .foregroundStyle(filled ? (scheme == .dark ? Color.black : Color.white) : color.readable(scheme))
        .background(RoundedRectangle(cornerRadius: 2).fill(color.opacity(filled ? 0.92 : (scheme == .dark ? 0.10 : 0.12))))
        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(color.opacity(filled ? 0 : 0.45), lineWidth: 0.6))
    }
}

struct Dot: View {
    let color: Color
    var body: some View {
        ZStack { Circle().fill(color.opacity(0.25)).frame(width: 11, height: 11); Circle().fill(color).frame(width: 5, height: 5) }
    }
}

struct IconBadge: View {
    @Environment(\.colorScheme) private var scheme
    let aspect: Aspect
    var size: CGFloat = 22
    var body: some View {
        Image(systemName: aspect.icon).font(.system(size: size * 0.48, weight: .semibold)).foregroundStyle(aspect.color.readable(scheme))
            .frame(width: size, height: size)
            .background(Rectangle().fill(aspect.color.opacity(0.12)))
            .overlay(Rectangle().strokeBorder(aspect.color.opacity(0.6), lineWidth: 0.8))
    }
}

/// Thin ring with tick marks, like an instrument dial.
struct Ring: View {
    let value: Double
    let color: Color
    var line: CGFloat = 5
    var body: some View {
        ZStack {
            Ticks(count: 60).stroke(color.opacity(0.35), lineWidth: 0.8)
            Group {
                Circle().stroke(color.opacity(0.12), lineWidth: line)
                Circle().trim(from: 0, to: max(0.002, min(1, value)))
                    .stroke(LinearGradient(colors: [color.opacity(0.5), color], startPoint: .topLeading, endPoint: .bottomTrailing), style: StrokeStyle(lineWidth: line, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }.padding(8)
        }
    }
}

struct Ticks: Shape {
    let count: Int
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: r.midX, y: r.midY), R = min(r.width, r.height) / 2
        for i in 0..<count {
            let a = Double(i) / Double(count) * 2 * .pi - .pi / 2
            let len: CGFloat = i % 5 == 0 ? 4.5 : 2
            p.move(to: CGPoint(x: c.x + cos(a) * R, y: c.y + sin(a) * R))
            p.addLine(to: CGPoint(x: c.x + cos(a) * (R - len), y: c.y + sin(a) * (R - len)))
        }
        return p
    }
}

/// Bar meter. With `segments`, lit cells up to the value like a level meter.
struct Meter: View {
    let value: Double
    var color: Color = Color(hex: 0x2EE6D6)
    var height: CGFloat = 6
    var segments = 0
    var body: some View {
        GeometryReader { g in
            if segments > 0 {
                Canvas { ctx, size in
                    let gap: CGFloat = 2, n = segments
                    let w = (size.width - gap * CGFloat(n - 1)) / CGFloat(n)
                    for i in 0..<n {
                        let r = CGRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: size.height)
                        ctx.fill(Path(r), with: .color(Double(i) < value * Double(n) ? color : color.opacity(0.13)))
                    }
                }
            } else {
                ZStack(alignment: .leading) {
                    Rectangle().fill(color.opacity(0.12))
                    Rectangle().fill(LinearGradient(colors: [color.opacity(0.5), color], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(1, min(1, max(0, value)) * g.size.width))
                }
            }
        }.frame(height: height)
    }
}

/// Corner brackets drawn over a panel's edge.
struct Brackets: Shape {
    var len: CGFloat = 9
    func path(in r: CGRect) -> Path {
        var p = Path()
        for (x, y, dx, dy) in [(r.minX, r.minY, 1.0, 1.0), (r.maxX, r.minY, -1.0, 1.0), (r.minX, r.maxY, 1.0, -1.0), (r.maxX, r.maxY, -1.0, -1.0)] {
            p.move(to: CGPoint(x: x + dx * len, y: y)); p.addLine(to: CGPoint(x: x, y: y)); p.addLine(to: CGPoint(x: x, y: y + dy * len))
        }
        return p
    }
}

/// The HUD panel: dark glass, hairline edge washed with the aspect colour, bracketed corners.
struct Panel<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    var aspect: Aspect? = nil
    var padding: CGFloat = 14
    @ViewBuilder var content: Content
    var body: some View {
        let hud = HUD(scheme: scheme)
        let tint = aspect?.color ?? hud.accent
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                ZStack {
                    Rectangle().fill(hud.panel)
                    Rectangle().fill(LinearGradient(colors: [tint.opacity(scheme == .dark ? 0.08 : 0.06), .clear], startPoint: .topLeading, endPoint: .center))
                }
            )
            .overlay(Rectangle().strokeBorder(LinearGradient(colors: [tint.opacity(0.5), hud.line, hud.line], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8))
            .overlay(Brackets().stroke(tint.readable(scheme).opacity(0.95), lineWidth: 1.5))
    }
}

struct SectionTitle: View {
    var title: String
    var aspect: Aspect? = nil
    var count: Int? = nil
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        HStack(spacing: 10) {
            if let aspect { Rectangle().fill(aspect.color).frame(width: 3, height: 13) }
            Text(title).hudLabel(.primary)
            if let count { Text(String(format: "%02d", count)).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle((aspect?.color ?? .secondary).readable(scheme)) }
            Rectangle().fill(HUD(scheme: scheme).line).frame(height: 0.8)
        }
    }
}

/// The faint engineering grid behind every screen.
struct GridBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let hud = HUD(scheme: scheme)
        Canvas { ctx, size in
            var p = Path()
            for x in stride(from: 0.0, through: size.width, by: 28) { p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)) }
            for y in stride(from: 0.0, through: size.height, by: 28) { p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)) }
            ctx.stroke(p, with: .color(hud.grid), lineWidth: 0.5)
        }
        .background(hud.bg)
        .ignoresSafeArea()
    }
}

/// A metric readout: label on top, a big thin number, an optional unit.
struct Readout: View {
    let label: String
    let value: String
    var unit: String = ""
    var color: Color = .primary
    var size: CGFloat = 28
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).hudLabel().lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).hudNumber(size).foregroundStyle(color).lineLimit(1)
                if !unit.isEmpty { Text(unit).font(.system(size: 10.5, weight: .medium, design: .monospaced)).foregroundStyle(.secondary) }
            }
        }
    }
}

/// HUD action button: square, outlined, monospaced, tinted.
struct HUDButton: ButtonStyle {
    var color: Color = Color(hex: 0x2EE6D6)
    var filled = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .bold, design: .monospaced)).textCase(.uppercase).tracking(0.8)
            .lineLimit(1).fixedSize()   // never wrap: the button grows to fit its label
            .padding(.horizontal, 10).padding(.vertical, 5)
            .foregroundStyle(filled ? Color.black : color.readable(scheme))
            .background(Rectangle().fill(color.opacity(filled ? (configuration.isPressed ? 0.7 : 0.95) : (configuration.isPressed ? 0.25 : 0.08))))
            .overlay(Rectangle().strokeBorder(color.opacity(0.75), lineWidth: 0.8))
            .opacity(enabled ? 1 : 0.35)
            .contentShape(Rectangle())
    }
}
