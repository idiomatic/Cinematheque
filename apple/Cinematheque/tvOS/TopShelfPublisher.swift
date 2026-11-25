#if os(tvOS)
import CryptoKit
import ImageIO
import OSLog
import SwiftUI
import TVServices
import UniformTypeIdentifiers

/// What the Top Shelf extension shows, written where it can read it (the
/// app group's container): Continue Watching, then each list, as
/// Home's rows, each title with its cover as a JPEG beside the list. The
/// extension reads `TopShelf/ContentProvider.swift`'s copy of this shape.
enum TopShelfPublisher {
    static let group = "group.com.rbrian.cinematheque"
    /// Where in the group's container: its caches, the only place a tvOS
    /// device lets an app write (the simulator lets it write anywhere).
    /// The extension's `ContentProvider` reads the same.
    static let path = "Library/Caches/TopShelf"
    private static let log = Logger(subsystem: "com.rbrian.cinematheque", category: "topshelf")
    /// The most of each section the Top Shelf shows.
    private static let most = 12

    struct Content: Codable, Equatable {
        struct Section: Codable, Equatable {
            let title: String
            let items: [Item]
        }

        struct Item: Codable, Equatable {
            let id: String
            let title: String
            /// The cover's file, in the container's `TopShelf` directory.
            let image: String?
            /// A movie's poster, or a season's square.
            let square: Bool
            /// Its page's link (select), and the link that plays it at once
            /// (Play/Pause).
            let url: String
            var play: String?
        }

        let sections: [Section]
    }

    /// The link that opens a tile's page, by its ID.
    static func url(tile: String) -> URL? {
        var parts = URLComponents()
        parts.scheme = "cinematheque"
        parts.host = "title"
        parts.queryItems = [URLQueryItem(name: "tile", value: tile)]
        return parts.url
    }

    /// The link that plays a tile at once (its Top Shelf item's Play/Pause).
    static func playURL(_ tile: Tile) -> URL? {
        guard var parts = url(tile: tile.id).flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else { return nil }
        parts.queryItems?.append(URLQueryItem(name: "play", value: "1"))
        return parts.url
    }

    /// How a link opens its tile: playing it at once (`play=1`, the Top
    /// Shelf's Play/Pause), else showing its page.
    static func opening(_ url: URL) -> Opening {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "play" && $0.value == "1" } == true ? .play : .show
    }

    /// The tile a link opens, if it's one of the library's.
    static func tile(_ url: URL, in library: Library) -> Tile? {
        guard url.scheme == "cinematheque", url.host == "title",
              let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "tile" })?.value
        else { return nil }
        return library.tiles.first { $0.id == id }
    }

    /// Bumped as what the Top Shelf shows is cleared, so a publishing
    /// under way then doesn't write it back.
    @MainActor private static var generation = 0

    /// Writes what Home shows, telling tvOS only if it changed: at once,
    /// with the covers already here (else placeholders), then again as the
    /// rest arrive, each kept as it comes. Covers fetched one by one from
    /// sources whose disks may be asleep took longer than the library
    /// stayed unchanged while it synced and crawled, and publishing began
    /// again each time, so nothing was ever written.
    @MainActor static func publish(_ library: Library) async {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            return log.error("No app group container: the Top Shelf can't be written")
        }
        let directory = container.appending(path: path, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return log.error("Top Shelf not written: \(error.localizedDescription, privacy: .public)")
        }
        let started = generation
        let rows = [("Continue Watching", Array(Shelf.home.tiles(in: library).prefix(most)))]
            + library.lists.map { ($0.shownName, Array(Shelf.list($0.id).tiles(in: library).filter { !$0.isWanted }.prefix(most))) }
            .filter { !$0.1.isEmpty }
        var missing = false
        /// What it shows, each cover as `image` finds it.
        func content(_ image: (Tile) async -> String?) async -> Content {
            var sections: [Content.Section] = []
            for (title, tiles) in rows {
                var items: [Content.Item] = []
                for tile in tiles {
                    guard let url = url(tile: tile.id) else { continue }
                    let image = await image(tile)
                    if image == nil { missing = true }
                    items.append(.init(id: tile.id, title: tile.seasonName.map { "\(tile.name) · \($0)" } ?? tile.name, image: image ?? placeholder(tile, in: directory), square: tile.season != nil, url: url.absoluteString, play: playURL(tile)?.absoluteString))
                }
                sections.append(.init(title: title, items: items))
            }
            return Content(sections: sections)
        }
        // The covers already here first, then those fetched.
        write(await content { cover($0, in: directory) }, in: directory, started: started)
        // The covers not here yet; a newer publishing, begun as the library
        // changed, takes over, with those already fetched.
        guard missing, !Task.isCancelled else { return }
        missing = false
        let fetched = await content { tile in
            if let image = cover(tile, in: directory) { return image }
            return Task.isCancelled ? nil : await fetch(tile, in: directory)
        }
        if !Task.isCancelled { write(fetched, in: directory, started: started) }
    }

    /// Writes what the Top Shelf shows, if it's changed and hasn't been
    /// cleared since publishing began, and covers no longer listed go.
    @MainActor private static func write(_ content: Content, in directory: URL, started: Int) {
        guard generation == started else { return }
        let sections = content.sections
        let file = directory.appending(path: "content.json")
        if let old = try? Data(contentsOf: file), (try? JSONDecoder().decode(Content.self, from: old)) == content { return }
        guard let data = try? JSONEncoder().encode(content) else { return }
        do {
            try data.write(to: file, options: .atomic)
        } catch {
            return log.error("Top Shelf not written: \(error.localizedDescription, privacy: .public)")
        }
        log.notice("Top Shelf written: \(sections.count, privacy: .public) rows of \(sections.map { String($0.items.count) }.joined(separator: ", "), privacy: .public) titles")
        TVTopShelfContentProvider.topShelfContentDidChange()
        let kept = Set(sections.flatMap(\.items).compactMap(\.image))
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasSuffix(".jpg") && !kept.contains(name) {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }

    /// Forgets what the Top Shelf shows, as a device leaving its library
    /// does, so it lists none of its titles.
    @MainActor static func clear() {
        generation += 1
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return }
        try? FileManager.default.removeItem(at: container.appending(path: path, directoryHint: .isDirectory))
        TVTopShelfContentProvider.topShelfContentDidChange()
    }

    /// A tile's cover as a JPEG in the directory, named for the cover, so
    /// it's written once: if it's here already, or in memory.
    private static func cover(_ tile: Tile, in directory: URL) -> String? {
        guard let cover = tile.cover else { return nil }
        let name = coverName(cover)
        let file = directory.appending(path: name)
        if FileManager.default.fileExists(atPath: file.path) { return name }
        if let image = ArtCache.shared.cached(cover, .tile), write(image, to: file) { return name }
        return nil
    }

    /// A tile's cover, fetched (from the app's caches, or its source).
    private static func fetch(_ tile: Tile, in directory: URL) async -> String? {
        guard let cover = tile.cover else { return nil }
        let name = coverName(cover)
        guard let image = await ArtCache.shared.image(cover, .tile), write(image, to: directory.appending(path: name)) else { return nil }
        return name
    }

    private static func coverName(_ cover: Cover) -> String {
        name("\(cover.url) \(cover.offset) \(cover.length) \(cover.stamp)")
    }

    /// A tile's placeholder as the app draws it, rather than the Top
    /// Shelf's dots, for a title without a cover, or until it's fetched.
    @MainActor private static func placeholder(_ tile: Tile, in directory: URL) -> String? {
        let name = name("placeholder \(tile.name) \(tile.season != nil)")
        let file = directory.appending(path: name)
        if FileManager.default.fileExists(atPath: file.path) { return name }
        let width = CGFloat(ArtCache.Size.tile.rawValue) * 2 / 3
        let renderer = ImageRenderer(content: CoverImage(cover: nil, title: tile.name)
            .frame(width: width, height: tile.season != nil ? width : width * 3 / 2))
        renderer.scale = 2
        guard let image = renderer.cgImage, write(image, to: file) else { return nil }
        return name
    }

    private static func name(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined() + ".jpg"
    }

    private static func write(_ image: CGImage, to file: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }
}
#endif
