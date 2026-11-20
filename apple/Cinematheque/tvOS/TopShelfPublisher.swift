#if os(tvOS)
import CryptoKit
import ImageIO
import SwiftUI
import TVServices
import UniformTypeIdentifiers

/// What the Top Shelf extension shows, written where it can read it (the
/// app group's container): Continue Watching, then the watchlist, as
/// Home's rows, each title with its cover as a JPEG beside the list. The
/// extension reads `TopShelf/ContentProvider.swift`'s copy of this shape.
enum TopShelfPublisher {
    static let group = "group.com.rbrian.cinematheque"
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
            let url: String
        }

        let sections: [Section]
    }

    /// The link that opens a tile's page.
    static func url(_ tile: Tile) -> URL? {
        var parts = URLComponents()
        parts.scheme = "cinematheque"
        parts.host = "title"
        parts.queryItems = [URLQueryItem(name: "tile", value: tile.id)]
        return parts.url
    }

    /// The tile a link opens, if it's one of the library's.
    static func tile(_ url: URL, in library: Library) -> Tile? {
        guard url.scheme == "cinematheque", url.host == "title",
              let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "tile" })?.value
        else { return nil }
        return library.tiles.first { $0.id == id }
    }

    /// Writes what Home shows, and its covers, telling tvOS only if it
    /// changed.
    static func publish(_ library: Library) async {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return }
        let directory = container.appending(path: "TopShelf", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rows = [
            ("Continue Watching", Array(Shelf.home.tiles(in: library).prefix(most))),
            ("Watchlist", Array(library.perTitle(Shelf.watchlist.tiles(in: library)).prefix(most))),
        ]
        var sections: [Content.Section] = []
        for (title, tiles) in rows where !tiles.isEmpty {
            var items: [Content.Item] = []
            for tile in tiles {
                guard let url = url(tile) else { continue }
                items.append(.init(id: tile.id, title: tile.seasonName.map { "\(tile.name) · \($0)" } ?? tile.name, image: await cover(tile, in: directory), square: tile.season != nil, url: url.absoluteString))
            }
            sections.append(.init(title: title, items: items))
        }
        let content = Content(sections: sections)
        let file = directory.appending(path: "content.json")
        if let old = try? Data(contentsOf: file), (try? JSONDecoder().decode(Content.self, from: old)) == content { return }
        guard let data = try? JSONEncoder().encode(content) else { return }
        try? data.write(to: file, options: .atomic)
        TVTopShelfContentProvider.topShelfContentDidChange()
        // Covers no longer listed go.
        let kept = Set(sections.flatMap(\.items).compactMap(\.image))
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasSuffix(".jpg") && !kept.contains(name) {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }

    /// A tile's cover as a JPEG in the directory, named for the cover, so
    /// it's written once.
    private static func cover(_ tile: Tile, in directory: URL) async -> String? {
        guard let cover = tile.cover else { return nil }
        let digest = SHA256.hash(data: Data("\(cover.url) \(cover.offset) \(cover.length) \(cover.stamp)".utf8))
        let name = digest.prefix(12).map { String(format: "%02x", $0) }.joined() + ".jpg"
        let file = directory.appending(path: name)
        if FileManager.default.fileExists(atPath: file.path) { return name }
        guard let image = await ArtCache.shared.image(cover, .tile),
              let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? name : nil
    }
}
#endif
