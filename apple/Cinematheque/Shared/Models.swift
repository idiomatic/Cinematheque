import Foundation

/// A cover: a byte range of a file in a source.
struct Cover: Codable, Hashable {
    let url: String
    let offset: Int
    let length: Int
    /// Changes when the file does.
    let stamp: String
}

/// One tile of the grid: a movie, or a season of a series.
struct Tile: Codable, Identifiable, Hashable {
    let key: String
    let name: String
    let year: Int?
    let kind: String
    let season: Int?
    let cover: Cover?
    /// The cover's placeholder, a ThumbHash in base64.
    let thumb: String?
    /// This person's: every item watched; how far along (0 to 1), by running
    /// time: how many milliseconds have `elapsed` (watched items whole,
    /// those partway to their positions) of the `runtime`; and whether any
    /// item has progress.
    let watched: Bool
    let progress: Double
    let elapsed: Int
    let runtime: Int
    let started: Bool
    /// How many items it holds: a season's episodes (an episode's versions
    /// and parts counting once), a movie's versions and parts.
    let items: Int
    /// Every copy it has is on a drive that isn't there (an unavailable
    /// directory of its source's): shown dimmed.
    var unavailable = false

    var id: String { season.map { "\(key)#\($0)" } ?? key }
    var isSeries: Bool { kind == "series" }
    /// "Season 3", or "Specials" for season 0.
    var seasonName: String? { season.map { $0 == 0 ? "Specials" : "Season \($0)" } }
}

/// One title in full: its metadata, covers, items, and where each copy is.
struct TitleDetail: Codable {
    struct Copy: Codable, Hashable {
        let url: String
        let size: Int
        let source: String
        /// On a drive that isn't there: tried last.
        var unavailable = false
    }

    struct Quality: Codable, Hashable {
        let label: String
        /// As its sources give it.
        let name: String
        /// For a picker, as the core names it ("1080p", "4K HDR", "720p
        /// Very Fast").
        let short: String
        /// Its resolution's lines (2160 for 4K), if it says.
        let height: Int?
        let copies: [Copy]
    }

    /// An item, as the core names it (no key is read here).
    struct Item: Codable, Hashable, Identifiable {
        let key: String
        /// An episode's season and number (a special's number null; a dated
        /// one's season its year).
        let season: Int?
        let number: Int?
        /// "Episode 3", "Special", "March 12", or a version's name.
        let label: String
        /// In a list: "3. Title", or a special's or dated episode's title.
        let name: String
        /// A dated episode's air date, `2024-03-12`.
        let aired: String?
        /// An episode's `title`, `description`, and `duration`.
        let fields: [String: String]
        let qualities: [Quality]
        /// This person's progress, in milliseconds.
        let position: Int
        let duration: Int
        let watched: Bool
        /// The one Play plays, of its season or the movie's versions, as
        /// the core decides.
        let next: Bool
        var id: String { key }

        /// An episode's season and number (a special's, 0).
        var episode: (season: Int, number: Int)? { season.map { ($0, number ?? 0) } }
    }

    let key: String
    let name: String
    let year: Int?
    /// `description`, `genre`, `released`, and `network`.
    let fields: [String: String]
    /// By field: `art`, `art:s01`...
    let covers: [String: Cover]
    let items: [Item]
}

struct Source: Codable, Identifiable, Hashable {
    /// A directory of it that held files and lists none now (an unplugged
    /// drive's mount point): relative to it, empty for the whole of it, and
    /// when it was noticed, in milliseconds since the epoch.
    struct Unavailable: Codable, Hashable {
        let dir: String
        let since: Double

        var name: String { dir.isEmpty ? "All of it" : dir }
        var date: Date { Date(timeIntervalSince1970: since / 1000) }
    }

    let id: String
    let url: String
    let quality: String
    let skip: String
    let copies: Int
    var unavailable: [Unavailable] = []
    /// A device's downloads, which no one crawls (see the core's
    /// download.zig).
    var managed = false

    /// Its server and folders, as a person reads them: "art › Movies ›
    /// 2160p".
    var displayName: String {
        guard let u = URL(string: url), let host = u.host() else { return url.removingPercentEncoding ?? url }
        let parts = u.pathComponents.filter { $0 != "/" }.compactMap { $0.removingPercentEncoding }
        // A NAS's shared folder (e.g., Video) is seldom worth showing.
        let shown = parts.count > 2 ? Array(parts.dropFirst()) : parts
        return ([host.replacing(/\.local$/, with: "")] + shown).joined(separator: " › ")
    }
}

struct Member: Codable, Identifiable, Hashable {
    let key: String
    let name: String?
    let founder: Bool
    let you: Bool
    var id: String { key }
}

/// One of this person's devices that has a name.
struct Device: Codable, Identifiable, Hashable {
    let key: String
    let name: String
    let you: Bool
    var id: String { key }
}

/// A device found nearby, or added by address.
struct NearbyDevice: Codable, Identifiable, Hashable {
    let url: String
    let device: String?
    /// Its host, as DNS-SD resolved it (`Not-Your-AppleTV.local.`).
    let host: String?
    let person: String?
    /// Its person's key.
    let person_key: String?
    /// Of this library.
    let ours: Bool
    /// Its person is a member.
    let member: Bool
    let added: Bool
    /// For a new device offering to be added (`url` is where to pair it):
    /// `new`, as the member's device decides what it is.
    let pairing: String?
    var id: String { url }
    /// Its device's and person's names, if they advertise any. tvOS tells
    /// apps only a generic name ("Apple TV") without an entitlement Apple
    /// grants, but its host is named for the Apple TV, so that stands in.
    var deviceName: String? {
        let advertised = device.flatMap { $0.isEmpty ? nil : $0 }
        guard advertised == nil || Self.generic.contains(advertised!), let named = hostName else { return advertised }
        return named
    }
    var personName: String? { person.flatMap { $0.isEmpty ? nil : $0 } }

    /// The names devices give apps in place of their own.
    private static let generic: Set<String> = ["Apple TV", "iPhone", "iPad"]

    /// Its host's name as a person wrote it, near enough
    /// (`Not-Your-AppleTV.local.` to "Not Your AppleTV"), unless that's
    /// generic too.
    private var hostName: String? {
        guard let host else { return nil }
        var label = host.hasSuffix(".") ? String(host.dropLast()) : host
        if label.hasSuffix(".local") { label = String(label.dropLast(6)) }
        let name = label.replacing("-", with: " ")
        return name.isEmpty || Self.generic.contains(name) ? nil : name
    }
}

/// A device just paired: its person's key and its own.
nonisolated struct Paired: Decodable {
    let person: String
    let device: String
}

/// A folder on this device, served as a source at `prefix`.
struct Folder: Codable, Identifiable, Hashable {
    let prefix: String
    let path: String
    /// The source's URL, as added.
    var url: String
    var id: String { prefix }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

struct Status: Codable, Equatable {
    let person: String
    /// Acting as the person of another of the person's devices.
    let paired: Bool
    let library: String?
    let founder: String?
    let members: Int
    /// How many other devices this person has, named or not.
    let others: Int
    /// How often refreshes not asked for look for new videos, in hours; 0,
    /// only when asked (Refresh Library).
    let crawl_every: Int
}

/// The core's handle, shared with long operations on other threads, which
/// the core allows (see cinematheque.h).
nonisolated struct Handle: @unchecked Sendable {
    let pointer: OpaquePointer
}

/// The library, through the core's C interface.

extension ComparisonResult: @retroactive Comparable {
    public static func < (a: ComparisonResult, b: ComparisonResult) -> Bool { a.rawValue < b.rawValue }
}
