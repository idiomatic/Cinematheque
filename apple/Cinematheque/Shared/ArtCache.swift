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
    /// When each cover that failed to load did, so scrolling back doesn't
    /// ask again at once.
    private var failed: [String: ContinuousClock.Instant] = [:]
    private let directory: URL
    private let session: URLSession

    /// What the disk cache keeps: files unused for 60 days go, then the
    /// oldest while it's over 500 MB.
    private static let diskAge: TimeInterval = 60 * 24 * 3600
    private static let diskBytes = 500 << 20

    /// The largest cover read: an MP4's are a few hundred kilobytes.
    private static let largest = 32 << 20

    init() {
        memory.totalCostLimit = 256 << 20
        directory = URL.cachesDirectory.appending(path: "com.rbrian.cinematheque/covers", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Task.detached(priority: .background) { [directory] in Self.prune(directory) }
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
        if let when = failed[name], ContinuousClock.now - when < .seconds(30) { return nil }
        let task = Task.detached(priority: size == .tile ? .utility : .userInitiated) { [directory, session] () -> CGImage? in
            let file = directory.appending(path: name + ".jpg")
            if let image = Self.decode(try? Data(contentsOf: file), size) {
                // Used now, for pruning by age.
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
                return image
            }
            // From a web server alone, and no more than the cover, whatever
            // a server sends: its address and range are other devices' word.
            guard let url = URL(web: cover.url), cover.length > 0, cover.length <= Self.largest else { return nil }
            var request = URLRequest(url: url)
            request.setValue("bytes=\(cover.offset)-\(cover.offset + cover.length - 1)", forHTTPHeaderField: "Range")
            guard let (bytes, response) = try? await session.bytes(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 206 || cover.offset == 0 else { return nil }
            var data = Data(capacity: cover.length)
            do {
                for try await byte in bytes {
                    data.append(byte)
                    if data.count == cover.length { break }
                }
            } catch { return nil }
            guard let image = Self.decode(data, size) else { return nil }
            Self.save(image, to: file)
            return image
        }
        loading[name] = task
        let image = await task.value
        loading[name] = nil
        if let image {
            failed[name] = nil
            memory.setObject(CGImageBox(image), forKey: name as NSString, cost: image.bytesPerRow * image.height)
        } else if !Task.isCancelled {
            failed[name] = ContinuousClock.now
        }
        return image
    }

    /// Deletes cached covers unused for `diskAge` (those of old stamps
    /// among them), then the least recently used while over `diskBytes`.
    private static func prune(_ directory: URL) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        var kept: [(url: URL, date: Date, size: Int)] = []
        let cutoff = Date(timeIntervalSinceNow: -diskAge)
        for url in files {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let date = values?.contentModificationDate ?? .distantPast
            if date < cutoff {
                try? FileManager.default.removeItem(at: url)
            } else {
                kept.append((url, date, values?.fileSize ?? 0))
            }
        }
        var total = kept.reduce(0) { $0 + $1.size }
        for file in kept.sorted(by: { $0.date < $1.date }) where total > diskBytes {
            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
        }
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

/// A cover, on a color of its own until it's loaded (with its title, if
/// it has none), in a fixed frame, so the grid never waits on an image. A
/// cover fills its frame, cropped, unless `fit`, then it's whole and
/// centered in it (e.g., a season's cover of another shape in a square);
/// or, `shaped`, it takes its own shape within the frame, as large as
/// fits: the image's, else as the core read it, else a square.
struct CoverImage: View {
    let cover: Cover?
    let aspect: Double?
    let title: String
    let size: ArtCache.Size
    let fit: Bool
    let shaped: Bool
    /// The cover, once loaded: from memory at once when the view is made,
    /// so scrolling back shows no placeholder, else when it arrives.
    @State private var image: CGImage?

    init(cover: Cover?, aspect: Double? = nil, title: String, size: ArtCache.Size = .tile, fit: Bool = false, shaped: Bool = false) {
        self.cover = cover
        self.aspect = aspect
        self.title = title
        self.size = size
        self.fit = fit
        self.shaped = shaped
        _image = State(initialValue: cover.flatMap { ArtCache.shared.cached($0, size) })
    }

    var body: some View {
        Group {
            if shaped {
                Color.clear
                    .aspectRatio(shape, contentMode: .fit)
                    .overlay { framed }
            } else {
                framed
            }
        }
        .task(id: cover) {
            guard let cover else { return }
            if let cached = ArtCache.shared.cached(cover, size) {
                image = cached
                return
            }
            if let loaded = await ArtCache.shared.image(cover, size) { image = loaded }
        }
    }

    /// The placeholder and the cover, both always there, the cover shown
    /// once loaded: so its arriving adds no view, as one added while its
    /// tile moves (as a band opening slides) is drawn where it ends, not
    /// moved with it.
    private var framed: some View {
        let cover = Image(decorative: image ?? Self.blank, scale: 1).resizable()
        return ZStack {
            placeholder.opacity(image == nil ? 1 : 0)
            Group {
                if fit {
                    cover.aspectRatio(contentMode: .fit)
                } else {
                    Self.filling(cover)
                }
            }
            .opacity(image == nil ? 0 : 1)
        }
        .clipped()
    }

    /// A cover not loaded yet: a clear pixel.
    private static let blank: CGImage = {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }()

    /// Width over height: the image's, else as the core read it, else 1.
    private var shape: CGFloat {
        if let image, image.height > 0 { return CGFloat(image.width) / CGFloat(image.height) }
        return Self.shape(aspect: aspect)
    }

    /// A cover's shape before it's loaded: as the core read it, else 1.
    static func shape(aspect: Double?) -> CGFloat { aspect.map { CGFloat($0) } ?? 1 }

    /// An image filling the frame offered, cropped to it: an image scaled
    /// to fill reports a size larger than its frame.
    private static func filling(_ image: Image) -> some View {
        Color.clear
            .overlay { image.aspectRatio(contentMode: .fill) }
            .clipped()
    }

    private var placeholder: some View {
        // Stable across launches, unlike hashValue.
        let hue = Double(title.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff } % 360) / 360
        return ZStack {
            Color(hue: hue, saturation: 0.35, brightness: 0.45)
            if cover == nil {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(8)
            }
        }
    }
}
