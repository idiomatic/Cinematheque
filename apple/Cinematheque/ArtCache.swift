import AppKit
import CryptoKit
import ImageIO
import SwiftUI

/// Covers, fetched from repositories by range request, scaled down off the
/// main thread, and kept: in memory for what's on screen and near it, and
/// on disk, in the app's caches, for the rest.
actor ArtCache {
    static let shared = ArtCache()

    enum Size: Int {
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

final class CGImageBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

/// A cover, or until it's loaded (or if there's none), a color of its own
/// with its title, in a fixed frame, so the grid never waits on an image.
struct CoverImage: View {
    let cover: Cover?
    let title: String
    var size: ArtCache.Size = .tile
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            // From memory at once, so scrolling back shows no placeholder.
            if let image = image ?? cover.flatMap({ ArtCache.shared.cached($0, size) }) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
        }
        .clipped()
        .task(id: cover) {
            guard let cover else { return }
            if ArtCache.shared.cached(cover, size) != nil { return }
            image = await ArtCache.shared.image(cover, size)
        }
    }

    private var placeholder: some View {
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
