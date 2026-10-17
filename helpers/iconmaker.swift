// Fit original artwork at normal Dock size; round only the outer corners.
// Usage: iconmaker <input-image|input.exe> <output.icns>
//        iconmaker --shortcuts <appid> <icon.icns> <stock.icns>

import AppKit
import Foundation

if CommandLine.arguments.count == 5, CommandLine.arguments[1] == "--shortcuts" {
    np_shortcuts_icons(getenv("HOME"), CommandLine.arguments[2], CommandLine.arguments[3], CommandLine.arguments[4])
    exit(0)
}

guard CommandLine.arguments.count == 3 else {
    fputs("usage: iconmaker <input-image|input.exe> <output.icns>\n", stderr)
    exit(1)
}
let inputPath = CommandLine.arguments[1]
let outputPath = CommandLine.arguments[2]

private func loadImage(_ path: String) -> NSImage? {
    var length = 0
    if let raw = np_pe_icon_ico(path, &length) {
        let ico = Data(bytesNoCopy: raw, count: length, deallocator: .free)
        if !ico.isEmpty, let image = NSImage(data: ico) { return image }
    }
    return NSImage(contentsOfFile: path)
}

guard let image = loadImage(inputPath), image.size.width > 0, image.size.height > 0,
      image.size.width.isFinite, image.size.height.isFinite else {
    fputs("iconmaker: cannot read \(inputPath)\n", stderr)
    exit(1)
}

let sizes: [(side: Int, scale: Int, name: String)] = [
    (16, 1, "icon_16x16.png"), (16, 2, "icon_16x16@2x.png"),
    (32, 1, "icon_32x32.png"), (32, 2, "icon_32x32@2x.png"),
    (128, 1, "icon_128x128.png"), (128, 2, "icon_128x128@2x.png"),
    (256, 1, "icon_256x256.png"), (256, 2, "icon_256x256@2x.png"),
    (512, 1, "icon_512x512.png"), (512, 2, "icon_512x512@2x.png"),
]
let fm = FileManager.default
let iconset = URL(fileURLWithPath: outputPath + ".iconset", isDirectory: true)
do {
    try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: iconset) }
    for entry in sizes {
        let px = entry.side * entry.scale
        let side = CGFloat(px)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.bitmapData!.initialize(repeating: 0, count: rep.bytesPerRow * px)
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        let tile = NSRect(x: side * 0.1, y: side * 0.1,
                          width: side * 0.8, height: side * 0.8)
        let radius = tile.width * 0.2237
        NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius).addClip()
        // Fit, rather than fill: keep every edge and the source aspect ratio.
        let scale = min(side * 0.8 / image.size.width, side * 0.8 / image.size.height)
        let width = image.size.width * scale, height = image.size.height * scale
        image.draw(in: NSRect(x: (side - width) / 2, y: (side - height) / 2,
                             width: width, height: height),
                   from: .zero, operation: .copy, fraction: 1)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: iconset.appendingPathComponent(entry.name))
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", iconset.path, "-o", outputPath]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
} catch {
    fputs("iconmaker: failed to build icon: \(error)\n", stderr)
    exit(1)
}
