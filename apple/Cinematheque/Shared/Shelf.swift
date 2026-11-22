import Foundation

/// The library's shelves, on every platform: what each holds, how it's
/// searched, and how it's counted. Each platform shows them its own way
/// (the Mac in a sidebar, the Apple TV from a home page).
enum Shelf: Identifiable, Hashable, RawRepresentable {
    /// Watching (`inProgress`, as it's stored) is the Mac's Home (which
    /// shows what's in progress elsewhere); Downloaded, what this Mac keeps,
    /// is the Mac's only too.
    /// Lists is every list, the Apple TV's section; the Mac shows each
    /// list on its own, by ID.
    case home, movies, series, lists, inProgress, watched, downloaded
    case list(String)

    /// Every shelf but a list's.
    static let allCases: [Shelf] = [.home, .movies, .series, .lists, .inProgress, .watched, .downloaded]

    var id: Self { self }

    /// As kept (`list:<id>` for a list's).
    var rawValue: String {
        switch self {
        case .home: "home"
        case .movies: "movies"
        case .series: "series"
        case .lists: "lists"
        case .inProgress: "inProgress"
        case .watched: "watched"
        case .downloaded: "downloaded"
        case .list(let id): "list:\(id)"
        }
    }

    init?(rawValue: String) {
        if rawValue.hasPrefix("list:") {
            self = .list(String(rawValue.dropFirst("list:".count)))
        } else if let shelf = Self.allCases.first(where: { $0.rawValue == rawValue }) {
            self = shelf
        } else {
            return nil
        }
    }

    /// Its name; a list's, the list's own (`name(in:)`).
    var title: String {
        switch self {
        case .home: "Home"
        case .movies: "Movies"
        case .series: "Series"
        case .lists: "Lists"
        case .inProgress: "Watching"
        case .watched: "Watched"
        case .downloaded: "Downloaded"
        case .list: "List"
        }
    }

    @MainActor func name(in library: Library) -> String {
        guard case .list(let id) = self else { return title }
        return library.lists.first { $0.id == id }?.shownName ?? title
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .movies: "film"
        // Filled when chosen (a tab's), a screen with a play mark, not a
        // blank one.
        case .series: "play.tv"
        case .lists: "star"
        case .list: "list.star"
        case .inProgress: "play.circle"
        case .watched: "checkmark.circle"
        case .downloaded: "arrow.down.circle"
        }
    }

    /// Its tiles, a series' by season, whose names hold `search`, if any,
    /// in `order` (else its own): Home's are those in progress (movies
    /// partway, seasons begun), as are the Mac's In Progress; Watched's,
    /// what's watched through.
    @MainActor func tiles(in library: Library, search: String = "", order: ShelfOrder? = nil) -> [Tile] {
        #if os(macOS)
        let downloaded = self == .downloaded ? library.downloadedTiles : []
        #else
        let downloaded: Set<String> = []
        #endif
        // A list's placeholders not in the library yet, as tiles of their
        // own (one that's come is its file's tile, keyed alike).
        let wanted: [UserList.Wanted] = switch self {
        case .lists: library.lists.flatMap { $0.wanted ?? [] }
        case .list(let id): library.lists.first { $0.id == id }?.wanted ?? []
        default: []
        }
        let present = wanted.isEmpty ? [] : Set(library.tiles.map(\.id))
        let placeholders = wanted.filter { !present.contains($0.key) }.map(Tile.init(wanted:))
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
        return (library.tiles.filter { tile in
            let on = switch self {
            case .home, .inProgress: !tile.watched && tile.started
            case .movies: !tile.isSeries
            case .series: tile.isSeries
            case .lists: library.onAnyList.contains(tile.id)
            case .list(let id): library.lists.first { $0.id == id }?.titles.contains(tile.id) ?? false
            case .watched: tile.watched
            case .downloaded: downloaded.contains(tile.id)
            }
            return on && (search.isEmpty || tile.name.localizedCaseInsensitiveContains(search))
        } + placeholders)
        .ordered(order ?? defaultOrder)
    }

    /// What it's sorted by until a person chooses: what's being watched,
    /// the latest first; else titles, A to Z.
    var defaultOrder: ShelfOrder {
        switch self {
        case .home, .inProgress, .watched: .init(by: .watched)
        case .movies, .series, .lists, .list, .downloaded: .init(by: .title)
        }
    }

    /// "4,000 movies", "300 series, 1,200 seasons, 15,000 episodes", or with a search, "12
    /// of 4,000 movies match “zoo”".
    @MainActor func counts(in library: Library, search: String = "") -> String {
        let all = tiles(in: library)
        let titles = Set(all.map(\.key)).count
        let noun = switch self {
        case .movies: titles == 1 ? "movie" : "movies"
        case .series: "series"
        case .home, .inProgress, .lists, .list, .watched, .downloaded: titles == 1 ? "title" : "titles"
        }
        if !search.isEmpty {
            let matching = Set(tiles(in: library, search: search).map(\.key)).count
            return "\(matching.formatted()) of \(titles.formatted()) \(noun) match “\(search)”"
        }
        if self == .series {
            let episodes = all.reduce(0) { $0 + $1.items }
            return "\(titles.formatted()) series, \(all.count.formatted()) \(all.count == 1 ? "season" : "seasons"), \(episodes.formatted()) \(episodes == 1 ? "episode" : "episodes")"
        }
        return "\(titles.formatted()) \(noun)"
    }

    /// What an empty shelf says.
    var empty: String {
        switch self {
        case .home, .inProgress: "What you're watching shows here."
        case .watched: "What you've watched shows here."
        case .lists: "Titles you add to your lists show here."
        case .list: "Titles you add to this list show here."
        case .downloaded: "What you download, to watch without a network, shows here."
        case .movies, .series: "Add sources of videos in Cinematheque on your Mac."
        }
    }
}

extension Library {
    /// One tile per title, as the Apple TV shows them: a series' standing
    /// for the whole series, with its progress over every season's
    /// running time, and watched once every season is.
    func perTitle(_ tiles: [Tile]) -> [Tile] {
        // Grouped once, as shelves redraw with each reload.
        let bySeries = tiles.contains(where: \.isSeries) ? Dictionary(grouping: self.tiles.filter(\.isSeries), by: \.key) : [:]
        return tiles.oneEach.map { tile in
            guard tile.isSeries else { return tile }
            let seasons = bySeries[tile.key] ?? []
            let elapsed = seasons.reduce(0) { $0 + $1.elapsed }
            let runtime = seasons.reduce(0) { $0 + $1.runtime }
            return Tile(
                key: tile.key, name: tile.name, year: tile.year, kind: tile.kind, season: tile.season,
                cover: tile.cover, thumb: tile.thumb,
                watched: seasons.allSatisfy(\.watched),
                progress: runtime > 0 ? Double(elapsed) / Double(runtime) : 0,
                elapsed: elapsed, runtime: runtime,
                started: seasons.contains(where: \.started),
                items: seasons.reduce(0) { $0 + $1.items },
                unavailable: seasons.allSatisfy(\.unavailable),
                order: tile.order
            )
        }
    }

    /// A series' seasons in order, specials last.
    static func seasons(of key: String, in tiles: [Tile]) -> [Tile] {
        let seasons = tiles.filter { $0.key == key && $0.season != nil }.sorted { ($0.season ?? 0) < ($1.season ?? 0) }
        return seasons.filter { $0.season != 0 } + seasons.filter { $0.season == 0 }
    }

    /// What a series' seasons come to, in order (as `seasons` gives them):
    /// "3 seasons"; a dated series' years, "2024–2026", or "2026"; of one
    /// season but the first, its name; nothing for a first alone (a
    /// miniseries, or one cut short).
    static func seasonsCaption(_ seasons: [Tile]) -> String {
        let numbered = seasons.compactMap(\.season).filter { $0 != 0 }
        if let first = numbered.first, let last = numbered.last, first >= 1000 {
            return first == last ? String(first) : "\(first)–\(last)"
        }
        guard seasons.count == 1 else { return "\(seasons.count) seasons" }
        return seasons[0].season == 1 ? "" : seasons[0].seasonName ?? ""
    }

    /// The season to start on: the first not watched through, else the
    /// first.
    static func nextSeason(_ seasons: [Tile]) -> Tile? {
        seasons.first { !$0.watched } ?? seasons.first
    }

    /// Whether a tile is on a list (`list`'s, else any); with
    /// `anySeason`, a series' tile standing for the whole series is if any
    /// of its seasons is.
    func isListed(_ tile: Tile, on list: UserList? = nil, anySeason: Bool = false) -> Bool {
        let titles = list.map { Set($0.titles) } ?? listed
        if titles.contains(tile.id) { return true }
        guard anySeason, tile.isSeries else { return false }
        return titles.contains { $0.hasPrefix(tile.key + "#") }
    }
}

/// What a shelf is sorted by, and which way: `reversed` turns the order's
/// usual direction around (Z to A, the oldest first).
struct ShelfOrder: Codable, Hashable {
    var by: By
    var reversed = false

    enum By: String, Codable, CaseIterable, Identifiable {
        case title, released, added, modified, watched

        var id: Self { self }

        var name: String {
            switch self {
            case .title: "Title"
            case .released: "Release Date"
            case .added: "Date Added"
            case .modified: "Date Modified"
            case .watched: "Date Watched"
            }
        }

        /// The usual direction's name, then the other's.
        var directions: (String, String) {
            self == .title ? ("A to Z", "Z to A") : ("Newest First", "Oldest First")
        }
    }

    /// A tile's place, if it has one in this order.
    func place(_ tile: Tile) -> Int? {
        switch by {
        case .title: tile.order.title
        case .released: tile.order.released
        case .added: tile.order.added
        case .modified: tile.order.modified
        case .watched: tile.order.watched
        }
    }
}

extension Array where Element == Tile {
    /// In `order`, a series' seasons together, by number; those with no
    /// place in it last, by title.
    func ordered(_ order: ShelfOrder) -> [Tile] {
        sorted { a, b in
            switch (order.place(a), order.place(b)) {
            case let (x?, y?) where x != y: order.reversed ? x > y : x < y
            case (_?, nil): true
            case (nil, _?): false
            default: (a.order.title, a.season ?? 0) < (b.order.title, b.season ?? 0)
            }
        }
    }

    /// One tile per title: a movie's, or a series' first season's (which
    /// carries the series' cover if the season has none).
    var oneEach: [Tile] {
        var seen: Set<String> = []
        return filter { seen.insert($0.key).inserted }
    }
}
