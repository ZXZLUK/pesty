import AppKit

// ClipBar icon: a bottom-up color strip sliding out of a dark rounded plate —
// the app's own slide-up bar motif. Original artwork for the ClipBar rename.
let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }

func rounded(_ r: CGRect, _ rad: CGFloat, _ color: NSColor) {
    color.setFill()
    NSBezierPath(roundedRect: r, xRadius: rad, yRadius: rad).fill()
}

// Background plate: deep teal-to-blue vertical gradient.
let margin = size * 0.085
let plate = CGRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
let corner = (size - margin * 2) * 0.225
ctx.saveGState()
NSBezierPath(roundedRect: plate, xRadius: corner, yRadius: corner).addClip()
let colors = [NSColor(srgbRed: 0.05, green: 0.32, blue: 0.38, alpha: 1).cgColor,
              NSColor(srgbRed: 0.10, green: 0.46, blue: 0.62, alpha: 1).cgColor] as CFArray
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: plate.midX, y: plate.maxY),
                       end: CGPoint(x: plate.midX, y: plate.minY), options: [])
ctx.restoreGState()

// Three cards rising from the bottom edge, newest tallest, each a different hue.
let cardColors: [NSColor] = [
    NSColor(srgbRed: 0.98, green: 0.75, blue: 0.18, alpha: 1),
    NSColor(srgbRed: 0.94, green: 0.96, blue: 0.98, alpha: 1),
    NSColor(srgbRed: 0.55, green: 0.90, blue: 0.78, alpha: 1),
]
let cardHeights: [CGFloat] = [0.58, 0.44, 0.32]
let cardW = plate.width * 0.24
let gap = plate.width * 0.045
let totalW = cardW * 3 + gap * 2
var cx = plate.midX - totalW / 2
for (i, c) in cardColors.enumerated() {
    let h = plate.height * cardHeights[i]
    let r = CGRect(x: cx, y: plate.minY - size * 0.02, width: cardW, height: h)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: size * 0.015), blur: size * 0.035,
                  color: NSColor.black.withAlphaComponent(0.28).cgColor)
    rounded(r, size * 0.04, c)
    ctx.restoreGState()
    // Header band on each card, like the app's color-coded card headers.
    rounded(CGRect(x: r.minX, y: r.maxY - h * 0.18, width: r.width, height: h * 0.18),
            size * 0.02, c.withAlphaComponent(0.75))
    cx += cardW + gap
}

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "packaging/icon_1024.png"
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
