import SwiftUI

/// What to play next, and the queue after it.
enum Playback {
    /// A movie's first item, resuming where this user left off; or a
    /// season's next unwatched episode (or its first, if all are watched),
    /// with the rest of the season queued after it.
    static func next(in detail: TitleDetail, season: Int?, rendition: String? = nil) -> PlayRequest? {
        let items = items(detail, season: season)
        guard !items.isEmpty else { return nil }
        let start = items.firstIndex { !$0.watched } ?? 0
        return request(detail, items: items, from: start, rendition: rendition)
    }

    /// The items of a movie, or of one season, in order.
    static func items(_ detail: TitleDetail, season: Int?) -> [TitleDetail.Item] {
        guard let season else { return detail.items }
        return detail.items
            .filter { $0.episode?.season == season }
            .sorted { ($0.episode?.number ?? 0) < ($1.episode?.number ?? 0) }
    }

    /// Plays `items[index]`, then the rest in order.
    static func request(_ detail: TitleDetail, items: [TitleDetail.Item], from index: Int, rendition: String? = nil) -> PlayRequest? {
        let queue = items[index...].compactMap { item -> PlayRequest.Entry? in
            guard let copy = copy(item, rendition: rendition), let url = URL(string: copy.url) else { return nil }
            return .init(url: url, item: "\(detail.key)/\(item.key)", title: name(item, in: detail))
        }
        guard let first = queue.first else { return nil }
        let item = items[index]
        return PlayRequest(url: first.url, item: first.item, start: item.watched ? 0 : Double(item.position) / 1000, title: first.title, queue: Array(queue.dropFirst()))
    }

    /// The copy to play: of the chosen rendition if the item has one, else
    /// its first.
    static func copy(_ item: TitleDetail.Item, rendition: String?) -> TitleDetail.Copy? {
        let chosen = item.renditions.first { $0.label == rendition } ?? item.renditions.first
        return chosen?.copies.first
    }

    static func name(_ item: TitleDetail.Item, in detail: TitleDetail) -> String {
        if let e = item.episode {
            return "\(detail.name) · S\(e.season)E\(e.number)" + (item.fields["title"].map { " · \($0)" } ?? "")
        }
        return detail.name
    }
}

/// A tile's details: a larger cover, its metadata, playing it, and its
/// place in this user's lists.
struct InspectorView: View {
    let tile: Tile
    @Environment(Library.self) private var library
    @Environment(\.openWindow) private var openWindow
    @State private var detail: TitleDetail?
    @State private var rendition: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // No taller than leaves room for the details below it.
                Color.clear
                    .aspectRatio(tile.isSeries ? 1 : 2.0 / 3.0, contentMode: .fit)
                    .overlay { CoverImage(cover: tile.cover, title: tile.name, size: .large) }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                    .frame(maxHeight: 340)
                    .frame(maxWidth: .infinity)
                heading
                if let detail {
                    controls(detail)
                    metadata(detail)
                    if tile.season != nil { episodes(detail) }
                }
            }
            .padding(16)
        }
        .task(id: library.revision) {
            detail = library.detail(tile.key)
            if rendition == nil { rendition = detail.flatMap { Playback.items($0, season: tile.season).first?.renditions.first?.label } }
        }
        .task(id: tile.id) { await describeEpisodes() }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(tile.name).font(.title2.weight(.semibold))
            Text([tile.season.map { "Season \($0)" }, tile.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func controls(_ detail: TitleDetail) -> some View {
        let items = Playback.items(detail, season: tile.season)
        let next = items.first { !$0.watched } ?? items.first
        let renditions = Array(Set(items.flatMap { $0.renditions.map(\.label) })).sorted()
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    if let request = Playback.next(in: detail, season: tile.season, rendition: rendition) { openWindow(value: request) }
                } label: {
                    Label(playLabel(next, detail), systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(next == nil)
                if renditions.count > 1 {
                    Picker("Rendition", selection: $rendition) {
                        ForEach(renditions, id: \.self) { label in
                            Text(renditionName(label, in: items)).tag(Optional(label))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            if tile.season == nil, let item = items.first, !item.watched, item.position > 0, item.duration > 0 {
                progress(item)
            }
            // Labeled where they fit, else icons alone.
            ViewThatFits(in: .horizontal) {
                lists(detail, items: items).labelStyle(.titleAndIcon)
                lists(detail, items: items).labelStyle(.iconOnly)
            }
        }
    }

    private func lists(_ detail: TitleDetail, items: [TitleDetail.Item]) -> some View {
            HStack {
                let listed = library.watchlist.contains(tile.key)
                Button {
                    library.setWatchlisted(tile.key, !listed)
                } label: {
                    Label(listed ? "On Watchlist" : "Watchlist", systemImage: listed ? "star.fill" : "star")
                }
                .help(listed ? "Remove from your watchlist" : "Add to your watchlist")
                let allWatched = !items.isEmpty && items.allSatisfy(\.watched)
                Button {
                    for item in items { library.setWatched("\(detail.key)/\(item.key)", !allWatched) }
                } label: {
                    Label(allWatched ? "Unwatched" : "Watched", systemImage: allWatched ? "circle" : "checkmark.circle")
                }
                .help(allWatched ? "Mark as unwatched" : "Mark as watched")
                if tile.season != nil {
                    Button {
                        if let request = Playback.request(detail, items: items, from: 0, rendition: rendition) { openWindow(value: request) }
                    } label: {
                        Label("From Start", systemImage: "backward.end.fill")
                    }
                    .help("Play the season from its first episode")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
    }

    private func playLabel(_ next: TitleDetail.Item?, _ detail: TitleDetail) -> String {
        guard let next else { return "Play" }
        let verb = !next.watched && next.position > 0 ? "Resume" : "Play"
        if let e = next.episode { return "\(verb) Episode \(e.number)" }
        return verb
    }

    private func renditionName(_ label: String, in items: [TitleDetail.Item]) -> String {
        items.lazy.flatMap(\.renditions).first { $0.label == label }?.name ?? label
    }

    private func progress(_ item: TitleDetail.Item) -> some View {
        HStack {
            ProgressView(value: Double(item.position), total: Double(item.duration))
            Text((Self.runtime(item.duration - item.position) ?? "") + " left")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private func metadata(_ detail: TitleDetail) -> some View {
        let fields = detail.fields
        let duration = tile.season == nil ? detail.items.first?.fields["duration"].flatMap(Int.init) : nil
        let facts = [fields["genre"], fields["released"].map { String($0.prefix(4)) }, fields["network"], duration.flatMap(Self.runtime)].compactMap { $0 }
        if !facts.isEmpty {
            Text(facts.joined(separator: " · ")).foregroundStyle(.secondary)
        }
        if tile.season == nil, let description = fields["description"] {
            Text(description).textSelection(.enabled)
        }
    }

    private func episodes(_ detail: TitleDetail) -> some View {
        let items = Playback.items(detail, season: tile.season)
        return VStack(alignment: .leading, spacing: 0) {
            Text("Episodes").font(.headline).padding(.bottom, 6)
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                EpisodeRow(item: item, detail: detail) {
                    if let request = Playback.request(detail, items: items, from: index, rendition: rendition) { openWindow(value: request) }
                }
                Divider()
            }
        }
    }

    /// Reads the season's episodes' metadata, one at a time, if not yet read.
    private func describeEpisodes() async {
        guard tile.season != nil, let detail = library.detail(tile.key) else { return }
        for item in Playback.items(detail, season: tile.season) where item.fields["duration"] == nil {
            if Task.isCancelled { return }
            await library.describe("\(detail.key)/\(item.key)")
        }
    }

    static func runtime(_ ms: Int) -> String? {
        guard ms > 0 else { return nil }
        let units: Set<Duration.UnitsFormatStyle.Unit> = ms < 60_000 ? [.seconds] : [.hours, .minutes]
        return Duration.milliseconds(ms).formatted(.units(allowed: units, width: .narrow))
    }
}

private struct EpisodeRow: View {
    let item: TitleDetail.Item
    let detail: TitleDetail
    let play: () -> Void
    @Environment(Library.self) private var library

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: play) {
                Image(systemName: item.watched ? "checkmark.circle.fill" : "play.circle")
                    .font(.title3)
                    .foregroundStyle(item.watched ? Color.secondary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .help(item.watched ? "Watched; play again" : "Play")
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("\(item.episode?.number ?? 0). " + (item.fields["title"] ?? "Episode \(item.episode?.number ?? 0)"))
                        .lineLimit(1)
                    Spacer()
                    if let runtime = item.fields["duration"].flatMap(Int.init).flatMap(InspectorView.runtime) {
                        Text(runtime).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                if !item.watched, item.position > 0, item.duration > 0 {
                    ProgressView(value: Double(item.position), total: Double(item.duration)).controlSize(.mini)
                }
                if let description = item.fields["description"] {
                    Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .contextMenu {
            Button(item.watched ? "Mark as Unwatched" : "Mark as Watched") {
                library.setWatched("\(detail.key)/\(item.key)", !item.watched)
            }
        }
    }
}
