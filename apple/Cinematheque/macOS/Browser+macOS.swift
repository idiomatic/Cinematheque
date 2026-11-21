#if os(macOS)
import SwiftUI

extension FocusedValues {
    /// Focuses the library window's search, as Edit › Find does.
    @Entry var find: FindAction?
    /// The library window's shelf's order, as View › Sort By sets it.
    @Entry var shelfOrder: Binding<ShelfOrder>?
}

/// View › Sort By: the shown shelf's order (Title, Release Date, Date
/// Added, Date Watched), then its direction, as Finder's.
struct SortCommand: View {
    @FocusedValue(\.shelfOrder) private var order

    var body: some View {
        Menu("Sort By") {
            if let order {
                Picker("Sort By", selection: Binding(get: { order.wrappedValue.by }, set: { order.wrappedValue = .init(by: $0) })) {
                    ForEach(ShelfOrder.By.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Divider()
                let names = order.wrappedValue.by.directions
                Picker("Direction", selection: order.reversed) {
                    Text(names.0).tag(false)
                    Text(names.1).tag(true)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
        .disabled(order == nil)
    }
}

/// Each shelf's order, once chosen, kept as JSON (`@AppStorage` keeps
/// strings).
struct ShelfOrders: RawRepresentable {
    var byShelf: [String: ShelfOrder] = [:]

    init() {}
    init?(rawValue: String) {
        byShelf = (try? JSONDecoder().decode([String: ShelfOrder].self, from: Data(rawValue.utf8))) ?? [:]
    }
    var rawValue: String { String(decoding: (try? JSONEncoder().encode(byShelf)) ?? Data("{}".utf8), as: UTF8.self) }

    subscript(shelf: Shelf) -> ShelfOrder {
        get { byShelf[shelf.rawValue] ?? shelf.defaultOrder }
        set { byShelf[shelf.rawValue] = newValue }
    }
}

/// Focusing a window's search: compared by the window it's for, as a
/// closure can't be, so views depending on it aren't redrawn on every
/// update.
struct FindAction: Equatable {
    let window: UUID
    let perform: () -> Void

    func callAsFunction() { perform() }

    static func == (a: FindAction, b: FindAction) -> Bool { a.window == b.window }
}

/// Edit › Find (⌘F), focusing the library window's search, as the covers
/// have the keys at launch.
struct FindCommand: View {
    @FocusedValue(\.find) private var find

    var body: some View {
        Button("Find") { find?() }
            .keyboardShortcut("f")
            .disabled(find == nil)
    }
}

/// The library as a grid of covers: movies, and series by season, filtered
/// by shelf and search, beside an inspector for the one selected.
struct Browser: View {
    /// The shelves in the sidebar.
    static let shelves: [Shelf] = [.movies, .series, .inProgress, .watched, .downloaded]

    @Environment(Library.self) private var library
    /// The shelf shown last, again at launch; at first, In Progress.
    @AppStorage("shelf") private var lastShelf: Shelf = .inProgress
    @State private var shelf: Shelf?
    /// The list whose name is being edited in the sidebar, if any.
    @State private var renaming: String?
    @AppStorage("orders") private var orders = ShelfOrders()
    @State private var search = ""
    /// Whether search has the keys (Find, ⌘F, gives it them).
    @FocusState private var searching: Bool
    /// This window's, for its Find action.
    @State private var window = UUID()
    @State private var selection: Tile.ID?
    @State private var inspecting = true
    /// Each shelf's scroll position, to return to.
    @State private var positions = ScrollMemory()
    @State private var nearBottom = false
    @State private var gridHeight: CGFloat = 0
    @Environment(\.openWindow) private var openWindow

    /// What plays in the library's window, filling it.
    @State private var playing: PlayRequest?

    var body: some View {
        ZStack {
            browser
            if let playing {
                // Its black fading away, to the library.
                WindowPlayer(request: playing) { withAnimation(.easeOut(duration: Platform.fade)) { self.playing = nil } }
                    .id(playing)
                    .transition(.opacity)
            }
        }
        .environment(\.play, PlayAction(inWindow: { playing = $0 }, newWindow: { openWindow(value: $0) }))
        .onAppear {
            // One the sidebar has no longer (another build's, or a list
            // deleted) gives way.
            if shelf == nil { shelf = shown(lastShelf) ? lastShelf : .inProgress }
        }
        .onChange(of: shelf) { if let shelf { lastShelf = shelf } }
        .onChange(of: library.lists) { if let shelf, !shown(shelf) { self.shelf = .inProgress } }
    }

    private var browser: some View {
        NavigationSplitView {
            List(selection: $shelf) {
                ForEach(Self.shelves) { shelf in
                    Label(shelf.title, systemImage: shelf.symbol)
                }
                Section("Lists") {
                    ForEach(library.lists) { list in
                        ListRow(list: list, renaming: $renaming)
                            .tag(Shelf.list(list.id))
                            .contextMenu {
                                Button("Rename") { renaming = list.id }
                                Button("Delete List…") { library.deletingList = list }
                            }
                    }
                    // A row of its own, last: at the sidebar's foot, under
                    // its glass, the list took its clicks. Named in place,
                    // as Notes' New Folder is.
                    Button(action: newList) {
                        Label("New List", systemImage: "plus")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            // A scroll view per shelf: one left scrolled past the end of a
            // shorter shelf shows nothing until scrolled.
            CoverGrid(tiles: shown, selection: $selection, shelf: shelf ?? .inProgress, search: search, order: orders[shelf ?? .inProgress], positions: positions)
                .id(shelf)
                .navigationTitle(shelf?.name(in: library) ?? "Cinematheque")
                .overlay(alignment: .bottom) { StatusBar(counts: counts, hovering: nearBottom) }
                // Pointing near the bottom brings back a faded status bar.
                .onContinuousHover { phase in
                    let near = if case .active(let point) = phase { point.y > gridHeight - StatusBar.height * 1.5 } else { false }
                    if near != nearBottom { nearBottom = near }
                }
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { _, height in gridHeight = height }
                // Search, as SwiftUI places it, goes last; the inspector's
                // toggle just before it, as in Photos.
                .searchable(text: $search, placement: .toolbar)
                .searchFocused($searching)
                .focusedSceneValue(\.find, FindAction(window: window) { searching = true })
                .focusedSceneValue(\.shelfOrder, $orders[shelf ?? .inProgress])
                // Beside search while the inspector's hidden; shown, the
                // inspector's own takes its place, at the window's corner.
                .toolbar {
                    if !inspecting {
                        ToolbarItem(placement: .primaryAction) { inspectorToggle }
                    }
                }
        }
        // Outside the split view, as Apple's own example has it: full
        // height, its toggle at the start of its section of the toolbar,
        // following its divider (an inspector inside the detail column left
        // the toggle astride the divider, whose drag area reaches up into
        // the toolbar and took its clicks). The toggle is the app's, one in
        // each section, only one shown: the system's own came and went
        // between launches.
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
            .toolbar {
                if inspecting {
                    ToolbarItem(placement: .primaryAction) { inspectorToggle }
                }
            }
        }
        #if DEBUG
        .onAppear {
            if let id = Launch.selection {
                selection = id
                // On the shelf it's on, whatever was shown last.
                shelf = id.contains("#") ? .series : .movies
            }
            if let url = Launch.play.flatMap(URL.init(string:)) { playing = PlayRequest(url: url, item: Launch.item ?? "", start: 0) }
        }
        #endif
    }

    /// Makes a list, "New List" (numbered if that's taken), shows it, and
    /// edits its name in place.
    private func newList() {
        let names = Set(library.lists.map(\.name))
        let name = (1...).lazy.map { $0 == 1 ? "New List" : "New List \($0)" }.first { !names.contains($0) }!
        guard let id = library.createList(named: name) else { return }
        shelf = .list(id)
        renaming = id
    }

    /// Whether the sidebar has a shelf: its own, or a list there is.
    private func shown(_ shelf: Shelf) -> Bool {
        if case .list(let id) = shelf { return library.lists.contains { $0.id == id } }
        return Self.shelves.contains(shelf)
    }

    /// The inspector's toggle, one of two, as only one shows at a time.
    private var inspectorToggle: some View {
        Button(inspecting ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.trailing") { inspecting.toggle() }
            .help(inspecting ? "Hide the inspector" : "Show the inspector")
    }

    private var shown: [Tile] { (shelf ?? .inProgress).tiles(in: library, search: search, order: orders[shelf ?? .inProgress]) }

    private var counts: String { (shelf ?? .inProgress).counts(in: library, search: search) }
}

/// Each shelf's topmost title in view, to return to: a movie's tile or a
/// series' seasons, by title key (not an offset, which a change in the
/// grid's width would move). Not observed, so scrolling doesn't redraw the
/// view that holds it.
final class ScrollMemory {
    var tops: [Shelf: String] = [:]
}

/// A list in the sidebar: its name, or, while it's being renamed, a field
/// in its place, as Finder renames: Return keeps the name typed, Escape the
/// one it had, and clicking elsewhere keeps what's typed.
private struct ListRow: View {
    let list: UserList
    @Binding var renaming: String?
    @Environment(Library.self) private var library
    @State private var name = ""
    @FocusState private var focused: Bool
    /// Whether the field has had the keys, before which losing them (to
    /// the sidebar, as a new list's selected) doesn't end it.
    @State private var began = false

    var body: some View {
        if renaming == list.id {
            Label {
                TextField("Name", text: $name)
                    .focused($focused)
                    .onSubmit(keep)
                    .onExitCommand { renaming = nil }
                    .onAppear {
                        name = list.name
                        began = false
                        // After the sidebar's taken its selection.
                        Task { focused = true }
                    }
                    .onChange(of: focused) {
                        if focused { began = true } else if began { keep() }
                    }
            } icon: {
                Image(systemName: Shelf.list(list.id).symbol)
            }
        } else {
            Label(list.name, systemImage: Shelf.list(list.id).symbol)
        }
    }

    /// The name typed, unless it's blank or the same, once.
    private func keep() {
        guard renaming == list.id else { return }
        renaming = nil
        let typed = name.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty, typed != list.name { library.renameList(list.id, to: typed) }
    }
}

/// Tiles of fixed size: movies' covers 2:3, and each series' seasons
/// together, square. As a cell's size is fixed, every row's place and
/// height is worked out before any is drawn (`Rows`), and only those near
/// the screen are: so the scroll bar knows the whole height at once and
/// holds still, as a lazy grid's guesses at rows not yet drawn (a series'
/// seasons above all) don't.
struct CoverGrid: View {
    let tiles: [Tile]
    @Binding var selection: Tile.ID?
    let shelf: Shelf
    let search: String
    let order: ShelfOrder
    let positions: ScrollMemory
    @State private var position = ScrollPosition(edge: .top)
    /// Whether the shelf's place has been restored, before which the grid's
    /// first layout (at the top) isn't recorded over it.
    @State private var restored = false
    @Environment(Library.self) private var library
    @Environment(\.play) private var play
    /// The rows on screen, whose titles a crawl describes first, and the
    /// first of which the grid keeps in place.
    @State private var visible: Range<Int> = 0..<0
    /// What's on screen, in the content's coordinates, and how much of it
    /// the toolbar and status bar cover; not observed, so scrolling redraws
    /// only as the rows on screen change.
    @State private var viewport = Viewport()
    @State private var cache = RowCache()

    struct Seen: Equatable {
        let rect: CGRect
        let insets: EdgeInsets
    }

    final class Viewport {
        var rect: CGRect = .zero
        var insets = EdgeInsets()
        /// What's seen, clear of the toolbar and the status bar (a content
        /// margin, which the insets leave out).
        var clear: (minY: CGFloat, maxY: CGFloat) { (rect.minY + insets.top, rect.maxY - insets.bottom - StatusBar.height) }
        /// Scrolls `position` by `delta`: its offsets count from the
        /// content's top at rest, below the toolbar, where the visible
        /// rectangle's count from under it.
        func scroll(_ position: inout ScrollPosition, by delta: CGFloat) {
            position.scrollTo(y: rect.minY + insets.top + delta)
        }
    }
    /// The title at the top, kept there when the grid's width changes (as
    /// when the inspector opens or closes) and its rows reflow.
    @State private var anchor = Anchor()

    /// Not observed, so recording it doesn't redraw the grid.
    final class Anchor {
        var top: String?
    }

    struct Group: Identifiable {
        let key: String
        let name: String
        let year: Int?
        let seasons: [Tile]
        var id: String { key }
    }

    /// Every row of the grid, where it is, and how tall: the movies' rows,
    /// then each series' name and its seasons' rows.
    @MainActor struct Rows {
        struct Row: Identifiable {
            let id: String
            /// A series' name, or a row of tiles.
            let header: String?
            let tiles: [Tile]
            let aspect: Double
            /// Its title's key (the first tile's).
            let key: String
            let y: CGFloat
            let height: CGFloat
            var maxY: CGFloat { y + height }
        }

        var rows: [Row] = []
        var movies: [Tile] = []
        var groups: [Group] = []
        /// The whole grid's, its margins too.
        var height: CGFloat = 0

        init() {}

        init(_ tiles: [Tile], columns: Int) {
            movies = tiles.filter { !$0.isSeries }
            groups = Self.groups(tiles.filter(\.isSeries))
            var y = CoverGrid.margin
            func add(_ tiles: [Tile], aspect: Double, height: CGFloat, id: String) {
                for start in stride(from: 0, to: tiles.count, by: columns) {
                    let row = Array(tiles[start..<min(start + columns, tiles.count)])
                    rows.append(Row(id: "\(id)/\(start)", header: nil, tiles: row, aspect: aspect, key: row[0].key, y: y, height: height))
                    y += height + Self.rowSpacing
                }
                y += Self.sectionSpacing - Self.rowSpacing
            }
            if !movies.isEmpty { add(movies, aspect: 2.0 / 3.0, height: Self.movieHeight, id: "movies") }
            for group in groups {
                rows.append(Row(id: group.key, header: group.name + (group.year.map { " (\($0))" } ?? ""), tiles: [], aspect: 1, key: group.key, y: y, height: Self.headerHeight))
                y += Self.headerHeight + Self.headerSpacing
                add(group.seasons, aspect: 1, height: Self.seasonHeight, id: group.key)
            }
            height = rows.isEmpty ? 0 : y - Self.sectionSpacing + CoverGrid.margin
        }

        /// The rows meeting the span from `minY` to `maxY`, top to bottom.
        func range(_ minY: CGFloat, _ maxY: CGFloat) -> Range<Int> {
            // The first ending below the top, then the first starting below
            // the bottom.
            let top = first(from: 0) { $0.maxY > minY }
            return top..<first(from: top) { $0.y >= maxY }
        }

        /// The first row from `start` on that's `past`, as rows are in
        /// order: by halves.
        private func first(from start: Int, past: (Row) -> Bool) -> Int {
            var low = start, high = rows.count
            while low < high {
                let mid = (low + high) / 2
                if past(rows[mid]) { high = mid } else { low = mid + 1 }
            }
            return low
        }

        func row(of tile: Tile.ID) -> Row? {
            rows.first { $0.tiles.contains { $0.id == tile } }
        }

        /// The first row of a title: a series' name, or the row a movie's
        /// in, wherever in it the columns put it.
        func row(holding title: String) -> Row? {
            rows.first { $0.key == title || $0.tiles.contains { $0.key == title } }
        }

        private static func groups(_ seasons: [Tile]) -> [Group] {
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

        /// A text style's line, as AppKit sets it, so a tile's height is
        /// known before it's drawn.
        private static func line(_ style: NSFont.TextStyle) -> CGFloat {
            ceil(NSLayoutManager().defaultLineHeight(for: .preferredFont(forTextStyle: style)))
        }

        // A movie's cover, name, and year (a line kept for it, if it has
        // none); a season's cover and name; a series' name.
        static let movieHeight = ceil(CoverGrid.cell * 3 / 2) + TileView.spacing + line(.callout) + TileView.spacing + line(.caption1)
        static let seasonHeight = CoverGrid.cell + TileView.spacing + line(.callout)
        static let headerHeight = line(.title3)
        static let rowSpacing: CGFloat = 22
        static let headerSpacing: CGFloat = 10
        static let sectionSpacing: CGFloat = 28
    }

    /// The rows, worked out again only when the tiles or the columns change.
    /// Not observed, as it's only a cache.
    final class RowCache {
        private var tiles: [Tile] = []
        private var columns = 0
        private var rows = Rows()

        func rows(_ tiles: [Tile], columns: Int) -> Rows {
            if columns != self.columns || tiles != self.tiles {
                self.tiles = tiles
                self.columns = columns
                rows = Rows(tiles, columns: columns)
            }
            return rows
        }
    }

    private var layout: Rows { cache.rows(tiles, columns: columns) }

    var body: some View {
        let layout = layout
        // A screen's worth above and below what's on it, drawn ahead.
        let drawn = layout.range(viewport.rect.minY - viewport.rect.height, viewport.rect.maxY + viewport.rect.height)
        ScrollView {
            ZStack(alignment: .topLeading) {
                ForEach(layout.rows[drawn]) { row in
                    rowView(row)
                        .frame(height: row.height, alignment: .topLeading)
                        .offset(x: Self.margin, y: row.y)
                }
            }
            .frame(maxWidth: .infinity, minHeight: layout.height, maxHeight: layout.height, alignment: .topLeading)
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: Seen.self, of: { Seen(rect: $0.visibleRect, insets: $0.contentInsets) }) { _, seen in
            viewport.rect = seen.rect
            viewport.insets = seen.insets
            let clear = viewport.clear
            let now = self.layout.range(clear.minY, clear.maxY)
            if now != visible { visible = now }
        }
        // The arrow keys move the selection over the covers, as in the
        // Finder's icon view; Return plays it.
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        // The covers take the keys at launch, rather than search, which
        // AppKit makes the window's first responder (`defaultFocus` doesn't
        // outrank it).
        .onAppear { focused = true }
        .onMoveCommand { direction in move(direction, in: [layout.movies] + layout.groups.map(\.seasons)) }
        .onKeyPress(.return) {
            guard let tile = tiles.first(where: { $0.id == selection }) else { return .ignored }
            playNext(tile)
            return .handled
        }
        // The last row clears the status bar floating over the grid.
        .contentMargins(.bottom, StatusBar.height, for: .scrollContent)
        // Only when the rows reflow, not at every width an animation (the
        // inspector's) passes through.
        .onGeometryChange(for: Int.self, of: { Self.columns($0.size.width) }) { _, count in
            columns = count
            if let top = anchor.top { scroll(to: top) }
        }
        .task {
            // After the first layout, which ignores scrolling.
            await Task.yield()
            if search.isEmpty, let top = positions.tops[shelf] { scroll(to: top) }
            restored = true
        }
        // A new search starts at the top, which its results may not reach,
        // as does a new order.
        .onChange(of: search) { position.scrollTo(edge: .top) }
        .onChange(of: order) { position.scrollTo(edge: .top) }
        // Once scrolling settles.
        .task(id: visible) {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let rows = layout.rows[visible.clamped(to: layout.rows.indices)]
            library.prioritize(Set(rows.flatMap { row in row.tiles.map(\.key) }))
            let top = rows.first?.key
            anchor.top = top
            // The shelf's whole grid, not a search's results.
            if restored, search.isEmpty { positions.tops[shelf] = top }
        }
        .overlay {
            if tiles.isEmpty {
                ContentUnavailableView("Nothing Here", systemImage: "film.stack", description: Text(shelf == .movies || shelf == .series ? "Add sources of videos in Settings." : shelf.empty))
            }
        }
    }

    /// How many tiles a row holds, as laid out.
    @State private var columns = 1
    @FocusState private var focused: Bool

    /// Moves the selection a tile over, or a row up or down, across
    /// `sections` (the movies, then each series' seasons), each laid out in
    /// rows of `columns`: up or down from a section's edge goes to the next
    /// section's nearest row, in the same column or its last.
    private func move(_ direction: MoveCommandDirection, in sections: [[Tile]]) {
        let sections = sections.filter { !$0.isEmpty }
        guard let first = sections.first?.first else { return }
        guard let s = sections.firstIndex(where: { $0.contains { $0.id == selection } }),
              let i = sections[s].firstIndex(where: { $0.id == selection }) else { return select(first) }
        let section = sections[s]
        let column = i % columns
        let target: Tile? = switch direction {
        case .left: i > 0 ? section[i - 1] : s > 0 ? sections[s - 1].last : nil
        case .right: i + 1 < section.count ? section[i + 1] : s + 1 < sections.count ? sections[s + 1].first : nil
        case .up:
            if i >= columns { section[i - columns] }
            else if s > 0, let above = Optional(sections[s - 1]) { above[min((above.count - 1) / columns * columns + column, above.count - 1)] }
            else { nil }
        case .down:
            if i + columns < section.count { section[i + columns] }
            // A last row that's shorter, beneath.
            else if i / columns < (section.count - 1) / columns { section.last }
            else if s + 1 < sections.count { sections[s + 1][min(column, sections[s + 1].count - 1)] }
            else { nil }
        @unknown default: nil
        }
        if let target { select(target) }
    }

    /// Selects a tile, scrolled just enough to be seen, clear of the
    /// toolbar and the status bar.
    private func select(_ tile: Tile) {
        selection = tile.id
        guard let row = layout.row(of: tile.id) else { return }
        let clear = viewport.clear
        if row.y < clear.minY {
            viewport.scroll(&position, by: row.y - clear.minY - Rows.rowSpacing)
        } else if row.maxY > clear.maxY {
            viewport.scroll(&position, by: row.maxY - clear.maxY + Rows.rowSpacing)
        }
    }

    /// Puts a title at the top; the first, with the grid's top margin above
    /// it, as when it was first shown.
    private func scroll(to top: String) {
        guard let row = layout.row(holding: top), row.y > Self.margin else {
            return position.scrollTo(edge: .top)
        }
        // Its top just below the toolbar, as offsets count.
        position.scrollTo(y: row.y)
    }

    /// A tile's width, the same at every grid width, so a change in width
    /// (the inspector opening, say) reflows whole tiles and resizes none.
    nonisolated private static let cell: CGFloat = 148
    nonisolated private static let gutter: CGFloat = 18
    nonisolated private static let margin: CGFloat = 20

    /// How many tiles fit across a grid this wide.
    nonisolated private static func columns(_ width: CGFloat) -> Int {
        max(1, Int((width - 2 * margin + gutter) / (cell + gutter)))
    }

    @ViewBuilder
    private func rowView(_ row: Rows.Row) -> some View {
        if let header = row.header {
            Text(header)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
        } else {
            HStack(alignment: .top, spacing: Self.gutter) {
                ForEach(row.tiles) { tile in
                    // Selecting at once, not after the double-click interval.
                    TileView(tile: tile, aspect: row.aspect, selected: selection == tile.id)
                        .frame(width: Self.cell)
                        .onTapGesture {
                        selection = tile.id
                        focused = true
                    }
                    .simultaneousGesture(TapGesture(count: 2).onEnded { playNext(tile) })
                    .contextMenu {
                        // A movie's download (the version Play plays), as an
                        // episode's is in its row's.
                        if tile.season == nil, let detail = library.detail(tile.key), let target = detail.downloadTarget {
                            DownloadMenuItems(key: target.key, items: target.items, title: tile.key)
                            Divider()
                        }
                        Menu("Add to List") { ListToggles(key: tile.id) }
                        // Unwatched forgets where you stopped, too.
                        if !tile.watched {
                            Button("Mark as Watched") { library.markWatched(tile, true) }
                        }
                        if tile.started {
                            Button("Mark as Unwatched") { library.markWatched(tile, false) }
                        }
                    }
                }
            }
        }
    }

    /// Plays what's next in a tile: a movie, or a season's next unwatched
    /// episode, then the rest of the season.
    private func playNext(_ tile: Tile) {
        selection = tile.id
        guard let detail = library.detail(tile.key), let request = Playback.next(in: detail, season: tile.season) else { return }
        play(request)
    }
}

struct TileView: View {
    let tile: Tile
    let aspect: Double
    let selected: Bool
    @Environment(Library.self) private var library

    /// Between its cover, name, and year, as `CoverGrid.Rows` counts them.
    static let spacing: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            Color.clear
                .aspectRatio(aspect, contentMode: .fit)
                .overlay { CoverImage(cover: tile.cover, thumb: tile.thumb, title: tile.seasonName ?? tile.name, fit: tile.isSeries) }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                // Its copies are all on drives that aren't there.
                .opacity(tile.unavailable ? 0.4 : 1)
                .help(tile.unavailable ? "Unavailable until its drive or share is back" : "")
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: selected ? 3 : 1)
                }
                .overlay(alignment: .top) { CoverMarks(listed: library.isListed(tile), watched: tile.watched) }
                .overlay(alignment: .bottomTrailing) {
                    if library.downloadedTiles.contains(tile.id) {
                        DownloadBadge(symbol: "arrow.down.circle.fill", color: .blue, raised: !tile.watched && tile.progress > 0)
                            .help("Downloaded")
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


/// A cover's download mark, at its bottom trailing corner, above its
/// progress bar if it has one.
private struct DownloadBadge: View {
    let symbol: String
    let color: Color
    let raised: Bool

    var body: some View {
        Image(systemName: symbol)
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, color)
            .font(.title3)
            .shadow(radius: 2)
            .padding(6)
            .padding(.bottom, raised ? 14 : 0)
    }
}

/// What last went wrong, along the bottom of a window, until dismissed or
/// the next action of its kind succeeds: modeless, never an alert.
struct ProblemBar: View {
    @Environment(Library.self) private var library

    var body: some View {
        if let problem = library.problem {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(problem)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Dismiss", systemImage: "xmark") { library.problem = nil }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(.bar)
        }
    }
}

/// Along the bottom of the grid, over it: the shelf's counts, what a long
/// operation is doing and how far it has come, or what went wrong. It fades
/// out a few seconds after it last changed, unless something is running or
/// wrong, or the pointer is near it; floating, so fading moves nothing.
struct StatusBar: View {
    let counts: String
    let hovering: Bool
    @Environment(Library.self) private var library
    @State private var fresh = true
    @AppStorage(Library.showsSyncActivity) private var showsSyncActivity = false

    static let height: CGFloat = 30

    private var sticky: Bool { library.problem != nil || library.activity != nil || hovering }
    private var visible: Bool { fresh || sticky }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                if let problem = library.problem {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    Text(problem).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Button("Dismiss", systemImage: "xmark") { library.problem = nil }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                } else {
                    // Whole, before the line of exchanges, which shortens instead.
                    Text(counts).lineLimit(1).fixedSize()
                }
                Spacer(minLength: 12)
                if let activity = library.activity {
                    Text(Self.describe(activity, library.steps))
                        .lineLimit(1)
                        .monospacedDigit()
                        .layoutPriority(1)
                    if let p = library.steps, p.total > 0 {
                        ProgressView(value: Double(min(p.done, p.total)), total: Double(p.total))
                            .progressViewStyle(.linear)
                            .frame(width: 100)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                } else if library.problem == nil, showsSyncActivity {
                    // The last exchange with devices each way, for diagnosis
                    // (making way for a problem, which matters more).
                    Text(library.syncLine)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: Self.height - 1)
        }
        .background(.bar)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .animation(.easeInOut(duration: 0.6), value: visible)
        // Shown afresh whenever it changes, then faded after a while.
        .task(id: "\(counts)|\(library.problem ?? "")|\(sticky)|\(showsSyncActivity ? "\(library.received?.at ?? .distantPast)|\(library.sent?.at ?? .distantPast)" : "")") {
            fresh = true
            guard !sticky else { return }
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { fresh = false }
        }
    }

    /// "Looking in 3 of 6 sources", "Finding covers for 1,200 of 5,000" (covers and
    /// details found), or what's running ("Looking for new videos").
    static func describe(_ activity: String, _ p: Library.Steps?) -> String {
        guard let p, let phase = p.phase else { return activity + "…" }
        let done = min(p.done + (phase == "describing" ? 0 : 1), p.total).formatted()
        let total = p.total.formatted()
        return switch phase {
        case "crawling": "Looking in \(done) of \(total) \(p.total == 1 ? "source" : "sources")…"
        case "describing": p.total == 0 ? "Finding covers…" : "Finding covers for \(p.done.formatted()) of \(total)…"
        // Catching up, as a refresh does first, says only what it's for.
        case "syncing": activity + "…"
        default: activity + "…"
        }
    }
}
#endif
