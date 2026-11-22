// Draws mock-library.sh's covers: for each line of stdin (an output PNG,
// width, height, top and bottom colors as hex, a title, and a line under
// it, tab-separated), a gradient with a pale disc and the title set large.
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

func color(_ hex: Substring, alpha: CGFloat = 1) -> CGColor {
    let v = UInt32(hex, radix: 16) ?? 0
    return CGColor(srgbRed: CGFloat(v >> 16 & 0xff) / 255, green: CGFloat(v >> 8 & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: alpha)
}

// Set in the first face found, as a Mac has them.
let faces = ["Futura-Bold", "AvenirNext-Bold", "HelveticaNeue-Bold"]
let face = faces.first { CTFontCopyPostScriptName(CTFontCreateWithName($0 as CFString, 12, nil)) as String == $0 } ?? "Helvetica-Bold"

func text(_ s: String, size: CGFloat, alpha: CGFloat = 1) -> NSAttributedString {
    var align = CTTextAlignment.center
    let style = withUnsafeBytes(of: &align) { bytes in
        [CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: bytes.baseAddress!)].withUnsafeBufferPointer {
            CTParagraphStyleCreate($0.baseAddress!, 1)
        }
    }
    return NSAttributedString(string: s, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(face as CFString, size, nil),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: alpha),
        NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style,
    ])
}

/// Draws `s` in `box`, as large as fits with no word broken.
func draw(_ s: String, in box: CGRect, largest: CGFloat, on context: CGContext) {
    var size = largest
    while size > 8 {
        let t = text(s, size: size)
        let widest = s.split(separator: " ").map { CTLineGetTypographicBounds(CTLineCreateWithAttributedString(text(String($0), size: size)), nil, nil, nil) }.max() ?? 0
        let setter = CTFramesetterCreateWithAttributedString(t)
        let fits = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, CGSize(width: box.width, height: .greatestFiniteMagnitude), nil)
        if widest <= box.width, fits.height <= box.height {
            // Set at the box's top.
            let frame = CGRect(x: box.minX, y: box.maxY - fits.height, width: box.width, height: fits.height)
            CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: frame, transform: nil), nil), context)
            return
        }
        size -= 2
    }
}

while let line = readLine() {
    let f = line.split(separator: "\t", omittingEmptySubsequences: false)
    guard f.count == 7, let w = Int(f[1]), let h = Int(f[2]) else { continue }
    let width = CGFloat(w), height = CGFloat(h)
    let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let gradient = CGGradient(colorsSpace: nil, colors: [color(f[3]), color(f[4])] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: .zero, options: [])
    // A disc, a moon or a planet, low and to one side.
    let r = min(width, height) * 0.42
    context.setFillColor(color(f[3], alpha: 0.55))
    context.fillEllipse(in: CGRect(x: width * 0.62 - r, y: height * 0.3 - r, width: 2 * r, height: 2 * r))
    let margin = width * 0.08
    draw(String(f[5]).uppercased(), in: CGRect(x: margin, y: height * 0.35, width: width - 2 * margin, height: height * 0.57), largest: min(width, height) * 0.2, on: context)
    let under = text(String(f[6]).uppercased(), size: min(width, height) * 0.055, alpha: 0.85)
    let underLine = CTLineCreateWithAttributedString(under)
    let underWidth = CTLineGetTypographicBounds(underLine, nil, nil, nil)
    context.textPosition = CGPoint(x: (width - underWidth) / 2, y: height * 0.06)
    CTLineDraw(underLine, context)
    let out = CGImageDestinationCreateWithURL(URL(fileURLWithPath: String(f[0])) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(out, context.makeImage()!, nil)
    CGImageDestinationFinalize(out)
}
