import Foundation

/// The library's shelves, on every platform: what each holds, how it's
/// searched, and how it's counted. Each platform shows them its own way
/// (the Mac in a sidebar, the Apple TV in a tab bar).
enum Shelf: String, CaseIterable, Identifiable, Hashable {
    /// In Progress and Watched are the Mac's Played, split (it has no
    /// Home); Downloaded, what this Mac keeps, is the Mac's only too.
    case home, movies, series, watchlist, played, inProgress, watched, downloaded

    /// The Mac's only.
    static let macOnly: Set<Shelf> = [.inProgress, .watched, .downloaded]

    var id: Self { self }

    var title: String {
        switch self {
        case .home: "Home"
        case .movies: "Movies"
        case .series: "Series"
        case .watchlist: "Watchlist"
        case .played: "Played"
        case .inProgress: "In Progress"
        case .watched: "Watched"
        case .downloaded: "Downloaded"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .movies: "film"
        case .series: "tv"
        case .watchlist: "star"
        case .played: "play.circle"
        case .inProgress: "play.circle"
        case .watched: "checkmark.circle"
        case .downloaded: "arrow.down.circle"
        }
    }

    /// Its tiles, a series' by season, whose names hold `search`, if any:
    /// Home's are those in progress (movies partway, seasons begun);
    /// Played's, a smart folder, everything with progress, in progress or
    /// watched; the Mac's In Progress, Home's, and its Watched, what's
    /// watched through, and any with a download watched since (its mark
    /// saying whether it waits for its space to be needed or is the only
    /// copy).
    @MainActor func tiles(in library: Library, search: String = "") -> [Tile] {
        #if os(macOS)
        let downloaded = self == .downloaded ? library.downloadedTiles : []
        let watchedDownloads = self == .watched ? library.watchedTiles : [:]
        #else
        let downloaded: Set<String> = []
        let watchedDownloads: [String: Bool] = [:]
        #endif
        return library.tiles.filter { tile in
            let on = switch self {
            case .home, .inProgress: !tile.watched && tile.started
            case .movies: !tile.isSeries
            case .series: tile.isSeries
            case .watchlist: library.watchlist.contains(tile.id)
            case .played: tile.played
            case .watched: tile.watched || watchedDownloads[tile.id] != nil
            case .downloaded: downloaded.contains(tile.id)
            }
            return on && (search.isEmpty || tile.name.localizedCaseInsensitiveContains(search))
        }
    }

    /// "4,000 movies", "300 series, 1,200 seasons", or with a search, "12
    /// of 4,000 movies match “zoo”".
    @MainActor func counts(in library: Library, search: String = "") -> String {
        let all = tiles(in: library)
        let titles = Set(all.map(\.key)).count
        let noun = switch self {
        case .home, .inProgress: titles == 1 ? "title in progress" : "titles in progress"
        case .movies: titles == 1 ? "movie" : "movies"
        case .series: "series"
        case .watchlist, .played, .watched, .downloaded: titles == 1 ? "title" : "titles"
        }
        if !search.isEmpty {
            let matching = Set(tiles(in: library, search: search).map(\.key)).count
            return "\(matching.formatted()) of \(titles.formatted()) \(noun) match “\(search)”"
        }
        if self == .series { return "\(titles.formatted()) series, \(all.count.formatted()) seasons" }
        return "\(titles.formatted()) \(noun)"
    }

    /// What an empty shelf says.
    var empty: String {
        switch self {
        case .home, .inProgress: "What you're watching shows here."
        case .watched: "What you've watched shows here, and downloads you've watched: those another source has, until their space is needed; those that are the only copy, until you delete or keep them."
        case .watchlist: "Titles you add to your watchlist show here."
        case .played: "What you've started or watched shows here."
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
        tiles.oneEach.map { tile in
            guard tile.isSeries else { return tile }
            let seasons = self.tiles.filter { $0.key == tile.key }
            let elapsed = seasons.reduce(0) { $0 + $1.elapsed }
            let runtime = seasons.reduce(0) { $0 + $1.runtime }
            return Tile(
                key: tile.key, name: tile.name, year: tile.year, kind: tile.kind, season: tile.season,
                cover: tile.cover, thumb: tile.thumb,
                watched: seasons.allSatisfy(\.watched),
                progress: runtime > 0 ? Double(elapsed) / Double(runtime) : 0,
                elapsed: elapsed, runtime: runtime,
                started: seasons.contains(where: \.started),
                absent: seasons.allSatisfy(\.absent)
            )
        }
    }

    /// Whether a tile is on the watchlist; with `anySeason`, a series'
    /// tile standing for the whole series is if any of its seasons is.
    func isListed(_ tile: Tile, anySeason: Bool = false) -> Bool {
        if watchlist.contains(tile.id) { return true }
        guard anySeason, tile.isSeries else { return false }
        return watchlist.contains { $0.hasPrefix(tile.key + "#") }
    }
}

extension Tile {
    /// On the Played shelf: with progress, in progress or watched.
    var played: Bool { started }
}

extension Array where Element == Tile {
    /// One tile per title: a movie's, or a series' first season's (which
    /// carries the series' cover if the season has none).
    var oneEach: [Tile] {
        var seen: Set<String> = []
        return filter { seen.insert($0.key).inserted }
    }
}
