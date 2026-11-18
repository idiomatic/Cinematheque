import Foundation

/// The library's shelves, on every platform: what each holds, how it's
/// searched, and how it's counted. Each platform shows them its own way
/// (the Mac in a sidebar, the Apple TV in a tab bar).
enum Shelf: String, CaseIterable, Identifiable, Hashable {
    case home, movies, series, watchlist, played

    var id: Self { self }

    var title: String {
        switch self {
        case .home: "Home"
        case .movies: "Movies"
        case .series: "Series"
        case .watchlist: "Watchlist"
        case .played: "Played"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .movies: "film"
        case .series: "tv"
        case .watchlist: "star"
        case .played: "play.circle"
        }
    }

    /// Its tiles, a series' by season, whose names hold `search`, if any:
    /// Home's are those in progress (movies partway, seasons begun);
    /// Played's, a smart folder, everything with a playhead, in progress or
    /// watched.
    @MainActor func tiles(in library: Library, search: String = "") -> [Tile] {
        library.tiles.filter { tile in
            let on = switch self {
            case .home: !tile.watched && tile.started
            case .movies: !tile.isSeries
            case .series: tile.isSeries
            case .watchlist: library.watchlist.contains(tile.key)
            case .played: tile.played
            }
            return on && (search.isEmpty || tile.name.localizedCaseInsensitiveContains(search))
        }
    }

    /// "4,000 movies", "312 series, 1,212 seasons", or with a search, "12
    /// of 4,000 movies match “zoo”".
    @MainActor func counts(in library: Library, search: String = "") -> String {
        let all = tiles(in: library)
        let titles = Set(all.map(\.key)).count
        let noun = switch self {
        case .home: titles == 1 ? "title in progress" : "titles in progress"
        case .movies: titles == 1 ? "movie" : "movies"
        case .series: "series"
        case .watchlist, .played: titles == 1 ? "title" : "titles"
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
        case .home: "What you're watching shows here."
        case .watchlist: "Titles you add to your watchlist show here."
        case .played: "What you've started or watched shows here."
        case .movies, .series: "Add sources of videos in Cinematheque on your Mac."
        }
    }
}

extension Tile {
    /// On the Played shelf: with a playhead, in progress or watched.
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
