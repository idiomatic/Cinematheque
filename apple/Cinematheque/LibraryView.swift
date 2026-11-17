import SwiftUI

/// The library as a grid of covers: movies, and series by season, filtered
/// by shelf and search, beside an inspector for the one selected.
struct LibraryView: View {
    enum Shelf: String, CaseIterable, Identifiable {
        case movies = "Movies", series = "Series", watchlist = "Watchlist"
        var id: Self { self }
        var symbol: String {
            switch self {
            case .movies: "film"
            case .series: "tv"
            case .watchlist: "star"
            }
        }
    }

    @Environment(Library.self) private var library
    @State private var shelf: Shelf? = .movies
    @State private var search = ""
    @State private var selection: Tile.ID?
    @State private var inspecting = true
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var library = library
        Group {
            if library.status == nil {
                ContentUnavailableView("No Peer Home", systemImage: "exclamationmark.triangle", description: Text(library.error ?? ""))
            } else if !library.hasLibrary {
                SetupView()
            } else {
                browser
            }
        }
        .alert("Cinematheque", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
            Button("OK") { library.error = nil }
        } message: {
            Text(library.error ?? "")
        }
    }

    private var browser: some View {
        NavigationSplitView {
            List(Shelf.allCases, selection: $shelf) { shelf in
                Label(shelf.rawValue, systemImage: shelf.symbol)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            CoverGrid(tiles: shown, selection: $selection)
                .navigationTitle(shelf?.rawValue ?? "Cinematheque")
                // What a long operation is doing, while it runs.
                .navigationSubtitle(library.activity.map { $0 + "…" } ?? "\(shown.count) \(shown.count == 1 ? "title" : "titles")")
                .inspector(isPresented: $inspecting) {
                    Group {
                        if let tile = library.tiles.first(where: { $0.id == selection }) {
                            InspectorView(tile: tile)
                                .id(tile.id)
                        } else {
                            ContentUnavailableView("Choose a Title", systemImage: "film")
                        }
                    }
                    .inspectorColumnWidth(min: 300, ideal: 360, max: 520)
                }
                // Search, as SwiftUI places it, goes last; the inspector's
                // toggle just before it, as in Photos.
                .searchable(text: $search, placement: .toolbar)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        inspectorToggle
                    }
                }
        }
        #if DEBUG
        .onAppear {
            if let id = Launch.selection { selection = id }
            if let url = Launch.play { openWindow(value: PlayRequest(url: url, item: Launch.item ?? "", start: 0)) }
        }
        #endif
    }

    private var inspectorToggle: some View {
        Button(inspecting ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.trailing") { inspecting.toggle() }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .help(inspecting ? "Hide the inspector" : "Show the inspector")
    }

    private var shown: [Tile] {
        library.tiles.filter { tile in
            let onShelf = switch shelf ?? .movies {
            case .movies: !tile.isSeries
            case .series: tile.isSeries
            case .watchlist: library.watchlist.contains(tile.key)
            }
            return onShelf && (search.isEmpty || tile.name.localizedCaseInsensitiveContains(search))
        }
    }
}

/// Tiles of fixed size, laid out lazily: movies' covers 2:3, and each
/// series' seasons together, square.
struct CoverGrid: View {
    let tiles: [Tile]
    @Binding var selection: Tile.ID?
    @Environment(Library.self) private var library
    @Environment(\.openWindow) private var openWindow
    /// Tiles on screen or near it (the lazy grid's), whose titles a crawl
    /// describes first.
    @State private var visible: Set<Tile.ID> = []

    private struct Group: Identifiable {
        let key: String
        let name: String
        let year: Int?
        let seasons: [Tile]
        var id: String { key }
    }

    var body: some View {
        let movies = tiles.filter { !$0.isSeries }
        let series = groups(tiles.filter(\.isSeries))
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if !movies.isEmpty {
                    grid(movies, aspect: 2.0 / 3.0)
                }
                ForEach(series) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(group.name + (group.year.map { " (\($0))" } ?? ""))
                            .font(.title3.weight(.semibold))
                        grid(group.seasons, aspect: 1)
                    }
                }
            }
            .padding(20)
        }
        // Once scrolling settles.
        .task(id: visible) {
            try? await Task.sleep(for: .milliseconds(200))
            // A tile's ID is its title's key, then `#` and a season for a
            // series' season.
            if !Task.isCancelled { library.prioritize(Set(visible.map { String($0.split(separator: "#")[0]) })) }
        }
        .overlay {
            if tiles.isEmpty {
                ContentUnavailableView("Nothing Here", systemImage: "film.stack", description: Text("Add repositories and crawl them in Settings."))
            }
        }
    }

    private func grid(_ tiles: [Tile], aspect: Double) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 18, alignment: .top)], alignment: .leading, spacing: 22) {
            ForEach(tiles) { tile in
                // Selecting at once, not after the double-click interval.
                TileView(tile: tile, aspect: aspect, selected: selection == tile.id)
                    .onAppear { visible.insert(tile.id) }
                    .onDisappear { visible.remove(tile.id) }
                    .onTapGesture { selection = tile.id }
                    .simultaneousGesture(TapGesture(count: 2).onEnded { play(tile) })
            }
        }
    }

    private func groups(_ seasons: [Tile]) -> [Group] {
        var order: [String] = []
        var byKey: [String: [Tile]] = [:]
        for tile in seasons {
            if byKey[tile.key] == nil { order.append(tile.key) }
            byKey[tile.key, default: []].append(tile)
        }
        return order.map { key in
            let list = byKey[key]!
            return Group(key: key, name: list[0].name, year: list[0].year, seasons: list)
        }
    }

    /// Plays what's next in a tile: a movie, or a season's next unwatched
    /// episode, then the rest of the season.
    private func play(_ tile: Tile) {
        selection = tile.id
        guard let detail = library.detail(tile.key), let request = Playback.next(in: detail, season: tile.season) else { return }
        openWindow(value: request)
    }
}

struct TileView: View {
    let tile: Tile
    let aspect: Double
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(aspect, contentMode: .fit)
                .overlay { CoverImage(cover: tile.cover, title: tile.seasonName ?? tile.name) }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: selected ? 3 : 1)
                }
                .overlay(alignment: .topTrailing) {
                    if tile.watched {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .padding(6)
                    }
                }
                .overlay(alignment: .bottom) {
                    if !tile.watched, tile.progress > 0 {
                        ProgressView(value: tile.progress)
                            .progressViewStyle(.linear)
                            .tint(.white)
                            .padding(8)
                    }
                }
                .shadow(color: .black.opacity(0.15), radius: 3, y: 2)
            Text(tile.seasonName ?? tile.name)
                .font(.callout)
                .lineLimit(1)
            if tile.season == nil, let year = tile.year {
                Text(String(year))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

