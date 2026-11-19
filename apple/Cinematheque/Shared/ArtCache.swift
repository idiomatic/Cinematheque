import CCinematheque
import CryptoKit
import ImageIO
import SwiftUI

/// Covers, fetched from sources by range request, scaled down off the
/// main thread, and kept: in memory for what's on screen and near it, and
/// on disk, in the app's caches, for the rest.
actor ArtCache {
    static let shared = ArtCache()

    enum Size: Int, CaseIterable {
        /// A grid tile's, at 2x.
        case tile = 480
        /// The inspector's.
        case large = 1200
    }

    /// NSCache is safe to use from any thread.
    nonisolated(unsafe) private let memory = NSCache<NSString, CGImageBox>()
    private var loading: [String: Task<CGImage?, Never>] = [:]
    private let directory: URL
    private let session: URLSession

    init() {
        memory.countLimit = 600
        directory = URL.cachesDirectory.appending(path: "com.rbrian.cinematheque/covers", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    /// The cover at `size`, from memory if it's there.
    nonisolated func cached(_ cover: Cover, _ size: Size) -> CGImage? {
        memory.object(forKey: Self.name(cover, size) as NSString)?.image
    }

    func image(_ cover: Cover, _ size: Size) async -> CGImage? {
        let name = Self.name(cover, size)
        if let box = memory.object(forKey: name as NSString) { return box.image }
        if let task = loading[name] { return await task.value }
        let task = Task.detached(priority: size == .tile ? .utility : .userInitiated) { [directory, session] () -> CGImage? in
            let file = directory.appending(path: name + ".jpg")
            if let image = Self.decode(try? Data(contentsOf: file), size) { return image }
            guard let url = URL(string: cover.url), cover.length > 0 else { return nil }
            var request = URLRequest(url: url)
            request.setValue("bytes=\(cover.offset)-\(cover.offset + cover.length - 1)", forHTTPHeaderField: "Range")
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 206 || cover.offset == 0,
                  let image = Self.decode(data, size) else { return nil }
            Self.save(image, to: file)
            return image
        }
        loading[name] = task
        let image = await task.value
        loading[name] = nil
        if let image { memory.setObject(CGImageBox(image), forKey: name as NSString) }
        return image
    }

    private static func name(_ cover: Cover, _ size: Size) -> String {
        let digest = SHA256.hash(data: Data("\(cover.url)|\(cover.offset)|\(cover.length)|\(cover.stamp)".utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined() + "-\(size.rawValue)"
    }

    /// Decodes and scales an image, no larger than `size` on its longer side.
    private static func decode(_ data: Data?, _ size: Size) -> CGImage? {
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: size.rawValue,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func save(_ image: CGImage, to file: URL) {
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }
}

nonisolated final class CGImageBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

/// Covers' placeholders, rendered by the core from their ThumbHashes (32
/// pixels on the longer side, blurred further by scaling up), and kept in
/// memory.
enum Placeholder {
    /// NSCache is safe to use from any thread.
    nonisolated(unsafe) private static let memory = NSCache<NSString, CGImageBox>()

    static func image(_ hash: String) -> CGImage? {
        if let box = memory.object(forKey: hash as NSString) { return box.image }
        var rgba = [UInt8](repeating: 0, count: 32 * 32 * 4)
        var width: Int32 = 0
        var height: Int32 = 0
        guard cq_thumbhash(hash, &rgba, &width, &height) == 0,
              let provider = CGDataProvider(data: Data(rgba[0..<Int(width * height * 4)]) as CFData),
              let image = CGImage(width: Int(width), height: Int(height), bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: Int(width) * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        memory.setObject(CGImageBox(image), forKey: hash as NSString)
        return image
    }
}

/// A cover, or until it's loaded, its placeholder: a blurred likeness from
/// its ThumbHash, or without one, a color of its own with its title; in a
/// fixed frame, so the grid never waits on an image. A cover fills its
/// frame, cropped, unless `fit`, then it's whole and centered in it (e.g.,
/// a season's cover of another shape in a square).
struct CoverImage: View {
    let cover: Cover?
    let thumb: String?
    let title: String
    let size: ArtCache.Size
    let fit: Bool
    /// The cover, once loaded: from memory at once when the view is made,
    /// so scrolling back shows no placeholder, else when it arrives.
    @State private var image: CGImage?

    init(cover: Cover?, thumb: String? = nil, title: String, size: ArtCache.Size = .tile, fit: Bool = false) {
        self.cover = cover
        self.thumb = thumb
        self.title = title
        self.size = size
        self.fit = fit
        _image = State(initialValue: cover.flatMap { ArtCache.shared.cached($0, size) })
    }

    var body: some View {
        ZStack {
            if let image, fit {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
            } else if let image {
                Self.filling(Image(decorative: image, scale: 1).resizable())
            } else {
                placeholder
            }
        }
        .clipped()
        .task(id: cover) {
            guard let cover else { return }
            if let cached = ArtCache.shared.cached(cover, size) {
                image = cached
                return
            }
            if let loaded = await ArtCache.shared.image(cover, size) { image = loaded }
        }
    }

    /// An image filling the frame offered, cropped to it: an image scaled
    /// to fill reports a size larger than its frame.
    private static func filling(_ image: Image) -> some View {
        Color.clear
            .overlay { image.aspectRatio(contentMode: .fill) }
            .clipped()
    }

    @ViewBuilder
    private var placeholder: some View {
        if let thumb, let image = Placeholder.image(thumb) {
            Self.filling(Image(decorative: image, scale: 1).resizable().interpolation(.high))
        } else {
            colored
        }
    }

    private var colored: some View {
        // Stable across launches, unlike hashValue.
        let hue = Double(title.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff } % 360) / 360
        return ZStack {
            Color(hue: hue, saturation: 0.35, brightness: 0.45)
            Text(title)
                .font(.headline)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .padding(8)
        }
    }
}
