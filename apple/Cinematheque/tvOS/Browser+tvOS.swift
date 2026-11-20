#if os(tvOS)
import SwiftUI

/// The tab bar: Home, Movies, Series, Watchlist, Watched, Settings, and
/// Search, each shelf a navigation stack opening titles' detail pages.
struct Browser: View {
    /// A tab: a shelf, search, or settings.
    enum Tab: Hashable {
        case shelf(Shelf), search, settings
    }

    @Environment(Library.self) private var library
    @State private var tab: Tab = .shelf(.home)
    /// A link's title to open on Home (the Top Shelf's), once the library
    /// has it; then the title itself.
    @State private var link: URL?
    @State private var opening: Tile?

    var body: some View {
        TabView(selection: $tab) {
            ForEach(Shelf.allCases.filter { !Shelf.macOnly.contains($0) }) { shelf in
                SwiftUI.Tab(shelf.title, systemImage: shelf.symbol, value: Tab.shelf(shelf)) {
                    Stack(opening: shelf == .home ? $opening : nil) {
                        if shelf == .home {
                            HomeView()
                        } else {
                            // A page per series (its seasons are there), so a
                            // cover per title.
                            PosterGrid(tiles: library.perTitle(shelf.tiles(in: library)), empty: shelf.empty)
                        }
                    }
                }
            }
            // Symbols alone, so every tab fits; Settings before Search, as
            // tvOS shows no tab after search's.
            SwiftUI.Tab(value: Tab.settings) {
                NavigationStack { SettingsView() }
            } label: {
                Image(systemName: "gearshape").accessibilityLabel("Settings")
            }
            SwiftUI.Tab(value: Tab.search, role: .search) {
                Stack { SearchView() }
            } label: {
                Image(systemName: "magnifyingglass").accessibilityLabel("Search")
            }
        }
        .overlay(alignment: .bottomTrailing) { Activity() }
        .task { TVPlayer.warmUp() }
        .onOpenURL { link = $0 }
        .task(id: "\(link?.absoluteString ?? "") \(library.tiles.count)") {
            guard let url = link, let tile = TopShelfPublisher.tile(url, in: library) else { return }
            link = nil
            tab = .shelf(.home)
            opening = tile
        }
        // What Home shows, for the Top Shelf, once changes settle.
        .task(id: library.revision) {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { await TopShelfPublisher.publish(library) }
        }
        #if DEBUG
        .onAppear {
            if let name = Launch.tab { tab = name == "search" ? .search : name == "settings" ? .settings : Shelf(rawValue: name).map(Tab.shelf) ?? tab }
        }
        #endif
    }
}

/// A tab's navigation stack, opening a movie's page or a series'.
private struct Stack<Content: View>: View {
    /// A title to open, as a link asks (Home's).
    var opening: Binding<Tile?>? = nil
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
        .onChange(of: opening?.wrappedValue) { _, tile in
            guard let tile else { return }
            path = [tile]
            opening?.wrappedValue = nil
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
        let listed = library.perTitle(Shelf.watchlist.tiles(in: library))
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
            // The whole row's width takes focus moving into it, so moving
            // down from the tab bar goes to the first row's nearest cover,
            // not to one further down that's more nearly beneath the tab.
            .focusSection()
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

/// A poster's name, moving out of the way of its cover as the cover lifts:
/// the borderless style moves a title only for an `Image`, and a cover is a
/// view of images, placeholders, and marks.
private struct PosterName: View {
    let name: String
    @Environment(\.isFocused) private var focused

    var body: some View {
        Text(name)
            .font(.caption)
            .lineLimit(1)
            .offset(y: focused ? 24 : 0)
            .animation(.easeOut(duration: 0.2), value: focused)
    }
}

/// A cover that opens its title, with this person's progress, and its name
/// below: tvOS's lockup (a borderless button), the cover lifting as it's
/// focused and its name moving out of its way.
struct Poster: View {
    let tile: Tile
    @Environment(Library.self) private var library

    var body: some View {
        NavigationLink(value: tile) {
            VStack(alignment: .leading, spacing: 14) {
                Color.clear
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                    .overlay { CoverImage(cover: tile.cover, thumb: tile.thumb, title: tile.name) }
                    // Its copies are all on drives that aren't there.
                    .opacity(tile.unavailable ? 0.4 : 1)
                    // A series' tile stands for the whole series.
                    .overlay(alignment: .top) { CoverMarks(listed: library.isListed(tile, anySeason: true), watched: tile.watched, padding: 10) }
                    .overlay(alignment: .bottom) {
                        if !tile.watched, tile.progress > 0 {
                            ProgressView(value: tile.progress).tint(.white).padding(12)
                        }
                    }
                    .clipShape(.rect(cornerRadius: 12))
                    // The cover, not its name, is what lifts.
                    .hoverEffect(.highlight)
                PosterName(name: tile.name)
            }
        }
        .buttonStyle(.borderless)
        // Pressed and held: a series' tile stands for the whole series.
        .contextMenu {
            let listed = library.isListed(tile, anySeason: true)
            Button(listed ? "Remove from Watchlist" : "Add to Watchlist", systemImage: listed ? "star.slash" : "star") {
                library.setListed(tile, !listed, anySeason: true)
            }
            // Unwatched forgets where you stopped, too.
            if !tile.watched {
                Button("Mark as Watched", systemImage: "checkmark.circle") { library.markWatched(tile, true, wholeTitle: tile.isSeries) }
            }
            if tile.started {
                Button("Mark as Unwatched", systemImage: "circle") { library.markWatched(tile, false, wholeTitle: tile.isSeries) }
            }
        }
    }
}

private struct SearchView: View {
    @Environment(Library.self) private var library
    @State private var text = ""

    var body: some View {
        // Every shelf's titles but Home's, which are among them.
        let found = text.isEmpty ? [] : library.perTitle(Shelf.movies.tiles(in: library, search: text) + Shelf.series.tiles(in: library, search: text))
        PosterGrid(tiles: found, empty: text.isEmpty ? "Search for a movie or series." : "No titles match “\(text)”.")
            .searchable(text: $text)
    }
}

/// What a refresh is doing, or what went wrong, in a corner.
private struct Activity: View {
    @Environment(Library.self) private var library
    /// Whether to show the last exchange with devices, for a while after it.
    @State private var showsExchange = false
    @AppStorage(Library.showsSyncActivity) private var showsSyncActivity = false

    var body: some View {
        content
            .task(id: "\(library.received?.at ?? .distantPast)|\(library.sent?.at ?? .distantPast)") {
                guard showsSyncActivity, library.received != nil || library.sent != nil else { return }
                showsExchange = true
                try? await Task.sleep(for: .seconds(6))
                if !Task.isCancelled { showsExchange = false }
            }
    }

    @ViewBuilder
    private var content: some View {
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
        } else if showsExchange {
            Label(library.syncLine, systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(24)
        }
    }
}
#endif
