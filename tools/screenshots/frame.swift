// Crops a screenshot to a window and makes its rounded corners clear, as
// macOS's own window screenshots have them: `frame IN.png OUT.png X Y
// WIDTH HEIGHT RADIUS SCALE`, the rectangle and radius in points, SCALE
// the shot's pixels a point. For tools/screenshots.sh, as screencapture
// can't capture a window in a VM without Screen Recording permission.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 9, let n = Optional(args[3...8].compactMap { Double($0) }), n.count == 6,
      let source = CGImageSourceCreateWithURL(URL(filePath: args[1]) as CFURL, nil),
      let shot = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    FileHandle.standardError.write(Data("usage: frame IN.png OUT.png X Y WIDTH HEIGHT RADIUS SCALE\n".utf8))
    exit(2)
}
let scale = n[5]
let rect = CGRect(x: n[0] * scale, y: n[1] * scale, width: n[2] * scale, height: n[3] * scale).integral
guard let window = shot.cropping(to: rect),
      let context = CGContext(data: nil, width: window.width, height: window.height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
let bounds = CGRect(x: 0, y: 0, width: window.width, height: window.height)
let radius = n[4] * scale
context.addPath(CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil))
context.clip()
context.draw(window, in: bounds)
guard let image = context.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(filePath: args[2]) as CFURL, UTType.png.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(dest, image, nil)
exit(CGImageDestinationFinalize(dest) ? 0 : 1)
