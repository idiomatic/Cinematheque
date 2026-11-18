#if os(tvOS)
import SwiftUI

/// The tab bar: Home, Movies, Series, Watchlist, and Search, each a
/// navigation stack opening titles' detail pages.
struct Browser: View {
    /// A tab: a shelf, or search.
    enum Tab: Hashable {
        case shelf(Shelf), search
    }

    @Environment(Library.self) private var library
    @State private var tab: Tab = .shelf(.home)

    var body: some View {
        TabView(selection: $tab) {
            ForEach(Shelf.allCases) { shelf in
                SwiftUI.Tab(shelf.title, systemImage: shelf.symbol, value: Tab.shelf(shelf)) {
                    Stack {
                        if shelf == .home {
                            HomeView()
                        } else {
                            // A page per series (its seasons are there), so a
                            // cover per title.
                            PosterGrid(tiles: shelf.tiles(in: library).oneEach, empty: shelf.empty)
                        }
                    }
                }
            }
            SwiftUI.Tab(value: Tab.search, role: .search) {
                Stack { SearchView() }
            }
        }
        .overlay(alignment: .bottomTrailing) { Activity() }
        #if DEBUG
        .onAppear {
            if let name = Launch.tab { tab = name == "search" ? .search : Shelf(rawValue: name).map(Tab.shelf) ?? tab }
        }
        #endif
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
        // Once the title has arrived (a first launch's sync brings it).
        .task(id: library.tiles.isEmpty) {
            if path.isEmpty, let key = Launch.selectedTitle, let tile = library.tiles.first(where: { $0.key == key }) { path = [tile] }
        }
        #endif
    }
}

/// Rows of what to watch: in progress (movies partway, seasons begun), then
/// the watchlist.
private struct HomeView: View {
    @Environment(Library.self) private var library

    var body: some View {
        let going = Shelf.home.tiles(in: library)
        let listed = Shelf.watchlist.tiles(in: library).oneEach
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 50) {
                if going.isEmpty && listed.isEmpty {
                    ContentUnavailableView("Nothing in Progress", systemImage: "play.rectangle", description: Text(Shelf.home.empty))
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
    var empty = Shelf.movies.empty

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
        // Every shelf's titles but Home's, which are among them.
        let found = text.isEmpty ? [] : (Shelf.movies.tiles(in: library, search: text) + Shelf.series.tiles(in: library, search: text)).oneEach
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
