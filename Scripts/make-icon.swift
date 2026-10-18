// Renders Steppe's app icon (1024x1024 PNG) with Core Graphics, no external assets.
// Usage: swift Scripts/make-icon.swift <output.png>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("context") }

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 255) / 255, CGFloat((hex >> 8) & 255) / 255, CGFloat(hex & 255) / 255, alpha])!
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map { $0.1 } as CFArray, locations: stops.map { $0.0 })!
}

// Icon body: 824pt rounded square centred on the 1024 canvas (macOS template).
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: body, cornerWidth: 190, cornerHeight: 190, transform: nil)

// Soft drop shadow under the body.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: color(0x000000, 0.45))
ctx.setFillColor(color(0x0B0D1F))
ctx.addPath(squircle)
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()

// Night sky into ember horizon.
ctx.drawLinearGradient(
    gradient([(0, color(0x090B1C)), (0.5, color(0x1D1B3F)), (0.78, color(0x6E2B22)), (1, color(0xB8501F))]),
    start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

// Glow around the sun.
ctx.drawRadialGradient(
    gradient([(0, color(0xFFB347, 0.85)), (0.45, color(0xF07A2A, 0.35)), (1, color(0xF07A2A, 0))]),
    startCenter: CGPoint(x: 512, y: 372), startRadius: 0, endCenter: CGPoint(x: 512, y: 372), endRadius: 470, options: [])

// Sun disc.
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: 512 - 150, y: 372 - 150, width: 300, height: 300))
ctx.clip()
ctx.drawLinearGradient(gradient([(0, color(0xFFE29A)), (1, color(0xF2862E))]),
                       start: CGPoint(x: 512, y: 522), end: CGPoint(x: 512, y: 222), options: [])
ctx.restoreGState()

// Far hills.
let far = CGMutablePath()
far.move(to: CGPoint(x: 100, y: 100))
far.addLine(to: CGPoint(x: 100, y: 330))
far.addCurve(to: CGPoint(x: 400, y: 300), control1: CGPoint(x: 190, y: 380), control2: CGPoint(x: 300, y: 350))
far.addCurve(to: CGPoint(x: 700, y: 330), control1: CGPoint(x: 500, y: 250), control2: CGPoint(x: 600, y: 300))
far.addCurve(to: CGPoint(x: 924, y: 290), control1: CGPoint(x: 800, y: 360), control2: CGPoint(x: 860, y: 330))
far.addLine(to: CGPoint(x: 924, y: 100))
far.closeSubpath()
ctx.setFillColor(color(0x3A1D2B))
ctx.addPath(far); ctx.fillPath()

// Near hills.
let near = CGMutablePath()
near.move(to: CGPoint(x: 100, y: 100))
near.addLine(to: CGPoint(x: 100, y: 230))
near.addCurve(to: CGPoint(x: 480, y: 215), control1: CGPoint(x: 220, y: 290), control2: CGPoint(x: 350, y: 250))
near.addCurve(to: CGPoint(x: 924, y: 240), control1: CGPoint(x: 620, y: 175), control2: CGPoint(x: 800, y: 290))
near.addLine(to: CGPoint(x: 924, y: 100))
near.closeSubpath()
ctx.setFillColor(color(0x120D18))
ctx.addPath(near); ctx.fillPath()

// A sabre: curved tapered blade, crossguard, grip and pommel. Drawn pointing up from the origin.
func sabre(rotation: CGFloat, mirrored: Bool, at origin: CGPoint) {
    ctx.saveGState()
    ctx.translateBy(x: origin.x, y: origin.y)
    ctx.rotate(by: rotation)
    if mirrored { ctx.scaleBy(x: -1, y: 1) }

    let base = CGPoint(x: 0, y: 0), tip = CGPoint(x: 60, y: 470), control = CGPoint(x: -26, y: 240)
    func spine(_ t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u * u * base.x + 2 * u * t * control.x + t * t * tip.x,
                       y: u * u * base.y + 2 * u * t * control.y + t * t * tip.y)
    }
    func normal(_ t: CGFloat) -> CGPoint {
        let u = 1 - t
        let dx = 2 * u * (control.x - base.x) + 2 * t * (tip.x - control.x)
        let dy = 2 * u * (control.y - base.y) + 2 * t * (tip.y - control.y)
        let len = max(0.001, (dx * dx + dy * dy).squareRoot())
        return CGPoint(x: -dy / len, y: dx / len)
    }
    let steps = 48
    let blade = CGMutablePath()
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let w = 23 * (1 - 0.82 * t)
        let p = spine(t), n = normal(t)
        let pt = CGPoint(x: p.x + n.x * w, y: p.y + n.y * w)
        i == 0 ? blade.move(to: pt) : blade.addLine(to: pt)
    }
    for i in stride(from: steps, through: 0, by: -1) {
        let t = CGFloat(i) / CGFloat(steps)
        let w = 23 * (1 - 0.82 * t) * 0.55
        let p = spine(t), n = normal(t)
        blade.addLine(to: CGPoint(x: p.x - n.x * w, y: p.y - n.y * w))
    }
    blade.closeSubpath()
    ctx.setFillColor(color(0xE9E4DA))
    ctx.addPath(blade); ctx.fillPath()
    ctx.setStrokeColor(color(0x0B0810, 0.55)); ctx.setLineWidth(3)
    ctx.addPath(blade); ctx.strokePath()

    // Crossguard.
    let crossguard = CGPath(roundedRect: CGRect(x: -62, y: -12, width: 124, height: 24), cornerWidth: 12, cornerHeight: 12, transform: nil)
    ctx.setFillColor(color(0xC98A2E)); ctx.addPath(crossguard); ctx.fillPath()
    // Grip and pommel.
    let grip = CGPath(roundedRect: CGRect(x: -14, y: -128, width: 28, height: 118), cornerWidth: 10, cornerHeight: 10, transform: nil)
    ctx.setFillColor(color(0x2A1A14)); ctx.addPath(grip); ctx.fillPath()
    ctx.setFillColor(color(0xC98A2E))
    ctx.fillEllipse(in: CGRect(x: -22, y: -150, width: 44, height: 44))
    ctx.restoreGState()
}
let hilt = CGPoint(x: 512, y: 215)
sabre(rotation: -0.46, mirrored: false, at: CGPoint(x: hilt.x - 88, y: hilt.y))
sabre(rotation: 0.46, mirrored: true, at: CGPoint(x: hilt.x + 88, y: hilt.y))

// Subtle top highlight.
ctx.drawLinearGradient(gradient([(0, color(0xFFFFFF, 0.10)), (0.25, color(0xFFFFFF, 0))]),
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 640), options: [])
ctx.restoreGState()

ctx.setStrokeColor(color(0xFFFFFF, 0.10))
ctx.setLineWidth(2)
ctx.addPath(squircle)
ctx.strokePath()

guard let image = ctx.makeImage(),
      let out = CGImageDestinationCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fatalError("encode") }
CGImageDestinationAddImage(out, image, nil)
guard CGImageDestinationFinalize(out) else { fatalError("write") }
