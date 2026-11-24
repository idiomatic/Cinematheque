import SwiftUI

/// How a title and its items read, and what to play of them, the same on
/// every platform; each platform lays them out its own way.
extension TitleDetail {
    /// "Action · 2013 · HBO · 1h 49m": genre, year, network, and, for a
    /// movie (`season` nil), its runtime.
    func facts(season: Int?) -> String {
        let runtime = season == nil ? items.first?.runtime : nil
        return [fields["genre"], fields["released"].map { String($0.prefix(4)) } ?? year.map(String.init), fields["network"], runtime]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// A movie's description, or a season's (its series').
    var summary: String? { fields["description"] ?? items.first?.fields["description"] }

    /// The quality to play the items in (see `QualityChoice.best`).
    func quality(for items: [Item]) -> String? {
        QualityChoice.best(items)
    }

    /// `chosen`, if any of `items` has it, else the best this device plays.
    func quality(for items: [Item], chosen: String?) -> String? {
        guard let chosen, items.contains(where: { $0.qualities.contains { $0.label == chosen } }) else { return quality(for: items) }
        return chosen
    }
}

extension TitleDetail {
    /// What a movie's Download downloads, as the version Play plays: an
    /// item alone, if it's a whole file; a version of parts alone, all its
    /// parts. With its key, and its name among the movie's versions.
    var downloadTarget: (key: String, items: [Item], name: String)? {
        guard let item = items.first(where: \.next) ?? items.first else { return nil }
        if let part = item.key.range(of: "/p/") {
            let version = String(item.key[..<part.lowerBound])
            if !items.contains(where: { $0.key == version }) {
                return ("\(key)/\(version)", items.filter { $0.key.hasPrefix(version + "/p/") }, item.version ?? item.label)
            }
        }
        return ("\(key)/\(item.key)", [item], item.label)
    }
}

extension TitleDetail.Item {
    /// Its runtime, e.g., "44m" or "1h 49m".
    var runtime: String? { fields["duration"].flatMap(Int.init).flatMap(Runtime.format) }

    /// Begun but not finished.
    var inProgress: Bool { !watched && position > 0 }
}

enum Runtime {
    /// "44m", "1h 49m", or under a minute, "40s".
    static func format(_ ms: Int) -> String? {
        guard ms > 0 else { return nil }
        let units: Set<Duration.UnitsFormatStyle.Unit> = ms < 60_000 ? [.seconds] : [.hours, .minutes]
        return Duration.milliseconds(ms).formatted(.units(allowed: units, width: .narrow))
    }
}

extension Playback {
    /// What Play plays: a movie's item, or a season's episode in progress,
    /// else its next unwatched (its first, if all are watched).
    static func nextItem(_ detail: TitleDetail, season: Int?) -> TitleDetail.Item? {
        let items = items(detail, season: season)
        return items.isEmpty ? nil : items[nextIndex(items)]
    }

    /// Start Over, beside Resume (on the Apple TV): the symbol of a button
    /// that plays what Resume would, from its beginning (to the start, not
    /// rewinding).
    static let startOverSymbol = "backward.end.fill"

    /// "Play", "Resume", "Play Episode 3", "Resume Special", "Play March 12"
    /// (the episode's label, as the core gives it).
    static func playLabel(_ next: TitleDetail.Item?) -> String {
        guard let next else { return "Play" }
        let verb = next.inProgress ? "Resume" : "Play"
        if next.episode != nil { return "\(verb) \(next.label)" }
        return verb
    }
}

/// Which quality a player plays: one in a format it plays (MP4, MOV, or
/// M4V; not MKV or ISO), at the most its display shows (`Platform`), else
/// the least above that.
enum QualityChoice {
    static func best(_ items: [TitleDetail.Item]) -> String? {
        let limit = Platform.displayHeight >= 2160 ? 2160 : 1080
        let qualities = items.flatMap(\.qualities)
        let playable = qualities.filter { r in r.copies.contains { isPlayable($0.url) } }
        return (playable.isEmpty ? qualities : playable).max { score($0.height, limit) < score($1.height, limit) }?.label
    }

    /// The items' qualities for a picker, by label: highest resolution
    /// first, those of unknown resolution last, then by short name.
    static func labels(_ items: [TitleDetail.Item]) -> [String] {
        var seen: [String: TitleDetail.Quality] = [:]
        for q in items.lazy.flatMap(\.qualities) where seen[q.label] == nil { seen[q.label] = q }
        return seen.values.sorted {
            ($0.height ?? 0, $1.short) > ($1.height ?? 0, $0.short)
        }.map(\.label)
    }

    /// A quality's name for a picker, by its label.
    static func name(_ label: String, in items: [TitleDetail.Item]) -> String {
        items.lazy.flatMap(\.qualities).first { $0.label == label }?.name ?? label
    }

    /// Each quality's short name for a picker, as the core names it (see
    /// views.zig); the full name is the picker's help.
    static func shortNames(_ labels: [String], in items: [TitleDetail.Item]) -> [String: String] {
        var out: [String: String] = [:]
        for q in items.lazy.flatMap(\.qualities) where labels.contains(q.label) && out[q.label] == nil { out[q.label] = q.short }
        return out
    }

    private static func isPlayable(_ url: String) -> Bool {
        ["mp4", "m4v", "mov"].contains((URL(string: url)?.pathExtension ?? "").lowercased())
    }

    /// The highest resolution up to the limit, then those above it, least
    /// first; one of unknown resolution ranks low.
    private static func score(_ height: Int?, _ limit: Int) -> Int {
        guard let height else { return 0 }
        return height <= limit ? 10_000 + height : 10_000 - height
    }
}

extension Library {
    /// Marks items of a title watched, or not, and reloads tiles' marks.
    func setWatched(_ items: [TitleDetail.Item], of detail: TitleDetail, _ watched: Bool) {
        for item in items { setWatched("\(detail.key)/\(item.key)", watched) }
        reloadSoon()
    }
}

/// The lists and watched marks of a movie or a season, for the platform
/// to lay out and style.
struct Marks: View {
    let detail: TitleDetail
    let items: [TitleDetail.Item]
    /// The season they're of, which goes on a list on its own.
    var season: Int? = nil
    @Environment(Library.self) private var library

    var body: some View {
        let watched = !items.isEmpty && items.allSatisfy(\.watched)
        ListsMenu(key: Library.listKey(detail.key, season: season))
        WatchedToggle(watched: watched) { library.setWatched(items, of: detail, !watched) }
    }
}

/// Watched, as every player marks it, on tiles and items' rows alike, at
/// the end of a name's line: green, not the accent color, which is white
/// on tvOS.
struct WatchedMark: View {
    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.green)
            .accessibilityLabel("Watched")
            .help("Watched")
    }
}

/// A status that pressing toggles: whether a title (or a whole series) is
/// watched, its check the watched mark's.
struct WatchedToggle: View {
    let watched: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Label {
                Text(watched ? "Watched" : "Unwatched")
            } icon: {
                Image(systemName: watched ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(watched ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
            }
        }
        .help(watched ? "Mark as unwatched" : "Mark as watched")
    }
}

/// An item's row on the Apple TV and the iPhone, where the whole row plays
/// it, as the Mac's inspector and the web client lay theirs out: its name,
/// the watched mark and its runtime at the line's end, and partway, a thin
/// bar under it.
struct ItemLine: View {
    let item: TitleDetail.Item
    var name: String? = nil

    var body: some View {
        LabeledContent {
            HStack {
                if item.watched { WatchedMark() }
                if let runtime = item.runtime { Text(runtime) }
            }
        } label: {
            Label {
                VStack(alignment: .leading) {
                    Text(name ?? item.name)
                    if item.inProgress, item.duration > 0 {
                        ProgressView(value: Double(item.position), total: Double(item.duration))
                    }
                }
            } icon: {
                Image(systemName: "play.circle")
            }
        }
    }
}

/// A cover over what's under it (its name), each as wide as
/// the cover and no wider, so a long name is cut short or wraps rather
/// than widening its tile, whose cover takes the width its shape gives it,
/// and the gaps along a row.
struct UnderCover: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let first = subviews.first else { return .zero }
        let cover = first.sizeThatFits(proposal)
        let below = subviews.dropFirst().map { $0.sizeThatFits(ProposedViewSize(width: cover.width, height: nil)).height }
        return CGSize(width: cover.width, height: below.reduce(cover.height) { $0 + spacing + $1 })
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let first = subviews.first else { return }
        let cover = first.sizeThatFits(proposal)
        first.place(at: bounds.origin, proposal: ProposedViewSize(cover))
        var y = bounds.minY + cover.height
        for subview in subviews.dropFirst() {
            let width = ProposedViewSize(width: cover.width, height: nil)
            y += spacing
            subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: width)
            y += subview.sizeThatFits(width).height
        }
    }
}

/// A tile's marks, at its name line's end, under its cover, on every
/// platform, so the cover shows whole: downloaded (the Mac's own), on a
/// list, and watched.
struct TileMarks: View {
    let listed: Bool
    let watched: Bool
    var downloaded = false

    var body: some View {
        HStack(spacing: 3) {
            if downloaded { DownloadedMark() }
            if listed { ListedMark() }
            if watched { WatchedMark() }
        }
    }
}

/// Downloaded to this device (the Mac's), as tiles and rows mark it: a
/// blue arrow.
struct DownloadedMark: View {
    var body: some View {
        Image(systemName: "arrow.down.circle.fill")
            .foregroundStyle(.blue)
            .accessibilityLabel("Downloaded")
            .help("Downloaded")
    }
}

/// On a list, as every player marks it, on tiles, rows, and the Lists
/// menu alike: a yellow star.
struct ListedMark: View {
    var body: some View {
        Image(systemName: "star.fill")
            .foregroundStyle(.yellow)
            .accessibilityLabel("On a list")
            .help("On a list")
    }
}

/// How far through a tile is, as a thin bar along its cover's foot, white
/// on a translucent track, as the web client draws it, so the art shows
/// through rather than being covered; nothing when it's not begun, or
/// watched. Drawn, not the system's ProgressView, whose track can't be made
/// translucent.
struct CoverProgress: View {
    let tile: Tile

    #if os(tvOS)
    private static let height: CGFloat = 6
    private static let inset: CGFloat = 12
    #else
    private static let height: CGFloat = 4
    private static let inset: CGFloat = 8
    #endif

    var body: some View {
        if !tile.watched, tile.progress > 0 {
            Capsule()
                .fill(.white.opacity(0.35))
                .overlay(alignment: .leading) {
                    GeometryReader { space in
                        Capsule().fill(.white).frame(width: space.size.width * min(max(tile.progress, 0), 1))
                    }
                }
                .frame(height: Self.height)
                .padding(Self.inset)
                .accessibilityElement()
                .accessibilityLabel("\(Int((tile.progress * 100).rounded())) percent watched")
        }
    }
}

/// A movie's or a season's lists, as a menu: its star filled if it's on
/// any, its name the same whatever it's on, so nothing beside it moves.
struct ListsMenu: View {
    let key: String
    @Environment(Library.self) private var library

    var body: some View {
        let on = library.lists(holding: key)
        Menu {
            ListToggles(key: key)
        } label: {
            Label {
                Text("Lists")
            } icon: {
                // Its star the tiles' when it's on one.
                if on.isEmpty {
                    Image(systemName: "star")
                } else {
                    #if os(macOS)
                    // Colored in the image itself, as a menu's label on
                    // macOS is drawn as a template, ignoring its style.
                    Image(nsImage: NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil)!
                        .withSymbolConfiguration(.init(paletteColors: [.systemYellow]))!)
                    #else
                    Image(systemName: "star.fill").foregroundStyle(.yellow)
                    #endif
                }
            }
        }
        .help(on.isEmpty ? "Add to a list" : "On " + on.map(\.name).joined(separator: ", "))
    }
}

/// A menu's lists, each checked if `key` is on it, chosen to put it on or
/// take it off; then New List…, putting it on the new one.
struct ListToggles: View {
    let key: String
    @Environment(Library.self) private var library

    var body: some View {
        ForEach(library.myLists) { list in
            Toggle(list.name, isOn: Binding(get: { list.titles.contains(key) }, set: { library.setListed(key, on: list.id, $0) }))
        }
        Divider()
        Button("New List…") { library.listPrompt = .init(kind: .create(adding: [key])) }
    }
}

/// Asking for a list's name: a new one's (to put titles on: a title, or a
/// series' seasons), or another for one.
struct ListPrompt: Identifiable {
    enum Kind {
        case create(adding: [String])
        case rename(UserList)
    }

    let id = UUID()
    let kind: Kind
}

/// Answers the library's requests about lists, from wherever they came:
/// a list's name (on tvOS, the full-screen keyboard at once, as Settings'
/// names, an alert's field bringing up the keyboard over it; on iOS, a
/// sheet, as Reminders' Add List, a menu holding no field; on the Mac, the
/// browser makes it, named in place in the sidebar), and deleting one,
/// confirmed first, as it's for good.
struct ListRequests: ViewModifier {
    @Environment(Library.self) private var library

    func body(content: Content) -> some View {
        let renaming: UserList? = if case .rename(let list) = library.listPrompt?.kind { list } else { nil }
        let prompting = Binding(get: { library.listPrompt != nil }, set: { if !$0 { library.listPrompt = nil } })
        content
            #if os(tvOS)
            .background {
                KeyboardField(title: renaming == nil ? "New List" : "Rename List", text: renaming?.name ?? "", typing: prompting) { answer($0) }
                    .unseen()
            }
            #elseif os(iOS)
            .sheet(isPresented: prompting) {
                ListNameSheet(title: renaming == nil ? "New List" : "Rename List", action: renaming == nil ? "Create" : "Rename", name: renaming?.name ?? "") { answer($0) }
            }
            #endif
            .confirmationDialog("Delete “\(library.deletingList?.name ?? "")”?", isPresented: Binding(get: { library.deletingList != nil }, set: { if !$0 { library.deletingList = nil } }), titleVisibility: .visible) {
                Button("Delete List", role: .destructive) {
                    if let list = library.deletingList { library.removeList(list.id) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Its titles stay in the library. This can’t be undone.")
            }
            .confirmationDialog("Share “\(library.sharingList?.name ?? "")” with everyone in the library?", isPresented: Binding(get: { library.sharingList != nil }, set: { if !$0 { library.sharingList = nil } }), titleVisibility: .visible) {
                Button("Share") {
                    if let list = library.sharingList { library.shareList(list.id) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("They’ll see its titles, and only you can change it. If you stop sharing it, their devices keep what they’ve already received.")
            }
    }

    /// A blank name is ignored, as the keyboard can't refuse one.
    private func answer(_ typed: String) {
        let named = typed.trimmingCharacters(in: .whitespaces)
        guard let prompt = library.listPrompt, !named.isEmpty else { return }
        switch prompt.kind {
        case .create(let keys):
            if let id = library.createList(named: named) { for key in keys { library.setListed(key, on: id, true) } }
        case .rename(let list):
            library.renameList(list.id, to: named)
        }
    }
}

#if os(iOS)
/// A list's name, in a small sheet: typed, with the keyboard up, and made
/// by Return or `action`; Cancel leaves it.
private struct ListNameSheet: View {
    let title: String
    let action: String
    @State var name: String
    let done: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var typing: Bool

    init(title: String, action: String, name: String, done: @escaping (String) -> Void) {
        self.title = title
        self.action = action
        _name = State(initialValue: name)
        self.done = done
    }

    private var blank: Bool { name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name, prompt: Text("Watchlist"))
                    .focused($typing)
                    .submitLabel(.done)
                    .onSubmit(finish)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(action, action: finish).disabled(blank) }
            }
            .onAppear { typing = true }
        }
        .presentationDetents([.height(200)])
    }

    private func finish() {
        guard !blank else { return }
        done(name)
        dismiss()
    }
}
#endif

#if os(tvOS) || os(iOS)
/// The quality a title page plays in, by short names (the Apple TV's and
/// the iPhone's): a picker, or, of one quality, it as text, so every title
/// says what it plays in.
struct QualityPicker: View {
    let detail: TitleDetail
    let items: [TitleDetail.Item]
    @Binding var chosen: String?

    var body: some View {
        let labels = QualityChoice.labels(items)
        let short = QualityChoice.shortNames(labels, in: items)
        if labels.count == 1, let label = labels.first {
            Text(short[label] ?? label)
                #if os(iOS)
                .font(.subheadline)
                #endif
                .foregroundStyle(.secondary)
        } else if labels.count > 1 {
            Picker(selection: Binding(get: { detail.quality(for: items, chosen: chosen) }, set: { chosen = $0 })) {
                ForEach(labels, id: \.self) { Text(short[$0] ?? $0).tag(Optional($0)) }
            } label: {
                Label("Quality", systemImage: "slider.horizontal.3")
            }
            .pickerStyle(.menu)
        }
    }
}
#endif
