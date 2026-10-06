import AppKit

// Generates the flat Calshot mark used by the Dock icon and app navigation.
// Run from the repository root: swift Design/GenerateBrand.swift
let size = 1024
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size,
    pixelsHigh: size,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Could not create icon canvas")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
context.shouldAntialias = true
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: size, height: size).fill()

let tile = NSBezierPath(roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928),
                        xRadius: 218, yRadius: 218)
NSColor(calibratedRed: 0.065, green: 0.073, blue: 0.095, alpha: 1).setFill()
tile.fill()

// The open frame reads as both a C and a selected region at small sizes.
let frame = NSBezierPath()
frame.lineWidth = 92
frame.lineCapStyle = .round
frame.lineJoinStyle = .round
frame.move(to: NSPoint(x: 710, y: 730))
frame.curve(to: NSPoint(x: 515, y: 775),
            controlPoint1: NSPoint(x: 655, y: 760),
            controlPoint2: NSPoint(x: 585, y: 785))
frame.curve(to: NSPoint(x: 278, y: 512),
            controlPoint1: NSPoint(x: 380, y: 775),
            controlPoint2: NSPoint(x: 278, y: 680))
frame.curve(to: NSPoint(x: 515, y: 249),
            controlPoint1: NSPoint(x: 278, y: 344),
            controlPoint2: NSPoint(x: 380, y: 249))
frame.curve(to: NSPoint(x: 710, y: 294),
            controlPoint1: NSPoint(x: 585, y: 239),
            controlPoint2: NSPoint(x: 655, y: 264))
NSColor(calibratedRed: 0.96, green: 0.97, blue: 1, alpha: 1).setStroke()
frame.stroke()

NSColor(calibratedRed: 0.32, green: 0.57, blue: 0.99, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 688, y: 452, width: 120, height: 120)).fill()
context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode icon")
}
for path in [
    "Assets.xcassets/AppIcon.appiconset/AppIcon.png",
    "Assets.xcassets/CalshotMark.imageset/CalshotMark.png"
] {
    try png.write(to: URL(fileURLWithPath: path), options: .atomic)
}
