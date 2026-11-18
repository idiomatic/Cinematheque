#if os(macOS)
import SwiftUI

/// A tile's details: a larger cover, its metadata, playing it, and its
/// place in this user's lists.
struct InspectorView: View {
    let tile: Tile
    @Environment(Library.self) private var library
    @Environment(\.play) private var play
    @State private var detail: TitleDetail?
    @State private var rendition: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // No taller than leaves room for the details below it.
                Color.clear
                    .aspectRatio(tile.isSeries ? 1 : 2.0 / 3.0, contentMode: .fit)
                    .overlay { CoverImage(cover: tile.cover, thumb: tile.thumb, title: tile.name, size: .large, fit: tile.isSeries) }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                    .frame(maxHeight: 340)
                    .frame(maxWidth: .infinity)
                heading
                if let detail {
                    controls(detail)
                    metadata(detail)
                    if tile.season != nil { episodes(detail) }
                    if tile.season == nil, detail.items.count > 1 { versions(detail) }
                }
            }
            .padding(16)
        }
        .task(id: library.revision) {
            detail = library.detail(tile.key)
            if rendition == nil { rendition = detail.flatMap { $0.rendition(for: Playback.items($0, season: tile.season)) } }
        }
        .task(id: tile.id) { await describeEpisodes() }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(tile.name).font(.title2.weight(.semibold))
            Text([tile.seasonName, tile.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func controls(_ detail: TitleDetail) -> some View {
        let items = Playback.items(detail, season: tile.season)
        let next = Playback.nextItem(detail, season: tile.season)
        let renditions = Array(Set(items.flatMap { $0.renditions.map(\.label) })).sorted()
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    if let request = Playback.next(in: detail, season: tile.season, rendition: rendition) { play(request) }
                } label: {
                    Label(Playback.playLabel(next), systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(next == nil)
            }
            .controlSize(.large)
            // On a row of its own: renditions' names are long.
            if renditions.count > 1 {
                Picker("Rendition", selection: $rendition) {
                    ForEach(renditions, id: \.self) { label in
                        Text(RenditionChoice.name(label, in: items)).tag(Optional(label))
                    }
                }
                .labelsHidden()
                .help("The rendition to play")
            }
            if tile.season == nil, let item = items.first, item.inProgress, item.duration > 0 {
                progress(item, key: "\(detail.key)/\(item.key)")
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
                Marks(detail: detail, items: items, season: tile.season)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
    }

    private func progress(_ item: TitleDetail.Item, key: String) -> some View {
        HStack {
            ProgressView(value: Double(item.position), total: Double(item.duration))
            Text((Runtime.format(item.duration - item.position) ?? "") + " left")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            ClearPosition(key: key)
        }
    }

    @ViewBuilder
    private func metadata(_ detail: TitleDetail) -> some View {
        let facts = detail.facts(season: tile.season)
        if !facts.isEmpty {
            Text(facts).foregroundStyle(.secondary)
        }
        if tile.season == nil, let description = detail.summary {
            Text(description).textSelection(.enabled)
        }
    }

    private func episodes(_ detail: TitleDetail) -> some View {
        let items = Playback.items(detail, season: tile.season)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Episodes").font(.headline)
                Spacer()
                // Beside the list it starts, and only where Play wouldn't
                // start there anyway.
                if Playback.nextIndex(items) != 0 {
                    Button("Play from First Episode") {
                        if let request = Playback.request(detail, items: items, from: 0, rendition: rendition) { play(request) }
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                    .help("Play the season from its first episode, the rest queued")
                }
            }
            .padding(.bottom, 6)
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                EpisodeRow(item: item, detail: detail) {
                    if let request = Playback.request(detail, items: items, from: index, rendition: rendition) { play(request) }
                }
                Divider()
            }
        }
    }

    /// A movie's versions (e.g., a director's cut), each playable.
    private func versions(_ detail: TitleDetail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Versions").font(.headline).padding(.bottom, 6)
            ForEach(Array(detail.items.enumerated()), id: \.element.id) { index, item in
                HStack {
                    Button {
                        if let request = Playback.request(detail, items: [item], from: 0, rendition: rendition) { play(request) }
                    } label: {
                        Image(systemName: item.watched ? "checkmark.circle.fill" : "play.circle")
                            .font(.title3)
                            .foregroundStyle(item.watched ? Color.secondary : Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    Text(item.versionName)
                    Spacer()
                    if let runtime = item.runtime {
                        Text(runtime).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .padding(.vertical, 6)
                Divider()
            }
        }
    }

    /// Reads the season's episodes' metadata, one at a time, if not yet read.
    private func describeEpisodes() async {
        guard let season = tile.season else { return }
        await library.describeEpisodes(of: tile.key, season: season)
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
                    Text(item.episodeName)
                        .lineLimit(1)
                    Spacer()
                    if let runtime = item.runtime {
                        Text(runtime).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                if item.inProgress, item.duration > 0 {
                    HStack {
                        ProgressView(value: Double(item.position), total: Double(item.duration)).controlSize(.mini)
                        ClearPosition(key: "\(detail.key)/\(item.key)").controlSize(.mini)
                    }
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

/// Beside a progress meter: forgets where this user stopped, so the item
/// plays from the beginning.
private struct ClearPosition: View {
    let key: String
    @Environment(Library.self) private var library

    var body: some View {
        Button("Clear Progress", systemImage: "arrow.counterclockwise.circle.fill") { library.clearPosition(key) }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Forget where you stopped, to play from the beginning")
    }
}
#endif
