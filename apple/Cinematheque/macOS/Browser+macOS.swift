#if os(macOS)
import SwiftUI

extension FocusedValues {
    /// Focuses the library window's search, as Edit › Find does.
    @Entry var find: FindAction?
    /// The library window's shelf's order, as View › Sort By sets it.
    @Entry var shelfOrder: Binding<ShelfOrder>?
    /// Whether the library window's inspector is shown, as View › Show
    /// Inspector sets it.
    @Entry var inspecting: Binding<Bool>?
    /// Whether the Series shelf is shown, for View › Group by Series.
    @Entry var showsSeries: Bool?
    /// Makes a list in the library window, as File › New List does.
    @Entry var newList: NewListAction?
    /// The list the library window shows, if it's this person's, for the
    /// File menu's list items.
    @Entry var shownList: ShownList?
}

/// The list a window shows, of this person's, and what's done to it from
/// the File menu, as its sidebar row's context menu does: so none of it is
/// only in a context menu. Compared by the window and the list as shown.
struct ShownList: Equatable {
    let window: UUID
    let list: UserList
    let rename: () -> Void
    let addMissing: () -> Void

    static func == (a: ShownList, b: ShownList) -> Bool { a.window == b.window && a.list == b.list }
}

/// File's items for the list shown: Add Missing Title…, Rename List, Share
/// List… or Stop Sharing List, and Delete List…; dimmed with none shown.
struct ListCommands: View {
    @FocusedValue(\.shownList) private var shown
    @Environment(Library.self) private var library

    var body: some View {
        Button("Add Missing Title…") { shown?.addMissing() }
            .disabled(shown == nil)
        Button("Rename List") { shown?.rename() }
            .disabled(shown == nil)
        if let list = shown?.list, list.isShared {
            Button("Stop Sharing List") { library.stopSharingList(list.id) }
        } else {
            Button("Share List…") { library.sharingList = shown?.list }
                .disabled(shown == nil)
        }
        Button("Delete List…") { library.deletingList = shown?.list }
            .disabled(shown == nil)
    }
}

/// Making a list in a window: compared by the window it's for, as
/// `FindAction` is.
struct NewListAction: Equatable {
    let window: UUID
    let perform: () -> Void

    func callAsFunction() { perform() }

    static func == (a: NewListAction, b: NewListAction) -> Bool { a.window == b.window }
}

/// File › New List (⇧⌘N, as Notes' New Folder), as the ⊕ at the sidebar's
/// Lists heading.
struct NewListCommand: View {
    @FocusedValue(\.newList) private var newList

    var body: some View {
        Button("New List") { newList?() }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(newList == nil)
    }
}

/// View › Group by Series: the Series shelf's tile per series, opening in
/// place, or every season under its series' name; a checkmark item, as
/// Finder's Use Groups.
struct GroupCommand: View {
    @FocusedValue(\.showsSeries) private var showsSeries
    @AppStorage("groupsSeries") private var groupsSeries = true

    var body: some View {
        // Its state even while dimmed, on another shelf.
        Toggle("Group by Series", isOn: $groupsSeries)
            .disabled(showsSeries != true)
    }
}

/// View › Show Inspector or Hide Inspector (⌃⌘I, as the system's).
struct InspectorCommand: View {
    @FocusedValue(\.inspecting) private var inspecting

    var body: some View {
        Button(inspecting?.wrappedValue == true ? "Hide Inspector" : "Show Inspector") { inspecting?.wrappedValue.toggle() }
            .keyboardShortcut("i", modifiers: [.control, .command])
            .disabled(inspecting == nil)
    }
}

/// View › Sort By: the shown shelf's order (Title, Release Date, Date
/// Added, Date Modified, Date Watched), then its direction, as Finder's.
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

/// The grid's search: AppKit's search field, in a toolbar item of the
/// grid's own, so it stays over the content it searches whether the
/// inspector's open or not (SwiftUI's `searchable` puts it at the window's
/// trailing end, over the inspector while it's shown). Escape clears it, as
/// AppKit's does.
private struct SearchField: NSViewRepresentable {
    @Binding var text: String
    /// Where Find reaches the field, to give it the keys.
    let focus: SearchFocus

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search"
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        focus.field = field
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

/// The search field, for Find to give the keys; not observed.
final class SearchFocus {
    weak var field: NSSearchField?

    func callAsFunction() {
        guard let field else { return }
        field.window?.makeFirstResponder(field)
    }
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
    /// The list a title not in the library yet is being put on, by name.
    @State private var wanting: UserList?
    @AppStorage("orders") private var orders = ShelfOrders()
    @AppStorage("groupsSeries") private var groupsSeries = true
    @State private var search = ""
    /// The search field, which Find (⌘F) gives the keys.
    @State private var searchFocus = SearchFocus()
    /// Watched's titles to forget, once confirmed.
    @State private var forgetting = false
    /// This window's, for its Find action.
    @State private var window = UUID()
    @State private var selection: Tile.ID?
    @State private var inspecting = true
    /// The inspector's width as the person last left it (see `Inspecting`).
    @AppStorage("inspectorWidth") private var inspectorWidth: Double = 360
    /// Whether the sidebar shows: here, not the split view's own, which
    /// the inspector coming and going (`Inspecting`) makes anew.
    @State private var columns: NavigationSplitViewVisibility = .all
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
        .sheet(item: $wanting) { WantSheet.adding(to: $0, in: library) }
        .onChange(of: shelf) { if let shelf { lastShelf = shelf } }
        .onChange(of: library.lists) { if let shelf, !shown(shelf) { self.shelf = .inProgress } }
    }

    private var browser: some View {
        // The shelf's tiles, filtered and ordered once a redraw, not for
        // each that asks.
        let shown = shown
        return NavigationSplitView(columnVisibility: $columns) {
            List(selection: $shelf) {
                ForEach(Self.shelves) { shelf in
                    Label(shelf.title, systemImage: shelf.symbol)
                }
                Section {
                    ForEach(library.lists) { list in
                        ListRow(list: list, renaming: $renaming)
                            .tag(Shelf.list(list.id))
                            .contextMenu {
                                // Another member's is theirs to change.
                                if list.isMine {
                                    Button("Rename") { renaming = list.id }
                                    Button("Add Missing Title…") { wanting = list }
                                    if list.isShared {
                                        Button("Stop Sharing") { library.stopSharingList(list.id) }
                                    } else {
                                        Button("Share…") { library.sharingList = list }
                                    }
                                    Divider()
                                    Button("Delete List…") { library.deletingList = list }
                                }
                            }
                    }
                } header: {
                    // Always shown, where Mail and Photos show theirs as
                    // the pointer nears; named in place, as Notes' New
                    // Folder is.
                    HStack {
                        Text("Lists")
                        Spacer()
                        Button("New List", systemImage: "plus.circle", action: newList)
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("New list")
                    }
                }
            }
            // Bounded, as is the grid below: dragged wider without, it took
            // the grid down to nothing, its own rows sliding out of sight.
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 320)
        } detail: {
            // A scroll view per shelf: one left scrolled past the end of a
            // shorter shelf shows nothing until scrolled.
            CoverGrid(tiles: shown, selection: $selection, shelf: shelf ?? .inProgress, search: search, order: orders[shelf ?? .inProgress], positions: positions, groupsSeries: groupsSeries)
                // Anew as grouping changes too, opening the series selected,
                // and keeping its place by its topmost title.
                .id("\(shelf?.rawValue ?? "") \(groupsSeries)")
                .navigationTitle(shelf?.name(in: library) ?? "Cinematheque")
                // What the window's least width leaves it beside the
                // sidebar and the inspector, its toolbar's room.
                .navigationSplitViewColumnWidth(min: 480, ideal: 640)
                // To the window's edge, faded out before the widest scroll
                // bar's column, so the grid's scroll bar, shown always or
                // while scrolling, runs the window's height through it.
                .overlay(alignment: .bottom) {
                    StatusBar(counts: counts, hovering: nearBottom)
                }
                // Pointing near the bottom brings back a faded status bar.
                .onContinuousHover { phase in
                    let near = if case .active(let point) = phase { point.y > gridHeight - StatusBar.height * 1.5 } else { false }
                    if near != nearBottom { nearBottom = near }
                }
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { _, height in gridHeight = height }
                .focusedSceneValue(\.find, FindAction(window: window) { searchFocus() })
                .focusedSceneValue(\.newList, NewListAction(window: window) { newList() })
                // A tile's Lists › New List…, made here, named in place.
                .onChange(of: library.listPrompt?.id) {
                    guard let prompt = library.listPrompt, case .create(let keys) = prompt.kind else { return }
                    library.listPrompt = nil
                    newList(adding: keys)
                }
                .focusedSceneValue(\.shownList, shownList)
                .focusedSceneValue(\.shelfOrder, $orders[shelf ?? .inProgress])
                .focusedSceneValue(\.inspecting, $inspecting)
                .focusedSceneValue(\.showsSeries, shelf == .series)
                // A shelf's own action, then search, over the grid; and the
                // inspector's toggle at the window's far right while it's
                // hidden, where its own is while it's shown, as Xcode's.
                .toolbar {
                    if shelf == .downloaded {
                        ToolbarItem(placement: .primaryAction) {
                            Button("Show in Finder", systemImage: "folder") {
                                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: library.downloadsDir)
                            }
                            .help("Show in Finder")
                        }
                    }
                    if shelf == .watched {
                        ToolbarItem(placement: .primaryAction) {
                            Button("Forget Watched…", systemImage: "eraser") { forgetting = true }
                                .help("Forget watched titles")
                                .disabled(shown.isEmpty)
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        SearchField(text: $search, focus: searchFocus)
                            .frame(width: 160)
                    }
                    if !inspecting {
                        ToolbarItem(placement: .primaryAction) { inspectorToggle }
                    }
                }
                // Hard to undo: every watched mark, on all this person's
                // devices.
                .confirmationDialog("Forget the titles you've watched?", isPresented: $forgetting) {
                    Button("Forget", role: .destructive) { library.forgetWatched() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Their watched marks are forgotten on all your devices. What you're partway through stays.")
                }
        }
        // Outside the split view, as Apple's own example has it: full
        // height, its toggle at the start of its section of the toolbar,
        // following its divider (an inspector inside the detail column left
        // the toggle astride the divider, whose drag area reaches up into
        // the toolbar and took its clicks). The toggle is the app's, one in
        // each section, only one shown: the system's own came and went
        // between launches.
        // Attached only while shown: hidden, its collapsed divider still
        // took the window's last points, over the grid's scroll bar, and
        // dragging the bar opened it.
        .modifier(Inspecting(shown: $inspecting, width: $inspectorWidth) {
            Group {
                if let tile = library.tiles.first(where: { $0.id == selection }) {
                    InspectorView(tile: tile)
                        .id(tile.id)
                } else if let key = selection, let wanted = library.wanted(key) {
                    // A placeholder, not in the library yet.
                    WantedInspectorView(wanted: wanted) { selection = $0 }
                        .id(key)
                } else if let key = selection, let series = library.perTitle(library.tiles.filter { $0.key == key }).first {
                    // A series, selected by its key on the Series shelf.
                    SeriesInspectorView(series: series) { selection = $0 }
                        .id(key)
                } else {
                    ContentUnavailableView("Choose a Title", systemImage: "film")
                }
            }
            // At the end of its section, the window's far right, where the
            // grid's is while it's hidden.
            .toolbar {
                if inspecting {
                    // Before macOS 26, at its section's start.
                    if #available(macOS 26, *) { ToolbarSpacer(.flexible) }
                    ToolbarItem(placement: .primaryAction) { inspectorToggle }
                }
            }
        })
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

    /// The list shown, if it's this person's, with what the File menu does
    /// to it.
    private var shownList: ShownList? {
        guard case .list(let id) = shelf, let list = library.lists.first(where: { $0.id == id }), list.isMine else { return nil }
        return ShownList(window: window, list: list, rename: { renaming = id }, addMissing: { wanting = list })
    }

    /// Makes a list, "New List" (numbered if that's taken), shows it, and
    /// edits its name in place.
    private func newList() {
        guard let id = makeList() else { return }
        shelf = .list(id)
        renaming = id
    }

    /// Makes a list with `keys` on it (as a tile's Lists › New List… asks)
    /// and edits its name in place in the sidebar, the shelf shown staying,
    /// rather than asking its name in an alert.
    private func newList(adding keys: [String]) {
        guard let id = makeList() else { return }
        for key in keys { library.setListed(key, on: id, true) }
        renaming = id
    }

    /// A new list, "New List" (numbered if that's taken); its ID.
    private func makeList() -> String? {
        let names = Set(library.myLists.map(\.name))
        let name = (1...).lazy.map { $0 == 1 ? "New List" : "New List \($0)" }.first { !names.contains($0) }!
        return library.createList(named: name)
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
/// grid's width would move); and a search's, and the series whose band was
/// closed, so the grid made anew (as the inspector comes and goes) is as it
/// was. Not observed, so scrolling doesn't redraw the view that holds it.
final class ScrollMemory {
    var tops: [Shelf: String] = [:]
    var searched: [Shelf: (search: String, top: String)] = [:]
    var closed: [Shelf: String] = [:]

    /// The topmost title to return to on `shelf`, as `search` shows it.
    func top(_ shelf: Shelf, search: String) -> String? {
        if search.isEmpty { return tops[shelf] }
        guard let s = searched[shelf], s.search == search else { return nil }
        return s.top
    }

    func note(_ top: String?, _ shelf: Shelf, search: String) {
        if search.isEmpty { tops[shelf] = top } else { searched[shelf] = top.map { (search, $0) } }
    }
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
                Image(systemName: symbol)
            }
        } else {
            Label(list.shownName, systemImage: symbol)
        }
    }

    /// A shared list's, this person's or another's, is of people.
    private var symbol: String { list.isShared ? UserList.sharedSymbol : Shelf.list(list.id).symbol }

    /// The name typed, unless it's blank or the same, once.
    private func keep() {
        guard renaming == list.id else { return }
        renaming = nil
        let typed = name.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty, typed != list.name { library.renameList(list.id, to: typed) }
    }
}

/// Tiles of fixed size: movies' covers 2:3, and each series' seasons
/// together, square; on the Series shelf, a tile per series, the one
/// selected open below its row, its seasons in a band pointing up at it
/// (an inline expansion). As a cell's size is fixed, every row's place and
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
    /// Whether the Series shelf shows a tile per series (View › Group by
    /// Series).
    var groupsSeries = true
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
    /// The Series shelf's series selected, open (unless `collapsed`) to
    /// show its seasons, the selection one of them.
    @State private var pointed: String?
    @State private var collapsed = false
    /// How far a band opening, and one closing, move as they come and go:
    /// as far as their series' rows do, so each moves with its row, as a
    /// view coming or going isn't moved by its row's offset.
    @State private var bandEnter: CGFloat = 0
    @State private var bandLeave: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The selection as the keys last left it, or as it last changed: a
    /// key's handler read the binding as it was a while before.
    @State private var current: Tile.ID?

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
        /// The scroll view showing the grid, for scrolling it smoothly, as
        /// `ScrollPosition` scrolls at once, even in an animation.
        weak var scrollView: NSScrollView?
        /// Scrolls by `delta` over `duration`, eased; false if it can't.
        @MainActor func glide(by delta: CGFloat, over duration: TimeInterval) -> Bool {
            guard let scrollView, let document = scrollView.documentView else { return false }
            let clip = scrollView.contentView
            var bounds = clip.bounds
            bounds.origin.y += document.isFlipped ? delta : -delta
            let origin = clip.constrainBoundsRect(bounds).origin
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                clip.animator().setBoundsOrigin(origin)
            }
            return true
        }
    }

    /// Finds the scroll view it's in, for `Viewport.glide`.
    private struct ScrollViewFinder: NSViewRepresentable {
        let viewport: Viewport

        func makeNSView(context: Context) -> Finder { Finder(viewport) }
        func updateNSView(_ view: Finder, context: Context) {}

        final class Finder: NSView {
            private weak var viewport: Viewport?
            init(_ viewport: Viewport) {
                self.viewport = viewport
                super.init(frame: .zero)
            }
            required init?(coder: NSCoder) { nil }
            override func viewDidMoveToWindow() {
                viewport?.scrollView = enclosingScrollView
            }
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
    /// then each series' name and its seasons' rows; or the Series shelf's
    /// rows of series, the open one's band of seasons after its row.
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
            /// A band of an open series' seasons: the column its series is
            /// in, which it points at.
            var band: Int? = nil
            var maxY: CGFloat { y + height }
        }

        var rows: [Row] = []
        var movies: [Tile] = []
        var groups: [Group] = []
        /// The Series shelf's tiles, a series' each, and the open one's
        /// seasons.
        var series: [Tile] = []
        var seasons: [Tile] = []
        /// The whole grid's, its margins too.
        var height: CGFloat = 0
        /// What of the room kept at the end for the tallest band no band
        /// takes, said to be left blank on purpose.
        var blank: CGFloat = 0

        init() {}

        /// The Series shelf's: a row of series at a time, and after the
        /// open one's row, its band.
        /// The height is the same whichever band is open, or none: room is
        /// kept at the end for the tallest (`most` seasons), so the scroll
        /// bar holds still as bands open and close.
        init(series: [Tile], open: String?, seasons: [Tile], most: Int, columns: Int) {
            self.series = series
            var y = CoverGrid.margin
            for start in stride(from: 0, to: series.count, by: columns) {
                let row = Array(series[start..<min(start + columns, series.count)])
                rows.append(Row(id: "series/\(start)", header: nil, tiles: row, aspect: 1, key: row[0].key, y: y, height: Self.seriesHeight))
                y += Self.seriesHeight
                if let open, let column = row.firstIndex(where: { $0.key == open }), !seasons.isEmpty {
                    self.seasons = seasons
                    y += Self.bandGap
                    let height = Self.bandHeight(seasons.count, columns: columns)
                    rows.append(Row(id: "band/\(open)", header: nil, tiles: seasons, aspect: 1, key: open, y: y, height: height, band: column))
                    y += height
                }
                y += Self.rowSpacing
            }
            let open = rows.first { $0.band != nil }.map { Self.bandGap + $0.height } ?? 0
            let tallest = most > 1 ? Self.bandGap + Self.bandHeight(most, columns: columns) : 0
            height = rows.isEmpty ? 0 : y - Self.rowSpacing + CoverGrid.margin - open + tallest
            blank = rows.isEmpty ? 0 : tallest - open
        }

        /// A band's: its point, its padding, and its seasons' rows.
        static func bandHeight(_ count: Int, columns: Int) -> CGFloat {
            let lines = CGFloat((count + columns - 1) / columns)
            return bandNotch + 2 * bandPadding + lines * seasonHeight + (lines - 1) * rowSpacing
        }

        /// Where a season in a band is, top and bottom.
        func span(inBand tile: Tile.ID, columns: Int) -> (y: CGFloat, maxY: CGFloat)? {
            guard let band = rows.first(where: { $0.band != nil }), let i = band.tiles.firstIndex(where: { $0.id == tile }) else { return nil }
            let y = band.y + Self.bandNotch + Self.bandPadding + CGFloat(i / columns) * (Self.seasonHeight + Self.rowSpacing)
            return (y, y + Self.seasonHeight)
        }

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
            rows.first { $0.band == nil && $0.tiles.contains { $0.id == tile } }
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
        // A series' cover, name, and how many seasons it has (or, of one,
        // which).
        static let seriesHeight = CoverGrid.cell + TileView.spacing + line(.callout) + TileView.spacing + line(.caption1)
        static let bandGap: CGFloat = 6
        static let bandNotch: CGFloat = 10
        static let bandPadding: CGFloat = 14
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
        private var open: String?
        private var rows = Rows()
        /// The Series shelf's tile per series, and each series' seasons, in
        /// order, made again only when the tiles change, not as bands open.
        private(set) var series: [Tile] = []
        private(set) var seasons: [String: [Tile]] = [:]
        private var grouped: [Tile]?

        /// With `series`, the Series shelf's, a tile per series, `open`
        /// open.
        @MainActor func rows(_ tiles: [Tile], columns: Int, series: Bool, open: String?, library: Library) -> Rows {
            if columns != self.columns || tiles != self.tiles || open != self.open {
                if series, grouped != tiles {
                    grouped = tiles
                    self.series = library.perTitle(tiles)
                    let keys = Set(self.series.map(\.key))
                    seasons = Dictionary(grouping: library.tiles.filter { $0.season != nil && keys.contains($0.key) }, by: \.key)
                        .mapValues { list in
                            let sorted = list.sorted { ($0.season ?? 0) < ($1.season ?? 0) }
                            return sorted.filter { $0.season != 0 } + sorted.filter { $0.season == 0 }
                        }
                }
                self.tiles = tiles
                self.columns = columns
                self.open = open
                if series {
                    let band = open.flatMap { seasons[$0] } ?? []
                    rows = Rows(series: self.series, open: open, seasons: band.count > 1 ? band : [], most: seasons.values.map(\.count).max() ?? 0, columns: columns)
                } else {
                    rows = Rows(tiles, columns: columns)
                }
            }
            return rows
        }
    }

    /// Whether it's the Series shelf, of a tile per series.
    private var bySeries: Bool { shelf == .series && groupsSeries }

    /// The open series: the one selected, unless collapsed.
    private var open: String? { bySeries && !collapsed ? pointed : nil }

    /// The series whose band is shown (not one of a single season).
    private var shownOpen: String? { layout.seasons.isEmpty ? nil : open }

    private var layout: Rows { cache.rows(tiles, columns: columns, series: bySeries, open: open, library: library) }

    var body: some View {
        let layout = layout
        // A screen's worth above and below what's on it, drawn ahead.
        let drawn = layout.range(viewport.rect.minY - viewport.rect.height, viewport.rect.maxY + viewport.rect.height)
        ScrollView {
            ZStack(alignment: .topLeading) {
                ForEach(layout.rows[drawn]) { row in
                    rowView(row)
                        .frame(height: row.height, alignment: .topLeading)
                        .background(alignment: .topLeading) { backing(row) }
                        .offset(x: Self.margin, y: row.y)
                }
                // The room kept for the tallest band, where none takes it:
                // said, so it doesn't look like the grid failed to load.
                if layout.blank >= 120 {
                    Text("This space is intentionally left blank.")
                        .font(.callout)
                        .italic()
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .frame(height: layout.blank - CoverGrid.margin)
                        .offset(y: layout.height - layout.blank)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, minHeight: layout.height, maxHeight: layout.height, alignment: .topLeading)
            .background(ScrollViewFinder(viewport: viewport))
        }
        .background(Self.background)
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
        // As key presses, as the scroll view took the arrows' move
        // commands before `onMoveCommand` saw them.
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            let direction: MoveCommandDirection = switch press.key {
            case .leftArrow: .left
            case .rightArrow: .right
            case .upArrow: .up
            default: .down
            }
            if bySeries { moveBySeries(direction) } else { move(direction, in: [layout.movies] + layout.groups.map(\.seasons)) }
            return .handled
        }
        .onChange(of: selection, initial: true) { current = selection }
        // Closes the open series, as clicking it again does.
        .onKeyPress(.escape) {
            guard bySeries, shownOpen != nil else { return .ignored }
            close()
            return .handled
        }

        .onKeyPress(.return) {
            if bySeries, let key = current, layout.series.contains(where: { $0.key == key }) {
                playSeries(key)
                return .handled
            }
            guard let tile = tiles.first(where: { $0.id == current }) ?? library.tiles.first(where: { $0.id == current }) else { return .ignored }
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
            // The series of a season selected on another shelf, open.
            // A season's, or one selected by its key.
            if bySeries, let key = library.tiles.first(where: { $0.id == selection })?.key ?? selection, library.tiles.contains(where: { $0.key == key && $0.isSeries }) {
                pointed = key
                // Unless it was closed, its tile selected.
                collapsed = positions.closed[shelf] == key
            }
            // After the first layout, which ignores scrolling.
            await Task.yield()
            if let top = positions.top(shelf, search: search) { scroll(to: top) }
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
            if restored { positions.note(top, shelf, search: search) }
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
        guard let s = sections.firstIndex(where: { $0.contains { $0.id == current } }),
              let i = sections[s].firstIndex(where: { $0.id == current }) else { return select(first) }
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
        current = tile.id
        guard let row = layout.row(of: tile.id) else { return }
        reveal(row.y, row.maxY)
    }

    /// Scrolls just enough to show a span, clear of the toolbar and the
    /// status bar, its top first if it doesn't fit (a series' row, over
    /// its band), smoothly if `gliding` (but under Reduce Motion).
    private func reveal(_ y: CGFloat, _ maxY: CGFloat, gliding: Bool = false) {
        let clear = viewport.clear
        let delta: CGFloat
        if y < clear.minY {
            delta = y - clear.minY - Rows.rowSpacing
        } else if maxY > clear.maxY {
            delta = min(maxY - clear.maxY + Rows.rowSpacing, y - clear.minY - Rows.rowSpacing)
        } else {
            return
        }
        if gliding, !reduceMotion, viewport.glide(by: delta, over: Self.bandDuration) { return }
        viewport.scroll(&position, by: delta)
    }

    /// Selects a series on the Series shelf, by its key, opening it (but
    /// one of a single season, which is its tile, that season selected),
    /// then scrolled to show it. As another's band above it closes, it moves
    /// up with it, as in the web client's flow.
    private func point(_ series: Tile) {
        let old = layout
        let seasons = cache.seasons[series.key] ?? Library.seasons(of: series.key, in: library.tiles)
        let id = seasons.count == 1 ? seasons[0].id : series.key
        selection = id
        current = id
        // Where the rows go with it open: its band comes in from as far off
        // as its row moves, and the band closing goes as far as its own.
        let next = cache.rows(tiles, columns: columns, series: bySeries, open: series.key, library: library)
        func moved(_ key: String) -> CGFloat {
            guard let from = old.row(holding: key), let to = next.row(holding: key) else { return 0 }
            return to.y - from.y
        }
        let enter = -moved(series.key)
        leaving(shownOpen.map(moved) ?? 0) {
            bandEnter = enter
            // The band fading in (another's out), the series after it moving
            // off it; then scrolling, as a scroll with them came before them.
            positions.closed[shelf] = nil
            withAnimation(bandMotion) {
                pointed = series.key
                collapsed = false
            } completion: {
                guard let row = layout.row(holding: series.key) else { return }
                let band = layout.rows.first { $0.band != nil }
                reveal(row.y, band?.maxY ?? row.maxY, gliding: true)
            }
        }
    }

    /// Sets how far the band closing moves, then makes `change`: a view
    /// leaving takes its transition from how it was last drawn, so it's
    /// drawn with it first.
    private func leaving(_ distance: CGFloat, then change: @escaping () -> Void) {
        guard distance != bandLeave else { return change() }
        bandLeave = distance
        Task { change() }
    }

    /// Closes the open series, selecting its tile.
    private func close() {
        if let open = shownOpen {
            selection = open
            current = open
            positions.closed[shelf] = open
        }
        // Fading where it is, its row not moving.
        leaving(0) { withAnimation(bandMotion) { collapsed = true } }
    }

    /// How a band opens and closes: none under Reduce Motion.
    private var bandMotion: Animation? { reduceMotion ? nil : .easeInOut(duration: Self.bandDuration) }
    nonisolated private static let bandDuration: TimeInterval = 0.25

    /// Selects a season in the open series' band, scrolled into view.
    private func selectInBand(_ season: Tile) {
        selection = season.id
        current = season.id
        if let span = layout.span(inBand: season.id, columns: columns) { reveal(span.y, span.maxY) }
    }

    /// The Series shelf's keys, over one selection: over the series, each
    /// opening as it's reached; down from the open one into its band, over
    /// its seasons, out of its ends to the series beside its own, and out
    /// of its top or bottom to the series above or below.
    private func moveBySeries(_ direction: MoveCommandDirection) {
        let series = layout.series
        guard let first = series.first else { return }
        let key = library.tiles.first { $0.id == current }?.key ?? current
        guard let i = series.firstIndex(where: { $0.key == key }) else { return point(first) }
        let above = i >= columns ? series[i - columns] : nil
        let below: Tile? = i / columns < (series.count - 1) / columns ? series[min(i + columns, series.count - 1)] : nil
        let seasons = layout.seasons
        if shownOpen == key, let j = seasons.firstIndex(where: { $0.id == current }) {
            switch direction {
            case .left: if j > 0 { selectInBand(seasons[j - 1]) } else if i > 0 { point(series[i - 1]) }
            case .right: if j + 1 < seasons.count { selectInBand(seasons[j + 1]) } else if i + 1 < series.count { point(series[i + 1]) }
            case .up:
                if j >= columns {
                    selectInBand(seasons[j - columns])
                } else {
                    // The series just above, in its own series' row: its
                    // own, or another beside it.
                    point(series[min(i / columns * columns + j % columns, series.count - 1)])
                }
            case .down:
                if j + columns < seasons.count { selectInBand(seasons[j + columns]) }
                else if j / columns < (seasons.count - 1) / columns { selectInBand(seasons[seasons.count - 1]) }
                else if below != nil { point(series[min((i / columns + 1) * columns + j % columns, series.count - 1)]) }
            @unknown default: break
            }
            return
        }
        switch direction {
        case .left: if i > 0 { point(series[i - 1]) }
        case .right: if i + 1 < series.count { point(series[i + 1]) }
        case .up: if let above { point(above) }
        case .down:
            // Into its band, the season beneath it.
            if shownOpen == key, !seasons.isEmpty { selectInBand(seasons[min(i % columns, seasons.count - 1)]) }
            else if let below { point(below) }
        @unknown default: break
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
    nonisolated fileprivate static let cell: CGFloat = 148
    nonisolated private static let gutter: CGFloat = 18
    nonisolated private static let margin: CGFloat = 20
    /// The grid's background, opaque, as rows cover a band with it.
    private static let background = Color(nsColor: .textBackgroundColor)

    /// The width of a row of `columns` tiles.
    private var rowWidth: CGFloat { CGFloat(columns) * (Self.cell + Self.gutter) - Self.gutter }

    /// On the Series shelf, a row of series' background, from the gap above
    /// it down, covering a band before it (as later rows are drawn over
    /// earlier ones): so the series after a band slide off it as it opens,
    /// showing it from its top down, and back over it as it closes.
    @ViewBuilder
    private func backing(_ row: Rows.Row) -> some View {
        if bySeries, row.band == nil, row.header == nil {
            Self.background
                .frame(width: rowWidth + 2 * Self.margin, height: row.height + Rows.rowSpacing)
                .offset(x: -Self.margin, y: -Rows.rowSpacing)
        }
    }

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
        } else if let column = row.band {
            band(row.tiles, pointingAt: column)
                // Fading as one, not each season and the tint apart; coming
                // and going as far off as its series' row moves.
                .compositingGroup()
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: bandEnter)), removal: .opacity.combined(with: .offset(y: bandLeave))))
        } else if bySeries {
            HStack(alignment: .top, spacing: Self.gutter) {
                ForEach(row.tiles) { series in
                    seriesTile(series)
                }
            }
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
                    .contextMenu { tileMenu(tile) }
                }
            }
        }
    }

    /// A movie's or a season's context menu.
    @ViewBuilder
    private func tileMenu(_ tile: Tile) -> some View {
        // A placeholder's: taken off its lists, as there's nothing else to it.
        if tile.isWanted {
            if library.isWantedByMe(tile.id) { Button("Remove from List") { library.unwant(tile.id) } }
        } else {
            titleMenu(tile)
        }
    }

    @ViewBuilder
    private func titleMenu(_ tile: Tile) -> some View {
        // A movie's download (the version Play plays), as an episode's is
        // in its row's.
        if tile.season == nil, let detail = library.detail(tile.key), let target = detail.downloadTarget {
            DownloadMenuItems(key: target.key, items: target.items, title: tile.key)
            Divider()
        }
        Menu("Lists") { ListToggles(key: tile.id) }
        // Unwatched forgets where you stopped, too.
        if !tile.watched {
            Button("Mark as Watched") { library.markWatched(tile, true) }
        }
        if tile.started {
            Button("Mark as Unwatched") { library.markWatched(tile, false) }
        }
    }

    /// A series' tile on the Series shelf: its cover, its name, and how
    /// many seasons it has; selected, it's open.
    private func seriesTile(_ series: Tile) -> some View {
        let seasons = cache.seasons[series.key] ?? []
        let count = seasons.count
        // Selected itself, or, of one season, that season.
        let selected = selection == series.key || (count == 1 && seasons[0].id == selection)
        // Named for its series, as every series' is, and under it what its
        // seasons come to.
        let caption = Library.seasonsCaption(seasons)
        return TileView(tile: series, aspect: 1, selected: selected, stands: .series(caption: caption))
            .frame(width: Self.cell)
            .onTapGesture {
                focused = true
                // Clicked again, selected and open, it closes.
                if shownOpen == series.key, selection == series.key { close() } else { point(series) }
            }
            .simultaneousGesture(TapGesture(count: 2).onEnded { playSeries(series.key) })
            .contextMenu {
                if count == 1 {
                    // Its one season's, Lists too, as the tile is that
                    // season.
                    tileMenu(seasons[0])
                } else {
                    // The whole series'; its seasons' lists are theirs.
                    if !series.watched {
                        Button("Mark as Watched") { library.markSeriesWatched(series, true) }
                    }
                    if series.started {
                        Button("Mark as Unwatched") { library.markSeriesWatched(series, false) }
                    }
                }
            }
    }

    /// An open series' seasons, in rows of the grid's columns, on a band
    /// of their own that points up at the series.
    private func band(_ seasons: [Tile], pointingAt column: Int) -> some View {
        let inset: CGFloat = 10
        let width = rowWidth
        let lines = stride(from: 0, to: seasons.count, by: columns).map { Array(seasons[$0..<min($0 + columns, seasons.count)]) }
        return VStack(alignment: .leading, spacing: Rows.rowSpacing) {
            ForEach(lines, id: \.first!.id) { line in
                HStack(alignment: .top, spacing: Self.gutter) {
                    ForEach(line) { season in
                        TileView(tile: season, aspect: 1, selected: selection == season.id)
                            .frame(width: Self.cell)
                            .onTapGesture {
                                selection = season.id
                                focused = true
                            }
                            .simultaneousGesture(TapGesture(count: 2).onEnded { playNext(season) })
                            .contextMenu { tileMenu(season) }
                    }
                }
            }
        }
        .padding(.top, Rows.bandNotch + Rows.bandPadding)
        .padding(.bottom, Rows.bandPadding)
        .padding(.horizontal, inset)
        .frame(width: width + 2 * inset, alignment: .topLeading)
        .background {
            Band(notch: inset + CGFloat(column) * (Self.cell + Self.gutter) + Self.cell / 2, depth: Rows.bandNotch)
                .fill(Color.primary.opacity(0.07))
        }
        .offset(x: -inset)
    }

    /// Plays a series' season to watch, from its next episode, the series
    /// still selected.
    private func playSeries(_ key: String) {
        guard let season = Library.nextSeason(cache.seasons[key] ?? Library.seasons(of: key, in: library.tiles)),
              let detail = library.detail(key), let request = Playback.next(in: detail, season: season.season) else { return }
        play(request)
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
    /// What the tile stands for: a movie or a season itself, or a whole
    /// series, with what its seasons come to under its name (how many, or,
    /// of one but the first, which; empty, nothing to say, its line kept
    /// either way).
    enum Stands { case itself, series(caption: String) }
    var stands: Stands = .itself
    @Environment(Library.self) private var library

    /// A series' caption, if it stands for one.
    private var caption: String? { if case .series(let caption) = stands { caption } else { nil } }
    private var isSeries: Bool { caption != nil }

    /// Between its cover, name, and year, as `CoverGrid.Rows` counts them.
    static let spacing: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            Color.clear
                .aspectRatio(aspect, contentMode: .fit)
                .overlay { CoverImage(cover: tile.cover, thumb: tile.thumb, title: isSeries ? tile.name : tile.seasonName ?? tile.name, fit: tile.isSeries) }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                // Its copies are all on drives that aren't there, or it's a
                // placeholder, not in the library yet.
                .opacity(tile.unavailable || tile.isWanted ? 0.4 : 1)
                .help(tile.isWanted ? "Not in the library yet" : tile.unavailable ? "Unavailable until its drive or share is back" : "")
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: selected ? 3 : 1)
                }
                .overlay(alignment: .bottom) { CoverProgress(tile: tile) }
                .shadow(color: .black.opacity(0.15), radius: 3, y: 2)
            let name = isSeries ? tile.name : tile.seasonName ?? tile.name
            if caption == "", let year = tile.year {
                // A series whose second line says nothing: its year beside
                // its name, if an em's space is left between them, its
                // second line still kept, so rows line up; else below.
                ViewThatFits(in: .horizontal) {
                    VStack(alignment: .leading, spacing: Self.spacing) {
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text(name).font(.callout).fixedSize()
                            Spacer(minLength: Self.em)
                            Text(String(year)).font(.caption).foregroundStyle(.secondary).fixedSize()
                            marks.padding(.leading, 4).fixedSize()
                        }
                        Text(" ").font(.caption)
                    }
                    VStack(alignment: .leading, spacing: Self.spacing) {
                        nameRow(name)
                        HStack {
                            Spacer(minLength: 4)
                            Text(String(year))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            } else {
                nameRow(name)
            }
            if let caption, caption != "" || tile.year == nil {
                // Its year, if its name has one, at the line's end, so the
                // seasons said before it read alike with it or without.
                HStack {
                    Text(caption)
                    Spacer(minLength: 4)
                    if let year = tile.year { Text(String(year)) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            } else if tile.season == nil, tile.isWanted {
                // A placeholder's, in the year's place.
                Text("Not in library")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if tile.season == nil, let year = tile.year {
                Text(String(year))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    /// The marks, at the name line's end, so the name and they span the
    /// cover's width; a series' listed if any of its seasons is.
    private var marks: TileMarks {
        TileMarks(listed: isSeries ? library.isAnySeasonListed(tile) : library.isListed(tile), watched: tile.watched, downloaded: !isSeries && library.downloadedTiles.contains(tile.id))
    }

    /// A name's line with its marks at the end.
    private func nameRow(_ name: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            nameLine(name)
            Spacer(minLength: 0)
            marks.font(.callout).fixedSize()
        }
    }

    /// A name's line, its whole name as help only where it's cut short,
    /// as help says only what can't be seen.
    private func nameLine(_ name: String) -> some View {
        // Whichever fits shown at once, not faded in or out apart from its
        // tile (as in a band opening or closing, whose captions came late,
        // or went first).
        ViewThatFits(in: .horizontal) {
            Text(name).fixedSize().transition(.identity)
            Text(name).lineLimit(1).help(name).transition(.identity)
        }
        .font(.callout)
    }

    /// An em of the name's font, the least space left between a name and
    /// a year beside it.
    private static let em = NSFont.preferredFont(forTextStyle: .callout).pointSize
}

/// A band's shape: a rounded rectangle with a point at its top, at
/// `notch` across, `depth` high, pointing up at what it opened from.
nonisolated private struct Band: Shape {
    let notch: CGFloat
    let depth: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: CGRect(x: rect.minX, y: rect.minY + depth, width: rect.width, height: rect.height - depth), cornerRadius: 10)
        path.move(to: CGPoint(x: notch - depth * 1.2, y: rect.minY + depth + 0.5))
        path.addLine(to: CGPoint(x: notch, y: rect.minY))
        path.addLine(to: CGPoint(x: notch + depth * 1.2, y: rect.minY + depth + 0.5))
        path.closeSubpath()
        return path
    }
}

/// The inspector, attached only while shown, so no collapsed divider is
/// left to grab.
private struct Inspecting<Inspector: View>: ViewModifier {
    @Binding var shown: Bool
    /// Its width, as the person last left it, given back as its ideal
    /// whenever it's attached, as SwiftUI keeps one dragged only till then.
    @Binding var width: Double
    @ViewBuilder let inspector: () -> Inspector

    func body(content: Content) -> some View {
        if shown {
            // Its width set here: set on the content's own views, SwiftUI
            // ignored it, opening it at its default width.
            content.inspector(isPresented: $shown) {
                inspector()
                    // Measured filling the column, as what's in it may be
                    // narrower (Choose a Title is at most 400 points).
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onGeometryChange(for: Double.self) { $0.size.width } action: { new in
                        let rounded = new.rounded() // A write a point, not a frame.
                        if rounded >= 300, rounded <= 520, rounded != width { width = rounded }
                    }
                    .inspectorColumnWidth(min: 300, ideal: width, max: 520)
            }
        } else {
            content
        }
    }
}
#endif
