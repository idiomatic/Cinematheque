#if os(iOS)
import SwiftUI

/// The iPhone's tab bar, within thumbs' reach: Home, Movies, Series, Lists,
/// and Search, each a navigation stack opening titles' pages: a movie's, or
/// a season's; a series' tile, its seasons first. Settings is from Home's
/// corner (see Settings+iOS.swift).
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
        // Settings is Home's sheet, not a tab.
        .onAppear { if let name = Launch.tab, name != "settings" { tab = name } }
        #endif
    }
}

/// A series' seasons, as a page: what a series' tile opens.
struct SeasonsOf: Hashable {
    let key: String
}

/// A tile's link: to `seasons`, a series' seasons, if given, else its own
/// page. Each a link of its value's own type, as the stack finds a
/// destination by it (an `AnyHashable` value, finding none, went nowhere).
private struct TileLink<Label: View>: View {
    let tile: Tile
    let seasons: SeasonsOf?
    @ViewBuilder let label: Label

    var body: some View {
        if let seasons {
            NavigationLink(value: seasons) { label }
        } else {
            NavigationLink(value: tile) { label }
        }
    }
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
            // The first tab to find it opens it, not every tab as it's first
            // shown.
            if let tile = library.tiles.first(where: { $0.id == id }) {
                if Launch.takeSelection() { path = NavigationPath([tile]) }
            } else if let key = Launch.selectedTitle, library.tiles.contains(where: { $0.key == key }) {
                if Launch.takeSelection() { path = NavigationPath([SeasonsOf(key: key)]) }
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
        let rows = library.homeRows
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                ForEach(rows) { Carousel(title: $0.title, tiles: $0.tiles, list: $0.list?.id, shared: $0.list?.isShared ?? false) }
            }
            .padding(.vertical)
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView("Nothing in Progress", systemImage: "play.rectangle", description: Text(Shelf.home.empty))
            }
        }
        .navigationTitle("Home")
        .toolbar {
            Button("Settings", systemImage: "gearshape") { settings = true }
        }
        .sheet(isPresented: $settings) { SettingsSheet() }
        #if DEBUG
        .onAppear { if Launch.tab == "settings" { settings = true } }
        #endif
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
                            UnderCover {
                                TileCover(tile: tile)
                                    .frame(height: 150)
                                PosterName(tile: tile, reservesLines: true)
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

/// A cover in its own shape, its progress a translucent bar along its foot
/// (`CoverProgress`), its marks under it, at its name's line's end
/// (`PosterName`), as on every platform.
struct TileCover: View {
    let tile: Tile

    var body: some View {
        CoverImage(cover: tile.cover, aspect: tile.aspect, title: tile.name, shaped: true)
            .opacity(tile.unavailable || tile.isWanted ? 0.4 : 1)
            .overlay(alignment: .bottom) { CoverProgress(tile: tile) }
            .clipShape(.rect(cornerRadius: 8))
    }
}

/// A title's name under its cover (or `title` in its place), up to two
/// lines, its marks (on a list, watched) at the line's end, so name and
/// marks span the cover's width; and a season's name under that.
private struct PosterName: View {
    let tile: Tile
    /// What it's called, if not its title's name (a season, among its
    /// series' seasons).
    var title: String? = nil
    /// Not for a series' tile, which stands for every season.
    var showsSeason = true
    /// Whether it keeps room for two lines of name and a season's line,
    /// whatever it shows, as in a carousel, whose lazy stack takes its
    /// height from the tiles first laid out, cutting taller ones after.
    var reservesLines = false
    @Environment(Library.self) private var library

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title ?? tile.name)
                    .lineLimit(2, reservesSpace: reservesLines)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                TileMarks(listed: library.isListed(tile), watched: tile.watched)
            }
            .font(.caption)
            if let season = tile.isWanted ? "Not in library" : showsSeason ? tile.seasonName : nil {
                Text(season).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            } else if reservesLines {
                Text(verbatim: " ").font(.caption2).accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A shelf's covers in a grid: Movies', or Series', a cover per series.
private struct ShelfGrid: View {
    let shelf: Shelf
    @Environment(Library.self) private var library

    var body: some View {
        let tiles = shelf.tiles(in: library)
        Group {
            if shelf == .series {
                JustifiedGrid(tiles: library.perTitle(tiles), empty: shelf.empty)
            } else {
                CoverGrid(tiles: tiles, empty: shelf.empty)
            }
        }
        .navigationTitle(shelf.title)
    }
}

/// A series' covers in rows, each cover its own shape at one height, as
/// many to a row as fit, wrapping like words; each full row scaled a little
/// to fill the width exactly (a justified layout, as photo libraries' grids
/// are), so a square cover beside portrait ones wastes no space and tops,
/// bottoms, and names all line up along a row. Shapes come from covers'
/// placeholders, known before the covers load, so rows don't jump.
private struct JustifiedGrid: View {
    let tiles: [Tile]
    var empty = Shelf.series.empty
    @State private var width: CGFloat = 0

    /// A row's height before it's scaled to fill, and the gaps.
    private static let height: CGFloat = 150
    private static let spacing: CGFloat = 12

    /// A row: its tiles, each with its shape (width over height), and the
    /// height they take.
    private struct Row: Identifiable {
        let tiles: [(tile: Tile, shape: CGFloat)]
        let height: CGFloat
        var id: String { tiles.first?.tile.id ?? "" }
    }

    /// Rows for `width`: tiles added while they fit at the usual height,
    /// then the row scaled to fill; the last, if not full, left as it is.
    private static func rows(_ tiles: [Tile], width: CGFloat) -> [Row] {
        guard width > 0 else { return [] }
        var rows: [Row] = []
        var row: [(tile: Tile, shape: CGFloat)] = []
        func widthAt(_ h: CGFloat) -> CGFloat { row.reduce(0) { $0 + $1.shape * h } + spacing * CGFloat(max(row.count - 1, 0)) }
        for tile in tiles {
            row.append((tile, CoverImage.shape(aspect: tile.aspect)))
            if widthAt(height) >= width {
                let gaps = spacing * CGFloat(row.count - 1)
                rows.append(Row(tiles: row, height: (width - gaps) / row.reduce(0) { $0 + $1.shape }))
                row = []
            }
        }
        if !row.isEmpty { rows.append(Row(tiles: row, height: height)) }
        return rows
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(Self.rows(tiles, width: width)) { row in
                    HStack(alignment: .top, spacing: Self.spacing) {
                        ForEach(row.tiles, id: \.tile.id) { item in
                            TileLink(tile: item.tile, seasons: item.tile.isSeries ? SeasonsOf(key: item.tile.key) : nil) {
                                UnderCover {
                                    TileCover(tile: item.tile)
                                        .frame(width: item.shape * row.height, height: row.height)
                                    PosterName(tile: item.tile, showsSeason: false)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .padding()
        }
        .nothingHere(tiles, empty)
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
                    TileLink(tile: tile, seasons: series && tile.isSeries ? SeasonsOf(key: tile.key) : nil) {
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
        .nothingHere(tiles, empty)
    }
}

/// A series' seasons, a page of their own, as the Apple TV's: square
/// cells, a portrait cover fit whole in its square.
private struct SeasonsPage: View {
    let key: String
    @Environment(Library.self) private var library

    /// Whether its heading has scrolled away, so the bar names the series.
    @State private var headingGone = false

    var body: some View {
        let seasons = Library.seasons(of: key, in: library.tiles)
        let name = seasons.first?.name ?? ""
        ScrollView {
            // The series' name as the page's heading, whole, wrapping as it
            // must: a large navigation title keeps to one line, cutting a
            // long one short.
            Text(name)
                .font(.title.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12, alignment: .top)], spacing: 16) {
                ForEach(seasons) { tile in
                    NavigationLink(value: tile) {
                        VStack(alignment: .leading, spacing: 4) {
                            Color.clear
                                .aspectRatio(1, contentMode: .fit)
                                .overlay { TileCover(tile: tile) }
                            PosterName(tile: tile, title: tile.seasonName ?? "", showsSeason: false)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > 40 } action: { _, gone in headingGone = gone }
        .navigationTitle(headingGone ? name : "")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Each list, a row apiece; New List names a new one in place, at the top,
/// as Files names a new folder.
private struct ListsView: View {
    @Environment(Library.self) private var library
    /// Whether a new list is being named, and its name so far.
    @State private var naming = false
    @State private var name = ""
    @FocusState private var typing: Bool

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if naming {
                    TextField("New List", text: $name, prompt: Text("New List"))
                        .font(.title2.bold())
                        .submitLabel(.done)
                        .focused($typing)
                        .onSubmit(create)
                        .onAppear { typing = true }
                        .onChange(of: typing) { if !typing { create() } }
                        .padding(.horizontal)
                }
                ForEach(library.lists) { list in
                    Carousel(title: list.shownName, tiles: Shelf.list(list.id).tiles(in: library), list: list.id, shared: list.isShared)
                }
            }
            .padding(.vertical)
        }
        .overlay {
            if library.lists.isEmpty, !naming {
                ContentUnavailableView("No Lists", systemImage: "star", description: Text("Make a list to keep titles in, as a watchlist or favorites."))
            }
        }
        .navigationTitle("Lists")
        .toolbar {
            Button("New List", systemImage: "plus") { naming = true }
                .disabled(naming)
        }
    }

    /// Makes the list named, unless it's blank, which drops it.
    private func create() {
        guard naming else { return }
        naming = false
        let named = name.trimmingCharacters(in: .whitespaces)
        name = ""
        if !named.isEmpty { _ = library.createList(named: named) }
    }
}

/// One list, whole, as a grid; if it's this person's own, renamed in place
/// by its title, as Files renames a document, and shared or deleted from
/// the title's menu.
private struct ListPage: View {
    let id: String
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let shelf = Shelf.list(id)
        let list = library.lists.first { $0.id == id }
        let grid = CoverGrid(tiles: shelf.tiles(in: library), empty: shelf.empty)
            .onChange(of: list == nil) { _, gone in
                if gone { dismiss() }
            }
        if let list, list.isMine {
            grid
                .navigationTitle(Binding(get: { list.name }, set: { rename(list, $0) }))
                .navigationBarTitleDisplayMode(.inline)
                .toolbarTitleMenu {
                    RenameButton()
                    ListActions(list: list)
                }
        } else {
            grid.navigationTitle(shelf.name(in: library))
        }
    }

    /// A blank name, or the same, is no change.
    private func rename(_ list: UserList, _ typed: String) {
        let named = typed.trimmingCharacters(in: .whitespaces)
        if !named.isEmpty, named != list.name { library.renameList(list.id, to: named) }
    }
}

/// Search, on its tab: every title whose name has what's typed.
private struct SearchView: View {
    @Environment(Library.self) private var library
    @State private var text = ""

    var body: some View {
        CoverGrid(tiles: library.search(text), series: true, empty: text.isEmpty ? "Search by a title's name." : "Nothing has that name.")
            .navigationTitle("Search")
            .searchable(text: $text)
    }
}

#endif
