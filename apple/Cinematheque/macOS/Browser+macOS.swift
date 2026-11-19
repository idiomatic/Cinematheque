#if os(macOS)
import SwiftUI

/// The library as a grid of covers: movies, and series by season, filtered
/// by shelf and search, beside an inspector for the one selected.
struct Browser: View {
    /// The shelves in the sidebar.
    static let shelves: [Shelf] = [.movies, .series, .watchlist, .inProgress, .watched, .downloaded]

    @Environment(Library.self) private var library
    /// The shelf shown last, again at launch; at first, In Progress.
    @AppStorage("shelf") private var lastShelf: Shelf = .inProgress
    @State private var shelf: Shelf?
    @State private var search = ""
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
            // One the sidebar has no longer (another build's) gives way.
            if shelf == nil { shelf = Self.shelves.contains(lastShelf) ? lastShelf : .inProgress }
        }
        .onChange(of: shelf) { if let shelf { lastShelf = shelf } }
    }

    private var browser: some View {
        NavigationSplitView {
            List(Self.shelves, selection: $shelf) { shelf in
                Label(shelf.title, systemImage: shelf.symbol)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            // A scroll view per shelf: one left scrolled past the end of a
            // shorter shelf shows nothing until scrolled.
            CoverGrid(tiles: shown, selection: $selection, shelf: shelf ?? .inProgress, search: search, positions: positions)
                .id(shelf)
                .navigationTitle(shelf?.title ?? "Cinematheque")
                .overlay(alignment: .bottom) { StatusBar(counts: counts, hovering: nearBottom) }
                // Pointing near the bottom brings back a faded status bar.
                .onContinuousHover { phase in
                    let near = if case .active(let point) = phase { point.y > gridHeight - StatusBar.height * 1.5 } else { false }
                    if near != nearBottom { nearBottom = near }
                }
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { _, height in gridHeight = height }
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
            if let id = Launch.selection {
                selection = id
                // On the shelf it's on, whatever was shown last.
                shelf = id.contains("#") ? .series : .movies
            }
            if let url = Launch.play.flatMap(URL.init(string:)) { playing = PlayRequest(url: url, item: Launch.item ?? "", start: 0) }
        }
        #endif
    }

    private var inspectorToggle: some View {
        Button(inspecting ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.trailing") { inspecting.toggle() }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .help(inspecting ? "Hide the inspector" : "Show the inspector")
    }

    private var shown: [Tile] { (shelf ?? .inProgress).tiles(in: library, search: search) }

    private var counts: String { (shelf ?? .inProgress).counts(in: library, search: search) }
}

/// Tiles of fixed size, laid out lazily: movies' covers 2:3, and each
/// series' seasons together, square.
/// Each shelf's topmost title in view, to return to: a movie's tile or a
/// series' seasons, by title key (not an offset, which a change in the
/// grid's width would move). Not observed, so scrolling doesn't redraw the
/// view that holds it.
final class ScrollMemory {
    var tops: [Shelf: String] = [:]
}

struct CoverGrid: View {
    let tiles: [Tile]
    @Binding var selection: Tile.ID?
    let shelf: Shelf
    let search: String
    let positions: ScrollMemory
    @State private var position = ScrollPosition(edge: .top)
    /// Whether the shelf's place has been restored, before which the grid's
    /// first layout (at the top) isn't recorded over it.
    @State private var restored = false
    @Environment(Library.self) private var library
    @Environment(\.play) private var play
    /// Tiles at least half on screen, whose titles a crawl describes first,
    /// and the first of which the grid keeps in place.
    @State private var visible: Set<Tile.ID> = []
    /// The title at the top, kept there when the grid's width changes (as
    /// when the inspector opens or closes) and its rows reflow.
    @State private var anchor = Anchor()

    /// Not observed, so recording it doesn't redraw the grid.
    final class Anchor {
        var top: String?
    }

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
        .scrollPosition($position)
        // The last row clears the status bar floating over the grid.
        .contentMargins(.bottom, StatusBar.height, for: .scrollContent)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { _, _ in
            if let top = anchor.top { scroll(to: top) }
        }
        .task {
            // After the first layout, which ignores scrolling.
            await Task.yield()
            if search.isEmpty, let top = positions.tops[shelf] { scroll(to: top) }
            restored = true
        }
        // A new search starts at the top, which its results may not reach.
        .onChange(of: search) { position.scrollTo(edge: .top) }
        // Once scrolling settles.
        .task(id: visible) {
            try? await Task.sleep(for: .milliseconds(200))
            // A tile's ID is its title's key, then `#` and a season for a
            // series' season.
            guard !Task.isCancelled else { return }
            library.prioritize(Set(visible.map { String($0.split(separator: "#")[0]) }))
            let top = tiles.first { visible.contains($0.id) }?.key
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

    /// Puts a title at the top; the first, with the grid's top margin above
    /// it, as when it was first shown.
    private func scroll(to top: String) {
        if top == tiles.first?.key {
            position.scrollTo(edge: .top)
        } else {
            position.scrollTo(id: top, anchor: .top)
        }
    }

    private func grid(_ tiles: [Tile], aspect: Double) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 18, alignment: .top)], alignment: .leading, spacing: 22) {
            ForEach(tiles) { tile in
                // Selecting at once, not after the double-click interval.
                TileView(tile: tile, aspect: aspect, selected: selection == tile.id)
                    .onScrollVisibilityChange(threshold: 0.5) { shown in
                        if shown { visible.insert(tile.id) } else { visible.remove(tile.id) }
                    }
                    // A lazy grid drops a tile it scrolls far past without
                    // saying it's no longer visible.
                    .onDisappear { visible.remove(tile.id) }
                    .onTapGesture { selection = tile.id }
                    .simultaneousGesture(TapGesture(count: 2).onEnded { playNext(tile) })
                    .contextMenu {
                        // Forgets its playheads (positions and watched marks).
                        if tile.played {
                            Button(shelf == .watched ? "Remove from Watched" : shelf == .inProgress ? "Remove from In Progress" : "Mark as Unwatched") { library.removeFromPlayed(tile) }
                        }
                    }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(aspect, contentMode: .fit)
                .overlay { CoverImage(cover: tile.cover, thumb: tile.thumb, title: tile.seasonName ?? tile.name, fit: tile.isSeries) }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                // Its copies are all on drives that aren't there.
                .opacity(tile.absent ? 0.4 : 1)
                .help(tile.absent ? "Unavailable: its copies are on a drive that isn't connected" : "")
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: selected ? 3 : 1)
                }
                .overlay(alignment: .top) { CoverMarks(listed: library.isListed(tile), watched: tile.watched) }
                .overlay(alignment: .bottomTrailing) {
                    if let waiting = library.watchedTiles[tile.id] {
                        DownloadBadge(symbol: waiting ? "hourglass.circle.fill" : "exclamationmark.circle.fill", color: waiting ? .gray : .orange, raised: !tile.watched && tile.progress > 0)
                            .help(waiting ? "Watched: deleted when its space is needed, as another source has it" : "Watched, and the only copy: delete it, or keep it")
                    } else if library.downloadedTiles.contains(tile.id) {
                        DownloadBadge(symbol: "arrow.down.circle.fill", color: .blue, raised: !tile.watched && tile.progress > 0)
                            .help("Downloaded to this Mac")
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
                    Text(Self.describe(activity, library.progress))
                        .lineLimit(1)
                        .monospacedDigit()
                        .layoutPriority(1)
                    if let p = library.progress, p.total > 0 {
                        ProgressView(value: Double(min(p.done, p.total)), total: Double(p.total))
                            .progressViewStyle(.linear)
                            .frame(width: 100)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                } else if library.problem == nil {
                    // The last exchange with peers each way, for diagnosis
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
        .task(id: "\(counts)|\(library.problem ?? "")|\(sticky)|\(library.received?.at ?? .distantPast)|\(library.sent?.at ?? .distantPast)") {
            fresh = true
            guard !sticky else { return }
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { fresh = false }
        }
    }

    /// "Looking in 3 of 6 sources", "Covers 1,200 of 5,000" (covers and
    /// details found), "Catching up with 1 of 2 devices", or what's running.
    static func describe(_ activity: String, _ p: Library.Progress?) -> String {
        guard let p, let phase = p.phase else { return activity + "…" }
        let done = min(p.done + (phase == "describing" ? 0 : 1), p.total).formatted()
        let total = p.total.formatted()
        return switch phase {
        case "crawling": "Looking in \(done) of \(total) \(p.total == 1 ? "source" : "sources")…"
        case "describing": p.total == 0 ? "Covers…" : "Covers \(p.done.formatted()) of \(total)"
        case "syncing": p.total == 0 ? "Looking for devices…" : "Catching up with \(done) of \(total) \(p.total == 1 ? "device" : "devices")…"
        default: activity + "…"
        }
    }
}
#endif
