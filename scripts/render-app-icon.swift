import AppKit
import Foundation

// Original geometric mark, rendered locally. No third-party image assets.
let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("Apps/Shared/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
let mac = root.appendingPathComponent("build/Minutes.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: mac, withIntermediateDirectories: true)
func render(size: Int, rounded: Bool) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw CocoaError(.fileWriteUnknown) }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let scale = CGFloat(size) / 1024
    let transform = NSAffineTransform(); transform.scale(by: scale); transform.concat()
    let bounds = NSRect(x: 0, y: 0, width: 1024, height: 1024)
    let shape = NSBezierPath(roundedRect: bounds, xRadius: rounded ? 220 : 0, yRadius: rounded ? 220 : 0)
    shape.addClip()
    NSGradient(starting: NSColor(srgbRed: 0.07, green: 0.26, blue: 0.65, alpha: 1), ending: NSColor(srgbRed: 0.22, green: 0.62, blue: 0.94, alpha: 1))!.draw(in: bounds, angle: 60)
    let halo = NSBezierPath(ovalIn: NSRect(x: -100, y: 680, width: 1400, height: 420))
    NSColor.white.withAlphaComponent(0.12).setFill(); halo.fill()
    for (index, height) in [170, 320, 470, 320, 170].enumerated() {
        let x = CGFloat(280 + index * 100)
        let frame = NSRect(x: x, y: CGFloat(512 - height / 2), width: 64, height: CGFloat(height))
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowBlurRadius = 22; shadow.shadowOffset = NSSize(width: 0, height: -10)
        shadow.shadowColor = NSColor(srgbRed: 0.02, green: 0.12, blue: 0.36, alpha: 0.28); shadow.set()
        let bar = NSBezierPath(roundedRect: frame, xRadius: 32, yRadius: 32)
        NSGradient(starting: .white, ending: NSColor.white.withAlphaComponent(0.74))!.draw(in: bar, angle: -90)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.7).setStroke(); bar.lineWidth = 1.5; bar.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    var result = bitmap
    if !rounded {
        guard let rgb = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let source = bitmap.bitmapData, let target = rgb.bitmapData else { throw CocoaError(.fileWriteUnknown) }
        for y in 0..<size { for x in 0..<size { for c in 0..<3 {
            target[y * rgb.bytesPerRow + x * 3 + c] = source[y * bitmap.bytesPerRow + x * 4 + c]
        } } }
        result = rgb
    }
    guard let png = result.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    return png
}
try render(size: 1024, rounded: false).write(to: assets.appendingPathComponent("Minutes-1024.png"))
try Data("{\"images\":[{\"filename\":\"Minutes-1024.png\",\"idiom\":\"universal\",\"platform\":\"ios\",\"size\":\"1024x1024\"}],\"info\":{\"author\":\"xcode\",\"version\":1}}".utf8).write(to: assets.appendingPathComponent("Contents.json"))
let catalog = assets.deletingLastPathComponent()
try Data("{\"info\":{\"author\":\"xcode\",\"version\":1}}".utf8).write(to: catalog.appendingPathComponent("Contents.json"))
for size in [16, 32, 128, 256, 512] {
    try render(size: size, rounded: true).write(to: mac.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size: size * 2, rounded: true).write(to: mac.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
