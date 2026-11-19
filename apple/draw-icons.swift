// Draws Cinematheque's placeholder icons: a cinema-red gradient, and the
// film.stack symbol in white, as layers (tvOS's parallax) or flattened.
// Usage: swift draw-icons.swift OUTPUT_DIR, then copy the PNGs into
// Cinematheque/Assets.xcassets (AppIcon, and App Icon & Top Shelf Image),
// whose file names they keep.
import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift draw-icons.swift OUTPUT_DIR\n".utf8))
    exit(2)
}
let out = URL(fileURLWithPath: CommandLine.arguments[1])

enum Layer { case back, front, flat, mac }

func draw(_ width: Int, _ height: Int, _ layer: Layer, title: Bool = false, symbolScale: CGFloat = 0.55, to name: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let w = CGFloat(width), h = CGFloat(height)
    // The Mac's icon grid: a rounded square 824 of 1024 across, centered,
    // so the system takes it as it is rather than setting it on a plate.
    var box = NSRect(x: 0, y: 0, width: w, height: h)
    if layer == .mac {
        let inset = w * 100 / 1024
        box = box.insetBy(dx: inset, dy: inset)
        NSBezierPath(roundedRect: box, xRadius: box.width * 0.225, yRadius: box.width * 0.225).addClip()
    }
    if layer != .front {
        let gradient = NSGradient(colors: [
            NSColor(red: 0.62, green: 0.07, blue: 0.12, alpha: 1),
            NSColor(red: 0.30, green: 0.02, blue: 0.07, alpha: 1),
        ])!
        gradient.draw(in: box, angle: -90)
    }
    if layer != .back {
        let side = min(box.width, box.height) * symbolScale
        let config = NSImage.SymbolConfiguration(pointSize: side, weight: .regular)
            .applying(.init(paletteColors: [.white]))
        if let symbol = NSImage(systemSymbolName: "film.stack", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let size = symbol.size
            let scale = side / max(size.width, size.height)
            let s = NSSize(width: size.width * scale, height: size.height * scale)
            // With a title, the symbol and the name together, centered.
            let font = NSFont.systemFont(ofSize: h * 0.16, weight: .semibold)
            let text = NSAttributedString(string: "Cinematheque", attributes: [.font: font, .foregroundColor: NSColor.white])
            let gap = h * 0.08
            let total = title ? s.width + gap + text.size().width : s.width
            let x = box.minX + (box.width - total) / 2
            symbol.draw(in: NSRect(x: x, y: box.minY + (box.height - s.height) / 2, width: s.width, height: s.height))
            if title {
                text.draw(at: NSPoint(x: x + s.width + gap, y: (h - text.size().height) / 2))
            }
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    let file = out.appendingPathComponent(name)
    try! FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! rep.representation(using: .png, properties: [:])!.write(to: file)
}

// macOS: on its icon grid.
for (size, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for scale in scales {
        draw(size * scale, size * scale, .mac, to: "mac/icon_\(size)x\(size)@\(scale)x.png")
    }
}
// tvOS: the Home Screen icon and the App Store's, in two layers each.
for (name, w, h, scales) in [("App Icon", 400, 240, [1, 2]), ("App Icon - App Store", 1280, 768, [1])] {
    for scale in scales {
        draw(w * scale, h * scale, .back, to: "tv/\(name)/back@\(scale)x.png")
        draw(w * scale, h * scale, .front, symbolScale: 0.5, to: "tv/\(name)/front@\(scale)x.png")
    }
}
// tvOS: the Top Shelf, with the app's name.
for (name, w, h) in [("Top Shelf Image", 1920, 720), ("Top Shelf Image Wide", 2320, 720)] {
    for scale in [1, 2] {
        draw(w * scale, h * scale, .flat, title: true, symbolScale: 0.32, to: "tv/\(name)/shelf@\(scale)x.png")
    }
}
