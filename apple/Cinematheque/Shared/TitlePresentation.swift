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


    /// A symbol of how far this person has watched it.
    var progressSymbol: String {
        watched ? "checkmark.circle.fill" : (inProgress ? "circle.lefthalf.filled" : "circle")
    }
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
        reload()
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
        // A status that pressing toggles: it shows whether it's watched.
        Button(watched ? "Watched" : "Unwatched", systemImage: watched ? "checkmark.circle.fill" : "circle") {
            library.setWatched(items, of: detail, !watched)
        }
        .help(watched ? "Mark as unwatched" : "Mark as watched")
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
            if downloaded { mark("arrow.down.circle.fill", .blue, "Downloaded") }
            if listed { mark("star.fill", .yellow, "On a list") }
            // Green, not the accent color, which is white on tvOS.
            if watched { mark("checkmark.circle.fill", .green, "Watched") }
        }
    }

    private func mark(_ symbol: String, _ color: Color, _ name: String) -> some View {
        Image(systemName: symbol)
            .foregroundStyle(color)
            .accessibilityLabel(name)
            .help(name)
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
            Label("Lists", systemImage: on.isEmpty ? "star" : "star.fill")
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
/// a list's name, in an alert with a field (on tvOS, the full-screen
/// keyboard at once, as Settings' names, an alert's field bringing up the
/// keyboard over it), and deleting one, confirmed first, as it's for good.
struct ListRequests: ViewModifier {
    @Environment(Library.self) private var library
    @State private var name = ""

    func body(content: Content) -> some View {
        let renaming: UserList? = if case .rename(let list) = library.listPrompt?.kind { list } else { nil }
        let prompting = Binding(get: { library.listPrompt != nil }, set: { if !$0 { library.listPrompt = nil } })
        content
            #if os(tvOS)
            .background {
                KeyboardField(title: renaming == nil ? "New List" : "Rename List", text: renaming?.name ?? "", typing: prompting) { answer($0) }
                    .frame(width: 1, height: 1)
                    .clipped()
                    .opacity(0.01)
                    .accessibilityHidden(true)
            }
            #else
            .alert(renaming == nil ? "New List" : "Rename List", isPresented: prompting) {
                TextField("Name", text: $name)
                Button("Cancel", role: .cancel) {}
                Button(renaming == nil ? "Create" : "Rename") { answer(name) }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .onChange(of: library.listPrompt?.id) { name = renaming?.name ?? "" }
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
                    if let list = library.sharingList { library.shareList(list.id, true) }
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
