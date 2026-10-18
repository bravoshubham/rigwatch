// Renders the RigWatch app icon: a seeing-stone orb held in a ring of chip pins. Inside the orb, the
// app's own die map, a radar sweep and an iris, all on a deep night tile.
// swift Assets/make-icon.swift Assets/AppIcon.png   (1024×1024)
import AppKit

let S: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let c = NSGraphicsContext.current!.cgContext
func rgb(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(h >> 16 & 255) / 255, green: CGFloat(h >> 8 & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a)
}
let cs = CGColorSpaceCreateDeviceRGB()
func grad(_ cols: [CGColor], _ locs: [CGFloat]) -> CGGradient { CGGradient(colorsSpace: cs, colors: cols as CFArray, locations: locs)! }
let ctr = CGPoint(x: 512, y: 500)
let cyan: UInt32 = 0x3FE0FF, violet: UInt32 = 0x8B5CFF, magenta: UInt32 = 0xFF4FD8, amber: UInt32 = 0xFFB547

// Tile: macOS icon grid (824 pt body, 100 pt margin).
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
c.saveGState()
c.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: rgb(0x000000, 0.5))
c.addPath(tilePath); c.setFillColor(rgb(0x070914)); c.fillPath()
c.restoreGState()

c.saveGState()
c.addPath(tilePath); c.clip()
c.drawLinearGradient(grad([rgb(0x1B1840), rgb(0x0B0E22), rgb(0x04050C)], [0, 0.55, 1]),
                     start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
// Aurora behind the orb.
c.drawRadialGradient(grad([rgb(violet, 0.55), rgb(violet, 0)], [0, 1]),
                     startCenter: CGPoint(x: 380, y: 760), startRadius: 0, endCenter: CGPoint(x: 380, y: 760), endRadius: 420, options: [])
c.drawRadialGradient(grad([rgb(cyan, 0.40), rgb(cyan, 0)], [0, 1]),
                     startCenter: CGPoint(x: 700, y: 260), startRadius: 0, endCenter: CGPoint(x: 700, y: 260), endRadius: 420, options: [])
// Fine dot grid.
c.setFillColor(rgb(0xBFD4FF, 0.10))
var gy: CGFloat = 120
while gy < 924 { var gx: CGFloat = 120; while gx < 924 { c.fillEllipse(in: CGRect(x: gx - 2.5, y: gy - 2.5, width: 5, height: 5)); gx += 40 }; gy += 40 }
c.restoreGState()
c.addPath(CGPath(roundedRect: tile.insetBy(dx: 2, dy: 2), cornerWidth: 183, cornerHeight: 183, transform: nil))
c.setStrokeColor(rgb(0xFFFFFF, 0.12)); c.setLineWidth(3); c.strokePath()

// Pin ring: the chip's pins bent round the orb, coloured cyan → violet → magenta → amber round the dial.
let R: CGFloat = 236
let pinCount = 60
func mix(_ a: UInt32, _ b: UInt32, _ t: CGFloat) -> CGColor {
    func ch(_ v: UInt32, _ s: UInt32) -> CGFloat { CGFloat(v >> s & 255) / 255 }
    return CGColor(red: ch(a, 16) + (ch(b, 16) - ch(a, 16)) * t, green: ch(a, 8) + (ch(b, 8) - ch(a, 8)) * t,
                   blue: ch(a, 0) + (ch(b, 0) - ch(a, 0)) * t, alpha: 1)
}
let stops: [UInt32] = [cyan, violet, magenta, amber, cyan]
c.saveGState()
c.setShadow(offset: .zero, blur: 14, color: rgb(cyan, 0.55))
c.setLineCap(.round)
for i in 0..<pinCount {
    let t = CGFloat(i) / CGFloat(pinCount)
    let a = .pi / 2 - t * .pi * 2
    let seg = t * CGFloat(stops.count - 1), k = Int(seg)
    c.setStrokeColor(mix(stops[k], stops[k + 1], seg - CGFloat(k)))
    // Lengths read as a live load meter round the dial.
    let load = 0.5 + 0.28 * sin(t * .pi * 6 + 0.7) + 0.22 * sin(t * .pi * 14 + 2.1)
    c.setLineWidth(11)
    let r0 = R + 34, r1 = R + 44 + 84 * load
    c.move(to: CGPoint(x: ctr.x + cos(a) * r0, y: ctr.y + sin(a) * r0))
    c.addLine(to: CGPoint(x: ctr.x + cos(a) * r1, y: ctr.y + sin(a) * r1))
    c.strokePath()
}
c.restoreGState()
// Socket ring the pins come out of.
c.setStrokeColor(rgb(0xDDE7FF, 0.85)); c.setLineWidth(10)
c.addArc(center: ctr, radius: R + 20, startAngle: 0, endAngle: .pi * 2, clockwise: false); c.strokePath()

// The orb.
let orb = CGRect(x: ctr.x - R, y: ctr.y - R, width: R * 2, height: R * 2)
c.saveGState()
c.setShadow(offset: CGSize(width: 0, height: -10), blur: 50, color: rgb(cyan, 0.6))
c.setFillColor(rgb(0x050616)); c.fillEllipse(in: orb)
c.restoreGState()
c.saveGState()
c.addEllipse(in: orb); c.clip()
c.drawRadialGradient(grad([rgb(0x123A7A), rgb(0x1A1250), rgb(0x05051A)], [0, 0.6, 1]),
                     startCenter: CGPoint(x: ctr.x - 40, y: ctr.y + 50), startRadius: 0, endCenter: ctr, endRadius: R, options: [])
// The die map, seen through the glass.
let cell = R * 2 / 8
let map: [(CGFloat, CGFloat, CGFloat, CGFloat, UInt32)] = [
    (0, 0, 3, 4, cyan), (3, 0, 3, 2, violet), (6, 0, 2, 3, amber), (3, 2, 2, 2, magenta), (5, 2, 1, 2, cyan),
    (0, 4, 2, 4, violet), (2, 4, 4, 2, cyan), (6, 3, 2, 3, magenta), (2, 6, 2, 2, amber), (4, 6, 4, 2, violet)]
for (x, y, w, h, col) in map {
    let r = CGRect(x: orb.minX + x * cell, y: orb.minY + y * cell, width: w * cell, height: h * cell).insetBy(dx: 6, dy: 6)
    c.setFillColor(rgb(col, 0.13)); c.fill(r)
    c.setStrokeColor(rgb(col, 0.45)); c.setLineWidth(3); c.stroke(r)
}
// Radar sweep: a wedge fading out behind its leading edge.
let lead: CGFloat = .pi * 0.30
for s in 0..<40 {
    let a0 = lead + CGFloat(s) * 0.025
    c.move(to: ctr)
    c.addArc(center: ctr, radius: R, startAngle: a0, endAngle: a0 + 0.026, clockwise: false)
    c.closePath()
    c.setFillColor(rgb(cyan, 0.70 * pow(1 - CGFloat(s) / 40, 2))); c.fillPath()
}
c.setStrokeColor(rgb(0xD8FBFF, 0.95)); c.setLineWidth(6)
c.move(to: ctr); c.addLine(to: CGPoint(x: ctr.x + cos(lead) * R, y: ctr.y + sin(lead) * R)); c.strokePath()
// Iris rings.
for (r, a, w) in [(R * 0.82, 0.22, 3.0), (R * 0.60, 0.35, 4.0), (R * 0.38, 0.55, 5.0)] as [(CGFloat, CGFloat, CGFloat)] {
    c.setStrokeColor(rgb(0xCFEFFF, a)); c.setLineWidth(w)
    c.addArc(center: ctr, radius: r, startAngle: 0, endAngle: .pi * 2, clockwise: false); c.strokePath()
}
// A blip the sweep just found.
let blip = CGPoint(x: ctr.x + cos(lead + 0.25) * R * 0.6, y: ctr.y + sin(lead + 0.25) * R * 0.6)
c.saveGState()
c.setShadow(offset: .zero, blur: 20, color: rgb(amber, 1))
c.setFillColor(rgb(amber)); c.fillEllipse(in: CGRect(x: blip.x - 16, y: blip.y - 16, width: 32, height: 32))
c.restoreGState()
// Inner shadow at the rim, so it reads as a sphere.
c.drawRadialGradient(grad([rgb(0x000000, 0), rgb(0x000000, 0), rgb(0x000000, 0.65)], [0, 0.7, 1]),
                     startCenter: ctr, startRadius: 0, endCenter: ctr, endRadius: R, options: [])
// Specular highlight.
c.drawRadialGradient(grad([rgb(0xFFFFFF, 0.55), rgb(0xFFFFFF, 0)], [0, 1]),
                     startCenter: CGPoint(x: ctr.x - R * 0.42, y: ctr.y + R * 0.48), startRadius: 0,
                     endCenter: CGPoint(x: ctr.x - R * 0.42, y: ctr.y + R * 0.48), endRadius: R * 0.55, options: [])
c.restoreGState()
// Rim light.
c.setLineWidth(5)
c.setStrokeColor(rgb(cyan, 0.9)); c.addArc(center: ctr, radius: R - 2, startAngle: .pi * 0.15, endAngle: .pi * 0.95, clockwise: false); c.strokePath()
c.setStrokeColor(rgb(magenta, 0.7)); c.addArc(center: ctr, radius: R - 2, startAngle: .pi * 1.15, endAngle: .pi * 1.85, clockwise: false); c.strokePath()

// Pupil.
c.saveGState()
c.setShadow(offset: .zero, blur: 34, color: rgb(cyan, 1))
c.setFillColor(rgb(cyan)); c.fillEllipse(in: CGRect(x: ctr.x - 34, y: ctr.y - 34, width: 68, height: 68))
c.restoreGState()
c.setFillColor(rgb(0xF2FDFF)); c.fillEllipse(in: CGRect(x: ctr.x - 15, y: ctr.y - 15, width: 30, height: 30))

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
