#if os(tvOS)
import SwiftUI

/// The home page, and one navigation stack of pages pushed from it: each
/// section's, and titles' pages (a movie's, or a season's; a series' tile,
/// a page of its seasons first). Back retraces them to the home page, and
/// from it leaves the app.
struct Browser: View {
    /// A section, a page pushed from the home page, in the order its button
    /// has there.
    enum Section: String, Hashable, CaseIterable {
        case movies, series, lists, watched, search, settings

        var title: String {
            switch self {
            case .movies: Shelf.movies.title
            case .series: Shelf.series.title
            case .lists: Shelf.lists.title
            case .watched: Shelf.watched.title
            case .search: "Search"
            case .settings: "Settings"
            }
        }
    }

    @Environment(Library.self) private var library
    @State private var path = NavigationPath()
    /// A link's title to open (the Top Shelf's), once the library has it;
    /// then the title itself, its page over the app.
    @State private var link: URL?
    @State private var opened: Opened?
    /// What a tile's Play/Pause plays, over the whole stack, from where it
    /// was pressed, with no page between.
    @State private var playing: PlayRequest?

    /// A title opened by a link, and whether to play it at once (the Top
    /// Shelf's Play/Pause, rather than its select); each opening its own,
    /// as one of the title shown already, taken for the same, played
    /// nothing.
    struct Opened: Identifiable {
        let tile: Tile
        let playing: Bool
        let id = UUID()
    }

    var body: some View {
        NavigationStack(path: $path) {
            HomeView()
                .navigationDestination(for: Section.self) { SectionPage(section: $0) }
                .navigationDestination(for: Tile.self) { tile in
                    if tile.isSeries { SeasonView(tile: tile, detail: library.detail(tile.key)) } else { MovieView(tile: tile, detail: library.detail(tile.key)) }
                }
                .navigationDestination(for: SeriesSeasons.self) { SeasonsView(key: $0.key, detail: library.detail($0.key)) }
                .navigationDestination(for: ListPageID.self) { ListPage(id: $0.id) }
        }
        .environment(\.playNow, PlayNow { playing = $0 })
        .modifier(PlaysFullScreen(request: $playing))
        .overlay(alignment: .bottomTrailing) { Activity() }
        .task { TVPlayer.warmUp() }
        .onOpenURL { link = $0 }
        .task(id: "\(link?.absoluteString ?? "") \(library.tiles.count)") {
            guard let url = link, let tile = TopShelfPublisher.tile(url, in: library) else { return }
            link = nil
            // At once, not sliding in over the app, which showed for the
            // moment it took.
            var now = Transaction()
            now.disablesAnimations = true
            withTransaction(now) { opened = Opened(tile: tile, playing: TopShelfPublisher.plays(url)) }
        }
        // Presented over the app, as tvOS gives a screen it presents focus
        // (its page's first, Play or Resume): pushed on Home within the tab
        // view the app had, as the app came to the front, focus stayed in
        // the tab bar, now and then. Back closes it, to where the app was.
        .fullScreenCover(item: $opened) { opened in
            let tile = opened.tile
            Group {
                if tile.isSeries {
                    SeasonView(tile: tile, detail: library.detail(tile.key), playing: opened.playing)
                } else {
                    MovieView(tile: tile, detail: library.detail(tile.key), playing: opened.playing)
                }
            }
            // A page of its own each time, not the one shown kept, its
            // state too, as a cover shown already is.
            .id(opened.id)
            // Its own ground, under its backdrop, as the app's own is
            // behind it now.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { Rectangle().fill(.background).ignoresSafeArea() }
        }
        // What Home shows, for the Top Shelf, once changes settle.
        .task(id: library.revision) {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { await TopShelfPublisher.publish(library) }
        }
        #if DEBUG
        // A section's page (`CINEMATHEQUE_TAB`), then, once the title has
        // arrived (a first launch's sync brings it), a season's page, or a
        // series' seasons (`CINEMATHEQUE_SELECT`).
        .onAppear {
            if path.isEmpty, let section = Launch.tab.flatMap(Section.init(rawValue:)) { path.append(section) }
        }
        .task(id: library.tiles.isEmpty) {
            guard !selected, let id = Launch.selection else { return }
            if let tile = library.tiles.first(where: { $0.id == id }) {
                selected = true
                path.append(tile)
            } else if let key = Launch.selectedTitle, library.tiles.contains(where: { $0.key == key }) {
                selected = true
                path.append(SeriesSeasons(key: key))
            }
        }
        #endif
    }

    #if DEBUG
    @State private var selected = false
    #endif
}

/// A series' seasons, as a page: what a series' tile opens.
struct SeriesSeasons: Hashable {
    let key: String
}

/// A list's whole page, by the list's ID: what See All opens.
struct ListPageID: Hashable {
    let id: String
}

/// A section's page: its covers in a grid under its name (a series' each,
/// opening its seasons), every list's row, search, or settings.
private struct SectionPage: View {
    let section: Browser.Section
    @Environment(Library.self) private var library

    var body: some View {
        switch section {
        case .movies:
            PosterGrid(tiles: Shelf.movies.tiles(in: library), empty: Shelf.movies.empty, heading: section.title)
        case .series:
            PosterGrid(tiles: library.perTitle(Shelf.series.tiles(in: library)), empty: Shelf.series.empty, heading: section.title, series: true)
        case .lists:
            ListsView()
        case .watched:
            PosterGrid(tiles: Shelf.watched.tiles(in: library), empty: Shelf.watched.empty, heading: section.title)
        case .search:
            SearchView()
        case .settings:
            SettingsView()
        }
    }
}

/// The home page: the sections' buttons, then rows of what to watch: in
/// progress (movies partway, seasons begun), then each list.
private struct HomeView: View {
    @Environment(Library.self) private var library

    var body: some View {
        let going = Shelf.home.tiles(in: library)
        let lists = library.lists.map { ($0, Shelf.list($0.id).tiles(in: library)) }.filter { !$0.1.isEmpty }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 50) {
                Sections()
                if going.isEmpty && lists.isEmpty {
                    ContentUnavailableView("Nothing in Progress", systemImage: "play.rectangle", description: Text(Shelf.home.empty))
                        .frame(maxWidth: .infinity)
                }
                if !going.isEmpty { Row(title: "Continue Watching", tiles: going) }
                ForEach(lists, id: \.0.id) { list, tiles in Row(title: list.shownName, tiles: tiles, list: list.id, shared: list.isShared) }
            }
            .padding(.vertical, 40)
        }
        .scrollClipDisabled()
    }
}

/// The sections' buttons, in a row at the top of the home page: names,
/// but Search's and Settings' symbols, as their tabs had.
private struct Sections: View {
    var body: some View {
        HStack(spacing: 30) {
            ForEach(Browser.Section.allCases, id: \.self) { section in
                NavigationLink(value: section) {
                    switch section {
                    case .search: Image(systemName: "magnifyingglass").accessibilityLabel(section.title)
                    case .settings: Image(systemName: "gearshape").accessibilityLabel(section.title)
                    default: Text(section.title)
                    }
                }
            }
        }
        // Its whole width, so moving up from a row reaches it from any
        // cover.
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
    }
}

/// Each list, a row apiece, by name, with New List; a list's own Rename
/// and Delete in its heading's menu.
private struct ListsView: View {
    @Environment(Library.self) private var library
    #if DEBUG
    /// A list's page opened at launch (`CINEMATHEQUE_PAGE`, `list:<id>`).
    @State private var opened: String?
    #endif

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 50) {
                Text(Shelf.lists.title).font(.title3.weight(.semibold))
                if library.lists.isEmpty {
                    ContentUnavailableView("No Lists", systemImage: "star", description: Text("Make a list to keep titles in, as a watchlist or favorites."))
                        .frame(maxWidth: .infinity)
                }
                ForEach(library.lists) { list in
                    let tiles = Shelf.list(list.id).tiles(in: library)
                    // A plain heading, as Home's rows have; the list's page,
                    // from its row's first tile, renames or deletes it.
                    Row(title: list.shownName, tiles: tiles, list: list.id, shared: list.isShared)
                }
                // Rare, so last.
                Button("New List", systemImage: "plus") { library.listPrompt = .init(kind: .create(adding: [])) }
            }
            .padding(.vertical, 40)
        }
        #if DEBUG
        .navigationDestination(item: $opened) { ListPage(id: $0) }
        .onAppear {
            if let page = Launch.page, page.hasPrefix("list:") { opened = String(page.dropFirst("list:".count)) }
        }
        #endif
    }
}

/// A list's whole page, where it's renamed and deleted too: a small
/// button saying how many titles it holds.
private struct SeeAll: View {
    let list: String
    let count: Int

    var body: some View {
        NavigationLink(value: ListPageID(id: list)) {
            HStack(spacing: 8) {
                Text("See All \(count)")
                Image(systemName: "chevron.right")
            }
            .font(.caption)
        }
        .controlSize(.small)
    }
}

/// One list, whole, as a shelf's grid, under its name; renaming and
/// deleting it last, as rare.
private struct ListPage: View {
    let id: String
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let shelf = Shelf.list(id)
        let list = library.lists.first { $0.id == id }
        // Its name as the grid's first line, aligned with the covers and
        // scrolling away with them: a navigation title stayed at the top,
        // inset from them.
        PosterGrid(tiles: shelf.tiles(in: library), empty: shelf.empty, heading: shelf.name(in: library)) {
            // Another member's is theirs to change.
            if let list, list.isMine {
                HStack(spacing: 30) {
                    Button("Rename…") { library.listPrompt = .init(kind: .rename(list)) }
                    if list.isShared {
                        Button("Stop Sharing") { library.shareList(list.id, false) }
                    } else {
                        Button("Share…") { library.sharingList = list }
                    }
                    Button("Delete List…", role: .destructive) { library.deletingList = list }
                }
            }
        }
        // Deleted (here, or by another device), back to Lists, as the page
        // has nothing left to focus; on coming back to it too, from a
        // title opened here, as it may not go back while covered.
        .onChange(of: list == nil) { _, gone in
            if gone { dismiss() }
        }
        .onAppear {
            if list == nil { dismiss() }
        }
    }
}

private struct Row: View {
    let title: String
    let tiles: [Tile]
    /// A list's, whose page See All, small, beside the heading, opens, so a
    /// long row needn't be scrolled through to reach it.
    var list: String? = nil
    /// A shared list's, its heading marked with people.
    var shared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Centered: See All's pill, not its smaller text, is what the
            // eye lines up, and on the heading's baseline it drooped.
            HStack(alignment: .center, spacing: 24) {
                if shared {
                    Label(title, systemImage: UserList.sharedSymbol).font(.title3)
                } else {
                    Text(title).font(.title3)
                }
                if let list { SeeAll(list: list, count: tiles.count) }
            }
            // As the row below: See All, small and at the left, takes focus
            // moving down from the sections' buttons, as the heading's whole
            // width does, not a cover more nearly beneath the button.
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusSection()
            // A carousel, not a grid: every cover one height, each its own
            // width, as its shape has it.
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 40) {
                    ForEach(tiles) { Poster(tile: $0, inRow: true) }
                }
                .padding(.vertical, 30)
            }
            .scrollClipDisabled()
            // The whole row's width takes focus moving into it, so moving
            // down goes to the first row's nearest cover, not to one further
            // down that's more nearly beneath the button.
            .focusSection()
        }
    }
}

/// Covers in a grid, six to a row.
struct PosterGrid<Footer: View>: View {
    let tiles: [Tile]
    var empty = Shelf.movies.empty
    /// A heading above the covers, and what follows them, scrolling with
    /// them.
    var heading: String? = nil
    /// Whether a series' tiles stand for the whole series (opening its
    /// seasons), not a season.
    var series = false
    @ViewBuilder var footer: Footer

    var body: some View {
        ScrollView {
            if let heading {
                Text(heading)
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 40)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 48, alignment: .top), count: 6), spacing: 60) {
                ForEach(tiles) { Poster(tile: $0, series: series) }
            }
            .padding(.vertical, 40)
            footer
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 40)
        }
        .overlay {
            if tiles.isEmpty { ContentUnavailableView("Nothing Here", systemImage: "film.stack", description: Text(empty)) }
        }
    }
}

extension PosterGrid where Footer == EmptyView {
    init(tiles: [Tile], empty: String = Shelf.movies.empty, heading: String? = nil, series: Bool = false) {
        self.init(tiles: tiles, empty: empty, heading: heading, series: series) { EmptyView() }
    }
}

/// Out of the way of its cover, which lifts and grows as it's focused: what's
/// under it (its name) moves down with it.
private struct ClearsLift: ViewModifier {
    @Environment(\.isFocused) private var focused

    func body(content: Content) -> some View {
        content
            .offset(y: focused ? 24 : 0)
            .animation(.easeOut(duration: 0.2), value: focused)
    }
}

/// A poster's name, and a season's under it, moving out of the way of its
/// cover as the cover lifts: the borderless style moves a title only for
/// an `Image`, and a cover is a view of images, placeholders, and marks.
private struct PosterName: View {
    let name: String
    var season: String? = nil
    /// At the name's line's end, so the name and they span the cover.
    var marks: TileMarks? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(name)
                Spacer(minLength: 0)
                marks?.fixedSize()
            }
            if let season { Text(season).foregroundStyle(.secondary) }
        }
        .font(.caption)
        .lineLimit(1)
        .modifier(ClearsLift())
    }
}

/// A cover that opens its title (a movie's page, a season's, or a series'
/// seasons), with this person's progress, and its name below: tvOS's
/// lockup (a borderless button), the cover lifting as it's focused and its
/// name moving out of its way.
struct Poster: View {
    let tile: Tile
    /// Whether a series' tile stands for the whole series, not a season.
    var series = false
    /// Whether it's among its series' seasons, named only as the season.
    var amongSeasons = false
    /// Whether it's in a row (a carousel), at the row's height.
    var inRow = false
    @Environment(Library.self) private var library
    @Environment(\.playNow) private var playNow

    /// A row's covers' height: a 2:3 cover's, as wide as a grid's.
    static let rowHeight: CGFloat = 360

    /// A series' seasons, unless it has only one, which it opens itself.
    private var opensSeasons: Bool {
        series && tile.isSeries && library.tiles.contains { $0.key == tile.key && $0.season != tile.season }
    }

    /// The cover itself, whole, which lifts: a movie's filling the
    /// box; a series' (a season's) in its own shape, square or 4:3, as is
    /// every cover in a row.
    private var cover: some View {
        Group {
            if tile.isSeries || inRow {
                CoverImage(cover: tile.cover, thumb: tile.thumb, title: tile.name, shaped: true)
            } else {
                CoverImage(cover: tile.cover, thumb: tile.thumb, title: tile.name)
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
            }
        }
            // Its copies are all on drives that aren't there, or it's a
            // placeholder, not in the library yet.
            .opacity(tile.unavailable || tile.isWanted ? 0.4 : 1)
            .overlay(alignment: .bottom) { CoverProgress(tile: tile) }
            .clipShape(.rect(cornerRadius: 12))
            // The cover, not its name, is what lifts.
            .hoverEffect(.highlight)
    }

    /// The lockup, its name as wide as its box: in a grid, a movie's 2:3
    /// box, so names line up along a row, a series' cover at its foot,
    /// whole, in its own shape, rather than cropped to fill it; among a
    /// series' seasons, a square, a season's cover fit whole at its center;
    /// in a row, the cover alone, at the row's height.
    private var lockup: some View {
        UnderCover(spacing: 14) {
            if inRow {
                cover.frame(height: Self.rowHeight)
            } else if amongSeasons {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay { cover }
            } else {
                Color.clear
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                    .overlay(alignment: .bottom) { cover }
            }
            if tile.isWanted {
                PosterName(name: tile.name, season: "Not in library", marks: marks)
            } else if amongSeasons {
                PosterName(name: tile.seasonName ?? tile.name, marks: marks)
            } else {
                PosterName(name: tile.name, season: series ? nil : tile.seasonName, marks: marks)
            }
        }
    }

    /// Its marks, at its name's line's end; a series' tile on a list if any
    /// season is.
    private var marks: TileMarks {
        TileMarks(listed: series ? library.isAnySeasonListed(tile) : library.isListed(tile), watched: tile.watched)
    }

    var body: some View {
        // Typed, as destinations are found by the value's type.
        Group {
            if tile.isWanted {
                // A placeholder: nothing to open, but its menu takes it off.
                Button {} label: { lockup }
            } else if opensSeasons {
                NavigationLink(value: SeriesSeasons(key: tile.key)) { lockup }
            } else {
                NavigationLink(value: tile) { lockup }
            }
        }
        .buttonStyle(.borderless)
        // Play/Pause plays it at once, as Apple's apps' tiles do: what its
        // page's Play plays, a series' the season to watch.
        .onPlayPauseCommand {
            if let request = playRequest() { playNow(request) }
        }
        // Pressed and held: a movie's or a season's lists (as only they
        // go on lists) and marks; a series' tile's, the whole series'.
        .contextMenu {
            if tile.isWanted {
                if library.isWantedByMe(tile.id) { Button("Remove from List", systemImage: "minus.circle") { library.unwant(tile.id) } }
            } else {
                titleMenu
            }
        }
    }

    /// What its page's Play plays: a movie's or a season's next item; for a
    /// series' tile, the season to watch's (the first not watched through).
    private func playRequest() -> PlayRequest? {
        guard !tile.isWanted, let detail = library.detail(tile.key) else { return nil }
        let season = opensSeasons ? Library.nextSeason(Library.seasons(of: tile.key, in: library.tiles))?.season : tile.season
        return Playback.next(in: detail, season: season, quality: detail.quality(for: Playback.items(detail, season: season), chosen: nil))
    }

    @ViewBuilder
    private var titleMenu: some View {
            if !series || !tile.isSeries {
                Menu("Lists", systemImage: "star") { ListToggles(key: tile.id) }
            }
            // Unwatched forgets where you stopped, too.
            if !tile.watched {
                Button("Mark as Watched", systemImage: "checkmark.circle") { series ? library.markSeriesWatched(tile, true) : library.markWatched(tile, true) }
            }
            if tile.started {
                Button("Mark as Unwatched", systemImage: "circle") { series ? library.markSeriesWatched(tile, false) : library.markWatched(tile, false) }
            }
    }
}

/// Plays a request over the whole navigation stack, as a tile's
/// Play/Pause does: a type, as the environment can't compare a closure, so
/// a closure kept there redrew whatever read it on every update.
struct PlayNow {
    let play: (PlayRequest) -> Void

    func callAsFunction(_ request: PlayRequest) { play(request) }
}

extension EnvironmentValues {
    @Entry var playNow = PlayNow { _ in }
}

private struct SearchView: View {
    @Environment(Library.self) private var library
    @State private var text = ""

    var body: some View {
        // Every shelf's titles but Home's, which are among them.
        let found = text.isEmpty ? [] : library.perTitle(Shelf.movies.tiles(in: library, search: text) + Shelf.series.tiles(in: library, search: text))
        PosterGrid(tiles: found, empty: text.isEmpty ? "Search for a movie or series." : "No titles match “\(text)”.", series: true)
            .searchable(text: $text)
    }
}

/// A series' seasons, as a page under its name: Play or Resume for the
/// season to watch (the first not watched through), focused first, and
/// the whole series' watched mark; then its seasons in square cells
/// (specials last), each opening its page.
struct SeasonsView: View {
    let key: String
    @Environment(Library.self) private var library
    @State private var detail: TitleDetail?
    @State private var playing: PlayRequest?

    /// With its details as they are, so Play is there to focus first.
    init(key: String, detail: TitleDetail?) {
        self.key = key
        _detail = State(initialValue: detail)
    }

    var body: some View {
        let seasons = Library.seasons(of: key, in: library.tiles)
        let up = Library.nextSeason(seasons)
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                Text(seasons.first?.name ?? "")
                    .font(.title3.weight(.semibold))
                if let detail, let series = library.perTitle(seasons).first {
                    HStack(spacing: 30) {
                        // The season it plays, by name ("Resume Season 2"),
                        // as Play alone says nothing of which.
                        let verb = Playback.nextItem(detail, season: up?.season)?.inProgress == true ? "Resume" : "Play"
                        Button([verb, up?.seasonName].compactMap { $0 }.joined(separator: " "), systemImage: "play.fill") {
                            playing = Playback.next(in: detail, season: up?.season, quality: detail.quality(for: Playback.items(detail, season: up?.season), chosen: nil))
                        }
                        // The whole series': a status that pressing toggles,
                        // as a season's is.
                        Button(series.watched ? "Watched" : "Unwatched", systemImage: series.watched ? "checkmark.circle.fill" : "circle") {
                            library.markSeriesWatched(series, !series.watched)
                        }
                        .labelStyle(.iconOnly)
                    }
                    .focusSection()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 40)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 48, alignment: .top), count: 6), spacing: 60) {
                ForEach(seasons) { Poster(tile: $0, amongSeasons: true) }
            }
            .padding(.vertical, 40)
        }
        .task(id: library.detailsRevision) { detail = library.detail(key) }
        .modifier(PlaysFullScreen(request: $playing))
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
