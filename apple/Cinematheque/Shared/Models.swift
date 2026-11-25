import Foundation

/// A cover: a byte range of a file in a source.
nonisolated struct Cover: Codable, Hashable {
    let url: String
    let offset: Int
    let length: Int
    /// Changes when the file does.
    let stamp: String
}

/// A title's kind, as the core names it.
nonisolated enum TitleKind: String, Codable, Hashable {
    case movie, series
}

/// One tile of the grid: a movie, or a season of a series.
nonisolated struct Tile: Codable, Identifiable, Hashable {
    let key: String
    let name: String
    let year: Int?
    let kind: TitleKind
    let season: Int?
    let cover: Cover?
    /// The cover's width over its height, if the core could read it.
    let aspect: Double?
    /// This person's: every item watched; how far along (0 to 1), by running
    /// time: how many milliseconds have `elapsed` (watched items whole,
    /// those partway to their positions) of the `runtime`; and whether any
    /// item has progress.
    var watched: Bool
    var progress: Double
    var elapsed: Int
    let runtime: Int
    var started: Bool
    /// How many items it holds: a season's episodes (an episode's versions
    /// and parts counting once), a movie's versions and parts.
    let items: Int
    /// Every copy it has is on a drive that isn't there (an unavailable
    /// directory of its source's): shown dimmed.
    var unavailable = false
    /// Its title's place in each order, as the core decides them.
    let order: Order
    /// A placeholder's note (empty if none): a title not in the library
    /// yet, put on a list by name, which its file's tile takes the place of
    /// when it comes, as it's keyed alike.
    var wanted: String? = nil

    var isWanted: Bool { wanted != nil }

    /// A placeholder's tile, from its key (`t/m/<name>/<year>`, or a
    /// season's, `t/s/<name>/<year>#<season>`) and its name as typed.
    init(wanted w: UserList.Wanted) {
        let fields = Wanting(w)
        self.init(key: String(w.key.split(separator: "#", maxSplits: 1)[0]), name: w.name, year: fields.year, kind: fields.kind,
                  season: fields.season, cover: nil, aspect: nil, watched: false, progress: 0, elapsed: 0,
                  runtime: 0, started: false, items: 0, order: .init(title: .max, released: nil, added: nil, modified: nil, watched: nil),
                  wanted: w.note)
    }

    init(key: String, name: String, year: Int?, kind: TitleKind, season: Int?, cover: Cover?, aspect: Double?, watched: Bool, progress: Double,
         elapsed: Int, runtime: Int, started: Bool, items: Int, unavailable: Bool = false, order: Order, wanted: String? = nil) {
        self.key = key
        self.name = name
        self.year = year
        self.kind = kind
        self.season = season
        self.cover = cover
        self.aspect = aspect
        self.watched = watched
        self.progress = progress
        self.elapsed = elapsed
        self.runtime = runtime
        self.started = started
        self.items = items
        self.unavailable = unavailable
        self.order = order
        self.wanted = wanted
    }

    /// Places counting from what comes first in each order's usual
    /// direction (A to Z, the newest released, the latest added, the
    /// latest watched); a title with nothing to order it by has none, and
    /// goes last.
    struct Order: Codable, Hashable {
        let title: Int
        let released: Int?
        let added: Int?
        let modified: Int?
        let watched: Int?
    }

    var id: String { season.map { "\(key)#\($0)" } ?? key }
    var isSeries: Bool { kind == .series }
    /// "Season 3", "Specials" for season 0, or a dated series' season's
    /// year alone, "2026" (a season of 1000 or more, as the core reads
    /// it), as "Season 2026" read as a 2,026th.
    var seasonName: String? { season.map { $0 == 0 ? "Specials" : $0 >= 1000 ? String($0) : "Season \($0)" } }
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
        /// A movie's item's version, its parts' alike ("Standard").
        var version: String?
        /// Whether it was described from one of its files as that file is
        /// now, as the core decides; else it's described as it's shown.
        var described: Bool?
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

nonisolated struct Source: Codable, Identifiable, Hashable {
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
    /// What it is: a server's address, or a device's own folder's,
    /// port-free (`cqdevice://<its key>/<path>`).
    let url: String
    /// Where it's reached now: its `url`, or for a device's own folder,
    /// where that device says it serves (none until it has).
    let address: String?
    /// Its address if it has one, else what it is: shown, and opened.
    var reached: String { address ?? url }
    /// Its server, then its folders, as a person reads them, as the core
    /// gives them: `displayName`'s parts.
    let path: [String]
    /// Where its files' quality comes from, and the name, if named.
    let quality_from: QualityFrom
    let quality: String
    let skip: String

    /// Where a source's files' quality comes from, as the core names it:
    /// the nearest of a file's name and folders that says one (the
    /// default), one name, or a newer device's setting, which this one
    /// doesn't crawl by.
    enum QualityFrom: String, Codable, Hashable { case path, named, unknown }

    /// Its quality setting, the name with it.
    var qualitySetting: Quality {
        switch quality_from {
        case .path: .path
        case .named: .named(quality)
        case .unknown: .unknown
        }
    }

    /// A quality setting: where it comes from, a name with `named`.
    enum Quality: Hashable { case path, named(String), unknown }
    let copies: Int
    var unavailable: [Unavailable] = []
    /// A device's downloads, which no one crawls (see the core's
    /// download.zig).
    var managed = false

    /// Its server and folders, as a person reads them: "art › Movies ›
    /// 2160p".
    var displayName: String { path.joined(separator: " › ") }
}

struct Member: Codable, Identifiable, Hashable {
    let key: String
    let name: String?
    let you: Bool
    var id: String { key }
}

/// One of this person's devices that has a name.
struct Device: Codable, Identifiable, Hashable {
    let key: String
    let name: String
    let you: Bool
    /// Its model, as it recorded it ("iPhone 13 mini"), if it has.
    var model: String?
    /// What kind of device it is, as the core tells from its model; nil
    /// for one that hasn't said, or a kind newer than this build.
    var kind: Kind?
    /// When it last synced with this device, either way, if it has.
    var seen: Date?
    var id: String { key }

    /// When it was last seen, as Settings says it: "Seen 5 minutes ago",
    /// or "Not seen yet".
    var seenText: String { seenAgo.map { "Seen \($0)" } ?? "Not seen yet" }

    /// How long ago it was seen ("5 minutes ago", "just now"), if it has
    /// been.
    var seenAgo: String? {
        guard let seen else { return nil }
        guard Date.now.timeIntervalSince(seen) >= 60 else { return "just now" }
        let when = RelativeDateTimeFormatter()
        when.dateTimeStyle = .named
        return when.localizedString(for: seen, relativeTo: .now)
    }

    /// What kind of device one is, as the core names them.
    enum Kind: String, Codable, Hashable {
        case iphone, ipad, ipod, appletv, vision, macbook, imac, mac_mini, mac_studio, mac_pro, mac, pc

        /// Its SF Symbol, as Apple's own lists of devices show them.
        var symbol: String {
            switch self {
            case .iphone: "iphone"
            case .ipad: "ipad"
            case .ipod: "ipodtouch"
            case .appletv: "appletv"
            case .vision: "visionpro"
            case .macbook: "laptopcomputer"
            case .imac, .mac: "desktopcomputer"
            case .mac_mini: "macmini"
            case .mac_studio: "macstudio"
            case .mac_pro: "macpro.gen3"
            case .pc: "pc"
            }
        }
    }

    /// Its kind's symbol, or a display's for one of no kind known.
    var symbol: String { kind?.symbol ?? "display" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        name = try c.decode(String.self, forKey: .name)
        you = try c.decode(Bool.self, forKey: .you)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        // One this build doesn't know is none, not a failure to read them all.
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)).flatMap { $0.flatMap(Kind.init(rawValue:)) }
        // Milliseconds since the epoch, as the core keeps it.
        seen = try c.decodeIfPresent(Double.self, forKey: .seen).map { Date(timeIntervalSince1970: $0 / 1000) }
    }
}

/// A device found nearby, or added by address.
struct NearbyDevice: Codable, Identifiable, Hashable {
    let url: String
    let device: String?
    /// What kind of device, as one offering to be added says ("iPhone 13
    /// mini").
    let model: String?
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
    /// Its device's and person's names, if any: the device's as the core
    /// shows it (by its host's, where it advertised only a generic one, as
    /// tvOS and iOS give apps).
    var deviceName: String? { device.flatMap { $0.isEmpty ? nil : $0 } }
    var personName: String? { person.flatMap { $0.isEmpty ? nil : $0 } }
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
    /// The source's URL, as added: port-free (`cqdevice://`), or as
    /// builds before wrote it (by its port) until it's moved there.
    var url: String
    var id: String { prefix }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

struct Status: Codable, Equatable {
    let person: String
    /// This device's key, for its own folders' addresses (`cqdevice://`).
    let device: String
    /// Acting as the person of another of the person's devices.
    let paired: Bool
    let library: String?
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

nonisolated extension ComparisonResult: @retroactive Comparable {
    public static func < (a: ComparisonResult, b: ComparisonResult) -> Bool { a.rawValue < b.rawValue }
}

nonisolated extension URL {
    /// A web address (http or https), from text other devices may have
    /// written, else nil: such text could name a file, a share, or another
    /// app's scheme, which opening or loading it would act on.
    init?(web string: String) {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host() != nil else { return nil }
        self = url
    }

    /// `path` within this folder, or nil if it would climb out of it, as a
    /// path another device recorded might (`../`).
    func within(_ path: String) -> URL? {
        guard !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        return appending(path: path)
    }
}

/// One of this person's lists (a Watchlist, Favorites): movies' title keys
/// and seasons' tiles (`<title key>#<season>`).
nonisolated struct UserList: Codable, Identifiable, Hashable {
    /// Its ID; another member's, `<owner>/<id>`.
    let id: String
    let name: String
    /// Its owner's person key, and name, if another member's is set.
    var owner: String?
    var ownerName: String?
    /// Only its owner changes it; every member sees it, if shared.
    var mine: Bool?
    var mode: Mode?
    let titles: [String]
    /// The placeholders among its titles: not in the library when put on
    /// it, by name, keyed as their files will be.
    var wanted: [Wanted]?

    struct Wanted: Codable, Hashable {
        let key: String
        let name: String
        let note: String
    }

    var isMine: Bool { mine ?? true }
    var isShared: Bool { mode == .shared }

    /// Who sees it: its owner alone, or every member.
    enum Mode: String, Codable, Hashable { case `private`, shared }

    /// Its name as shown: another member's, as theirs, if they're named
    /// (a shared list's marked by a symbol of people, wherever it's named).
    var shownName: String {
        if isMine { return name }
        if let owner = ownerName, !owner.isEmpty { return "\(owner)’s \(name)" }
        return name
    }

    /// The mark of a shared list, this person's or another's.
    static let sharedSymbol = "person.2"
}

/// A placeholder's fields, as it's put on a list or changed: a movie, or a
/// series' season, by its name and year as its file will be named, and a
/// note (as an article's address).
nonisolated struct Wanting: Equatable {
    var kind: TitleKind = .movie
    var name = ""
    var year: Int?
    /// A series' season; the first if none.
    var season: Int?
    var note = ""

    init() {}

    /// A placeholder's, from its key (`t/m/<name>/<year>`, or a season's,
    /// `t/s/<name>/<year>#<season>`) and its name as typed.
    init(_ w: UserList.Wanted) {
        let parts = w.key.split(separator: "#", maxSplits: 1)
        let key = String(parts[0])
        kind = key.hasPrefix("t/s/") ? .series : .movie
        name = w.name
        year = key.split(separator: "/").last.flatMap { Int($0) }
        season = parts.count > 1 ? Int(parts[1]) : nil
        note = w.note
    }

    /// Whether it can be put on a list: a name, at least.
    var isComplete: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }
}
