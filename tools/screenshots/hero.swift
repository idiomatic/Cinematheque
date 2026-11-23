// Sets a Mac window's shot and an Apple TV's screen into one picture, the
// TV's in front of the window's lower right, as a screen beside it, so the
// first look says "your own library, on the screens you have":
// `hero OUT.png MAC.png TV.png`, on a clear ground. The TV's screen is
// 0.42 of the window's width, in a thin black bezel with rounded corners,
// over a soft shadow. For tools/screenshots.sh.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 4 else {
    FileHandle.standardError.write(Data("usage: hero OUT.png MAC.png TV.png\n".utf8))
    exit(2)
}
func load(_ path: String) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(filePath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        FileHandle.standardError.write(Data("error: can't read \(path)\n".utf8))
        exit(1)
    }
    return image
}
let mac = load(args[2]), tv = load(args[3])
let w = Double(mac.width), h = Double(mac.height)
// The TV's screen, its bezel, and how far it reaches past the window.
let screenWidth = w * 0.42
let screenHeight = screenWidth * Double(tv.height) / Double(tv.width)
let bezel = screenWidth * 0.018
let past = (x: w * 0.1, y: h * 0.18)
let width = w + past.x, height = h + past.y
guard let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
// Core Graphics' origin is the lower left: the window at the top left.
context.draw(mac, in: CGRect(x: 0, y: past.y, width: w, height: h))
let set = CGRect(x: width - screenWidth - 2 * bezel, y: 0, width: screenWidth + 2 * bezel, height: screenHeight + 2 * bezel)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -w * 0.006), blur: w * 0.025, color: CGColor(gray: 0, alpha: 0.55))
context.addPath(CGPath(roundedRect: set, cornerWidth: bezel * 1.6, cornerHeight: bezel * 1.6, transform: nil))
context.setFillColor(CGColor(gray: 0.04, alpha: 1))
context.fillPath()
context.restoreGState()
context.saveGState()
let screen = set.insetBy(dx: bezel, dy: bezel)
context.addPath(CGPath(roundedRect: screen, cornerWidth: bezel * 0.5, cornerHeight: bezel * 0.5, transform: nil))
context.clip()
context.draw(tv, in: screen)
context.restoreGState()
guard let image = context.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(filePath: args[1]) as CFURL, UTType.png.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(dest, image, nil)
exit(CGImageDestinationFinalize(dest) ? 0 : 1)
