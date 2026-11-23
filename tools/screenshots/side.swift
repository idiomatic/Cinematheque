// Sets screenshots side by side, each with rounded corners, on a clear
// ground: `side OUT.png GAP RADIUS IN.png...`, the gap and radius in
// pixels, every image the first's height. For tools/screenshots.sh, as a
// phone's one tall screen stood far taller than the others in a row.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 5, let gap = Double(args[2]), let radius = Double(args[3]) else {
    FileHandle.standardError.write(Data("usage: side OUT.png GAP RADIUS IN.png...\n".utf8))
    exit(2)
}
let images = args[4...].map { path -> CGImage in
    guard let source = CGImageSourceCreateWithURL(URL(filePath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        FileHandle.standardError.write(Data("error: can't read \(path)\n".utf8))
        exit(1)
    }
    return image
}
let height = Double(images[0].height)
let widths = images.map { Double($0.width) * height / Double($0.height) }
let width = widths.reduce(0, +) + gap * Double(images.count - 1)
guard let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
var x = 0.0
for (image, w) in zip(images, widths) {
    let frame = CGRect(x: x, y: 0, width: w, height: height)
    context.saveGState()
    context.addPath(CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.clip()
    context.draw(image, in: frame)
    context.restoreGState()
    x += w + gap
}
guard let image = context.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(filePath: args[1]) as CFURL, UTType.png.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(dest, image, nil)
exit(CGImageDestinationFinalize(dest) ? 0 : 1)
