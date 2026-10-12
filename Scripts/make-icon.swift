// Draws the app icon into an .iconset directory (Scripts/make-app.sh turns it into an .icns with
// iconutil). Nothing here is a checked-in binary: the icon is code.
//
//     swift Scripts/make-icon.swift dist/Switchboard.iconset
import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.iconset>\n".utf8))
    exit(2)
}
let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

/// One square PNG, `pixels` wide: a rounded square in the macOS icon grid with the "split" glyph.
func render(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }

    let side = CGFloat(pixels)
    let tile = NSRect(x: side * 0.1, y: side * 0.1, width: side * 0.8, height: side * 0.8)
    let path = NSBezierPath(roundedRect: tile, xRadius: side * 0.18, yRadius: side * 0.18)
    NSGradient(
        starting: NSColor(calibratedRed: 0.20, green: 0.42, blue: 0.86, alpha: 1),
        ending: NSColor(calibratedRed: 0.09, green: 0.18, blue: 0.48, alpha: 1)
    )?.draw(in: path, angle: -90)

    let configuration = NSImage.SymbolConfiguration(pointSize: side * 0.42, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "rectangle.split.1x2", accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) {
        let size = symbol.size
        symbol.draw(in: NSRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
    }
    return rep.representation(using: .png, properties: [:])
}

// iconutil's names: icon_<points>x<points>.png and the @2x file with twice the pixels.
let points = [16, 32, 128, 256, 512]
for point in points {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(point)x\(point).png" : "icon_\(point)x\(point)@2x.png"
        guard let data = render(pixels: point * scale) else {
            FileHandle.standardError.write(Data("could not draw \(name)\n".utf8))
            exit(1)
        }
        try data.write(to: outputDirectory.appending(path: name))
    }
}
