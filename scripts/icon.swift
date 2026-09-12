// Draws Remit's 1024 px app icon: a white task card with one checked row, on a coral rounded
// square that follows the macOS icon grid. Run through scripts/make-icon.sh.
import AppKit

let output = CommandLine.arguments[1]
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
let context = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = context
let cg = context.cgContext

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// The macOS grid: an 824 px body centred on the 1024 canvas, leaving room for the shadow.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = roundedRect(body, 185)

cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.28))
cg.addPath(bodyPath)
cg.setFillColor(color(0xD9483A))
cg.fillPath()
cg.restoreGState()

cg.saveGState()
cg.addPath(bodyPath)
cg.clip()
let background = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [color(0xF2795F), color(0xC9392B)] as CFArray,
    locations: [0, 1]
)!
cg.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
cg.restoreGState()

// The card.
let card = CGRect(x: 262, y: 222, width: 500, height: 580)
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x5A1A12, 0.35))
cg.addPath(roundedRect(card, 64))
cg.setFillColor(color(0xFFFFFF))
cg.fillPath()
cg.restoreGState()

// Three task rows, top to bottom; the first is done.
for (index, y) in [CGFloat(680), 512, 344].enumerated() {
    let centreX: CGFloat = 352
    let radius: CGFloat = 44
    let circle = CGRect(x: centreX - radius, y: y - radius, width: radius * 2, height: radius * 2)
    if index == 0 {
        cg.setFillColor(color(0xDC4C3E))
        cg.fillEllipse(in: circle)
        cg.setStrokeColor(color(0xFFFFFF))
        cg.setLineWidth(15)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        cg.move(to: CGPoint(x: centreX - 20, y: y + 1))
        cg.addLine(to: CGPoint(x: centreX - 5, y: y - 15))
        cg.addLine(to: CGPoint(x: centreX + 22, y: y + 17))
        cg.strokePath()
    } else {
        cg.setStrokeColor(color(0xC9C3BC))
        cg.setLineWidth(14)
        cg.strokeEllipse(in: circle.insetBy(dx: 7, dy: 7))
    }
    cg.setFillColor(color(index == 0 ? 0xE9E4DE : 0x3B3835))
    cg.addPath(roundedRect(CGRect(x: 430, y: y + 4, width: index == 0 ? 250 : 270, height: 30), 15))
    cg.fillPath()
    cg.setFillColor(color(0xE9E4DE))
    cg.addPath(roundedRect(CGRect(x: 430, y: y - 40, width: index == 2 ? 150 : 190, height: 22), 11))
    cg.fillPath()
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
