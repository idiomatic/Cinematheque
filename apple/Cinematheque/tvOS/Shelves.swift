#if os(tvOS)
import SwiftUI

/// The tab bar: Home, Movies, Series, Watchlist, and Search, each a
/// navigation stack opening titles' detail pages.
struct Shelves: View {
    enum Shelf: String, Hashable {
        case home, movies, series, watchlist, search
    }

    @Environment(Library.self) private var library
    @State private var shelf: Shelf = .home

    var body: some View {
        TabView(selection: $shelf) {
            Tab("Home", systemImage: "house", value: .home) {
                Stack { HomeView() }
            }
            Tab("Movies", systemImage: "film", value: .movies) {
                Stack { PosterGrid(tiles: library.tiles.filter { !$0.isSeries }) }
            }
            Tab("Series", systemImage: "tv", value: .series) {
                Stack { PosterGrid(tiles: Shelves.series(library.tiles)) }
            }
            Tab("Watchlist", systemImage: "star", value: .watchlist) {
                Stack { PosterGrid(tiles: Shelves.titles(library.tiles.filter { library.watchlist.contains($0.key) }), empty: "Titles you add to your watchlist show here.") }
            }
            Tab(value: .search, role: .search) {
                Stack { SearchView() }
            }
        }
        .overlay(alignment: .bottomTrailing) { Activity() }
        #if DEBUG
        .onAppear { if let tab = TVLaunch.tab { shelf = tab } }
        #endif
    }

    /// One tile per series (its first season's, which carries the series'
    /// cover if the season has none), named for the series.
    static func series(_ tiles: [Tile]) -> [Tile] {
        titles(tiles.filter(\.isSeries))
    }

    /// One tile per title: a movie's, or a series' first season's.
    static func titles(_ tiles: [Tile]) -> [Tile] {
        var seen: Set<String> = []
        return tiles.filter { seen.insert($0.key).inserted }
    }
}

/// A tab's navigation stack, opening a movie's page or a series'.
private struct Stack<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(Library.self) private var library
    @State private var path: [Tile] = []

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationDestination(for: Tile.self) { tile in
                    if tile.isSeries { SeriesView(key: tile.key) } else { MovieView(tile: tile) }
                }
        }
        #if DEBUG
        .onAppear {
            if let key = TVLaunch.select, let tile = library.tiles.first(where: { $0.key == key }) { path = [tile] }
        }
        #endif
    }
}

/// Rows of what to watch: in progress (movies partway, seasons begun), then
/// the watchlist.
private struct HomeView: View {
    @Environment(Library.self) private var library

    var body: some View {
        let tiles = library.tiles
        let going = tiles.filter { !$0.watched && $0.progress > 0 }
        let listed = Shelves.titles(tiles.filter { library.watchlist.contains($0.key) })
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 50) {
                if going.isEmpty && listed.isEmpty {
                    ContentUnavailableView("Nothing in Progress", systemImage: "play.rectangle", description: Text("What you're watching, and your watchlist, show here."))
                        .frame(maxWidth: .infinity)
                }
                if !going.isEmpty { Row(title: "Continue Watching", tiles: going) }
                if !listed.isEmpty { Row(title: "Watchlist", tiles: listed) }
            }
            .padding(.vertical, 40)
        }
    }
}

private struct Row: View {
    let title: String
    let tiles: [Tile]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title).font(.title3)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 40) {
                    ForEach(tiles) { Poster(tile: $0).frame(width: 240) }
                }
                .padding(.vertical, 30)
            }
            .scrollClipDisabled()
        }
    }
}

/// Covers in a grid, six to a row.
struct PosterGrid: View {
    let tiles: [Tile]
    var empty = "Add repositories, then refresh, on your Mac."

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 48, alignment: .top), count: 6), spacing: 60) {
                ForEach(tiles) { Poster(tile: $0) }
            }
            .padding(.vertical, 40)
        }
        .overlay {
            if tiles.isEmpty { ContentUnavailableView("Nothing Here", systemImage: "film.stack", description: Text(empty)) }
        }
    }
}

/// A cover that opens its title, with this user's progress, and its name
/// below.
struct Poster: View {
    let tile: Tile

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            NavigationLink(value: tile) {
                Color.clear
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                    .overlay { CoverImage(cover: tile.cover, thumb: tile.thumb, title: tile.name) }
                    .overlay(alignment: .topTrailing) {
                        if tile.watched {
                            Image(systemName: "checkmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.accentColor)
                                .padding(10)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if !tile.watched, tile.progress > 0 {
                            ProgressView(value: tile.progress).tint(.white).padding(12)
                        }
                    }
            }
            .buttonStyle(.card)
            Text(tile.name)
                .font(.caption)
                .lineLimit(1)
        }
    }
}

private struct SearchView: View {
    @Environment(Library.self) private var library
    @State private var text = ""

    var body: some View {
        let found = text.isEmpty ? [] : Shelves.titles(library.tiles.filter { $0.name.localizedCaseInsensitiveContains(text) })
        PosterGrid(tiles: found, empty: text.isEmpty ? "Search for a movie or series." : "No titles match “\(text)”.")
            .searchable(text: $text)
    }
}

/// What a refresh is doing, or what went wrong, in a corner.
private struct Activity: View {
    @Environment(Library.self) private var library

    var body: some View {
        if let activity = library.activity {
            HStack(spacing: 16) {
                ProgressView()
                Text(activity + "…")
            }
            .font(.caption)
            .padding(24)
        } else if let problem = library.problem {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(24)
        }
    }
}
#endif
