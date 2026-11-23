// Prints each window on screen, tab-separated: its ID, its owner, its
// layer, and its bounds in points (x y width height); then the screen's
// size in points. Run in a macOS guest by tools/screenshots.sh, to find
// the app's window and the Local Network prompt; it needs no permission.
import CoreGraphics
import Foundation

let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
for w in list {
    guard let id = w[kCGWindowNumber as String] as? Int, let owner = w[kCGWindowOwnerName as String] as? String,
          let b = w[kCGWindowBounds as String] as? [String: Double], (w[kCGWindowLayer as String] as? Int) != nil else { continue }
    print("\(id)\t\(owner)\t\(w[kCGWindowLayer as String]!)\t\(Int(b["X"]!)) \(Int(b["Y"]!)) \(Int(b["Width"]!)) \(Int(b["Height"]!))")
}
let s = CGDisplayBounds(CGMainDisplayID())
print("screen\t\(Int(s.width)) \(Int(s.height))")
