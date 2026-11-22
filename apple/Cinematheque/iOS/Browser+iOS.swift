#if os(iOS)
import SwiftUI

/// The iPhone's tab bar, within thumbs' reach: Home, Movies, Series, Lists,
/// and Search, each a navigation stack opening titles' pages: a movie's, or
/// a season's; a series' tile, its seasons first. Settings is from Home's
/// corner. A prototype: browsing, the title pages, and playing.
struct Browser: View {
    @Environment(Library.self) private var library
    @State private var tab = "home"

    var body: some View {
        TabView(selection: $tab) {
            Tab("Home", systemImage: Shelf.home.symbol, value: "home") {
                Stack { HomeView() }
            }
            Tab("Movies", systemImage: Shelf.movies.symbol, value: "movies") {
                Stack { ShelfGrid(shelf: .movies) }
            }
            Tab("Series", systemImage: Shelf.series.symbol, value: "series") {
                Stack { ShelfGrid(shelf: .series) }
            }
            Tab("Lists", systemImage: Shelf.lists.symbol, value: "lists") {
                Stack { ListsView() }
            }
            Tab(value: "search", role: .search) {
                Stack { SearchView() }
            }
        }
        #if DEBUG
        .onAppear { if let name = Launch.tab { tab = name } }
        #endif
    }
}

/// A series' seasons, as a page: what a series' tile opens.
struct SeasonsOf: Hashable {
    let key: String
}

/// A list's whole page: what See All opens.
struct ListOf: Hashable {
    let id: String
}

/// A tab's navigation stack, opening a movie's page, a season's, a
/// series' seasons, or a list's page.
private struct Stack<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(Library.self) private var library
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationDestination(for: Tile.self) { tile in
                    TitlePage(tile: tile)
                }
                .navigationDestination(for: SeasonsOf.self) { SeasonsPage(key: $0.key) }
                .navigationDestination(for: ListOf.self) { ListPage(id: $0.id) }
        }
        #if DEBUG
        // A season's page, or a series' seasons, once the title's there.
        .task(id: library.tiles.isEmpty) {
            guard path.isEmpty, let id = Launch.selection else { return }
            if let tile = library.tiles.first(where: { $0.id == id }) {
                path = NavigationPath([tile])
            } else if let key = Launch.selectedTitle, library.tiles.contains(where: { $0.key == key }) {
                path = NavigationPath([SeasonsOf(key: key)])
            }
        }
        #endif
    }
}

/// Rows of what to watch: Continue Watching, then each list, each with
/// See All, as iOS's own apps' rows have; Settings in its corner.
private struct HomeView: View {
    @Environment(Library.self) private var library
    @State private var settings = false

    var body: some View {
        let going = Shelf.home.tiles(in: library)
        let lists = library.lists.map { ($0, Shelf.list($0.id).tiles(in: library)) }.filter { !$0.1.isEmpty }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if !going.isEmpty { Carousel(title: "Continue Watching", tiles: going) }
                ForEach(lists, id: \.0.id) { list, tiles in
                    Carousel(title: list.shownName, tiles: tiles, list: list.id, shared: list.isShared)
                }
            }
            .padding(.vertical)
        }
        .overlay {
            if going.isEmpty && lists.isEmpty {
                ContentUnavailableView("Nothing in Progress", systemImage: "play.rectangle", description: Text(Shelf.home.empty))
            }
        }
        .navigationTitle("Home")
        .toolbar {
            Button("Settings", systemImage: "gearshape") { settings = true }
        }
        .sheet(isPresented: $settings) { SettingsSheet() }
    }
}

/// A row of covers, scrolling sideways: every cover one height, each its
/// own width by its shape (a carousel isn't a grid, so its gaps never line
/// up across rows anyway); a list's with See All, how many it holds.
private struct Carousel: View {
    let title: String
    let tiles: [Tile]
    var list: String? = nil
    var shared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if shared {
                    Label(title, systemImage: UserList.sharedSymbol)
                } else {
                    Text(title)
                }
                Spacer()
                if let list {
                    NavigationLink(value: ListOf(id: list)) {
                        Text("See All \(tiles.count)")
                    }
                    .font(.subheadline)
                }
            }
            .font(.title3.weight(.semibold))
            .padding(.horizontal)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(tiles) { tile in
                        NavigationLink(value: tile) {
                            VStack(alignment: .leading, spacing: 4) {
                                TileCover(tile: tile)
                                    .frame(height: 150)
                                PosterName(tile: tile)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
            .scrollIndicators(.hidden)
        }
    }
}

/// A cover in its own shape, with its marks and progress.
struct TileCover: View {
    let tile: Tile
    @Environment(Library.self) private var library

    var body: some View {
        CoverImage(cover: tile.cover, thumb: tile.thumb, title: tile.name, shaped: true)
            .opacity(tile.unavailable || tile.isWanted ? 0.4 : 1)
            .overlay(alignment: .top) { CoverMarks(listed: library.isListed(tile), watched: tile.watched, padding: 6) }
            .overlay(alignment: .bottom) {
                if !tile.watched, tile.progress > 0 {
                    ProgressView(value: tile.progress).tint(.white).padding(8)
                }
            }
            .clipShape(.rect(cornerRadius: 8))
    }
}

/// A title's name under its cover, and a season's under that.
private struct PosterName: View {
    let tile: Tile
    /// Not for a series' tile, which stands for every season.
    var showsSeason = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tile.name).font(.caption).lineLimit(1)
            if let season = tile.isWanted ? "Not in library" : showsSeason ? tile.seasonName : nil {
                Text(season).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// A shelf's covers in a grid: Movies', or Series', a cover per series.
private struct ShelfGrid: View {
    let shelf: Shelf
    @Environment(Library.self) private var library

    var body: some View {
        let tiles = shelf.tiles(in: library)
        CoverGrid(tiles: shelf == .series ? library.perTitle(tiles) : tiles, series: shelf == .series, empty: shelf.empty)
            .navigationTitle(shelf.title)
    }
}

/// Covers in a grid, three to a row on an iPhone: every cell the column's
/// width, 2:3 for movies, a season's cover fit whole at its foot.
struct CoverGrid: View {
    let tiles: [Tile]
    /// Whether a series' tiles stand for the whole series (opening its
    /// seasons), not a season.
    var series = false
    var empty = Shelf.movies.empty

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12, alignment: .top)], spacing: 16) {
                ForEach(tiles) { tile in
                    NavigationLink(value: series && tile.isSeries ? AnyHashable(SeasonsOf(key: tile.key)) : AnyHashable(tile)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Color.clear
                                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                                .overlay(alignment: .bottom) { TileCover(tile: tile) }
                            PosterName(tile: tile, showsSeason: !series)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .overlay {
            if tiles.isEmpty { ContentUnavailableView("Nothing Here", systemImage: "film.stack", description: Text(empty)) }
        }
    }
}

/// A series' seasons, a page of their own, as the Apple TV's: square
/// cells, a portrait cover fit whole in its square.
private struct SeasonsPage: View {
    let key: String
    @Environment(Library.self) private var library

    var body: some View {
        let seasons = Library.seasons(of: key, in: library.tiles)
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12, alignment: .top)], spacing: 16) {
                ForEach(seasons) { tile in
                    NavigationLink(value: tile) {
                        VStack(alignment: .leading, spacing: 4) {
                            Color.clear
                                .aspectRatio(1, contentMode: .fit)
                                .overlay { TileCover(tile: tile) }
                            Text(tile.seasonName ?? "").font(.caption).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .navigationTitle(seasons.first?.name ?? "")
    }
}

/// Each list, a row apiece, then New List.
private struct ListsView: View {
    @Environment(Library.self) private var library

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                ForEach(library.lists) { list in
                    Carousel(title: list.shownName, tiles: Shelf.list(list.id).tiles(in: library), list: list.id, shared: list.isShared)
                }
            }
            .padding(.vertical)
        }
        .overlay {
            if library.lists.isEmpty {
                ContentUnavailableView("No Lists", systemImage: "star", description: Text("Make a list to keep titles in, as a watchlist or favorites."))
            }
        }
        .navigationTitle("Lists")
        .toolbar {
            Button("New List", systemImage: "plus") { library.listPrompt = .init(kind: .create(adding: [])) }
        }
    }
}

/// One list, whole, as a grid; renaming, sharing, and deleting it from its
/// navigation bar's menu, if it's this person's own.
private struct ListPage: View {
    let id: String
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let shelf = Shelf.list(id)
        let list = library.lists.first { $0.id == id }
        CoverGrid(tiles: shelf.tiles(in: library), empty: shelf.empty)
            .navigationTitle(shelf.name(in: library))
            .toolbar {
                if let list, list.isMine {
                    Menu("List", systemImage: "ellipsis.circle") {
                        Button("Rename…", systemImage: "pencil") { library.listPrompt = .init(kind: .rename(list)) }
                        if list.isShared {
                            Button("Stop Sharing", systemImage: "person.2.slash") { library.shareList(list.id, false) }
                        } else {
                            Button("Share…", systemImage: "person.2") { library.sharingList = list }
                        }
                        Button("Delete List…", systemImage: "trash", role: .destructive) { library.deletingList = list }
                    }
                }
            }
            .onChange(of: list == nil) { _, gone in
                if gone { dismiss() }
            }
    }
}

/// Search, on its tab: every title whose name has what's typed.
private struct SearchView: View {
    @Environment(Library.self) private var library
    @State private var text = ""

    var body: some View {
        CoverGrid(tiles: text.isEmpty ? [] : library.perTitle(Shelf.movies.tiles(in: library, search: text) + Shelf.series.tiles(in: library, search: text)), series: true, empty: text.isEmpty ? "Search by a title's name." : "Nothing has that name.")
            .navigationTitle("Search")
            .searchable(text: $text)
    }
}

/// Settings, from Home's corner: for now, refreshing the library.
private struct SettingsSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button("Refresh Library") { Task { await library.refresh() } }
                        .disabled(library.activity != nil)
                    if let activity = library.activity { Text(activity + "…").foregroundStyle(.secondary) }
                } footer: {
                    Text("Looks for new videos on every source, after catching up with your other devices.")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                Button("Done") { dismiss() }
            }
        }
    }
}
#endif
