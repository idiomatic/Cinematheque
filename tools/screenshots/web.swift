// Renders the web client, or any page, to a PNG at this Mac's display's
// scale (twice its size in points, on a Retina one), in dark or light, once every image on screen has
// loaded: `web URL WIDTHxHEIGHT dark|light OUT.png`. For
// tools/screenshots.sh, as this Mac has WebKit but no headless browser.
import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count == 5, let url = URL(string: args[1]) else {
    FileHandle.standardError.write(Data("usage: web URL WIDTHxHEIGHT dark|light OUT.png\n".utf8))
    exit(2)
}
let size = args[2].split(separator: "x").compactMap { Double($0) }
let appearance = NSAppearance(named: args[3] == "dark" ? .darkAqua : .aqua)
let out = URL(filePath: args[4])

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
app.appearance = appearance
// On screen but clear, and clicked through: off screen, WebKit runs no
// animation frames, by which the web client builds its shelves.
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: size[0], height: size[1]), styleMask: [.borderless], backing: .buffered, defer: false)
let web = WKWebView(frame: NSRect(x: 0, y: 0, width: size[0], height: size[1]))
web.appearance = appearance
window.contentView = web
window.alphaValue = 0
window.ignoresMouseEvents = true
window.orderFrontRegardless()
web.load(URLRequest(url: url))

// Ready once tiles are shown and every image in view has loaded (covers
// load as they near the screen), twice in a row, a quarter second apart.
let ready = """
    (() => {
      const tiles = document.querySelectorAll('.tile').length;
      const imgs = [...document.images].filter((i) => i.getBoundingClientRect().top < innerHeight);
      return tiles > 0 && imgs.length > 0 && imgs.every((i) => i.complete && i.naturalWidth > 0);
    })()
    """
var streak = 0
var tries = 0
func check() {
    tries += 1
    if tries > 240 {
        FileHandle.standardError.write(Data("error: \(url) didn't finish loading in a minute\n".utf8))
        exit(1)
    }
    web.evaluateJavaScript(ready) { result, _ in
        streak = (result as? Bool) == true ? streak + 1 : 0
        if streak < 2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: check)
            return
        }
        let config = WKSnapshotConfiguration()
        // In points, rendered at the display's scale.
        config.snapshotWidth = NSNumber(value: size[0])
        web.takeSnapshot(with: config) { image, error in
            guard let image, let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                FileHandle.standardError.write(Data("error: no snapshot: \(error?.localizedDescription ?? "")\n".utf8))
                exit(1)
            }
            try! png.write(to: out)
            exit(0)
        }
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: check)
app.run()
