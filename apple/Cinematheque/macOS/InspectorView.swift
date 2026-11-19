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
            DownloadControls(detail: detail, items: items, season: tile.season, rendition: rendition)
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
                    Button {
                        if let request = Playback.request(detail, items: items, from: 0, rendition: rendition) { play(request) }
                    } label: {
                        Label("Restart", systemImage: "backward.end.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Play the season from its first episode, the rest queued")
                }
            }
            .padding(.bottom, 6)
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                EpisodeRow(item: item, detail: detail, rendition: rendition) {
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
    let rendition: String?
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
                    DownloadMark(key: "\(detail.key)/\(item.key)")
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
            DownloadMenuItems(key: "\(detail.key)/\(item.key)", rendition: rendition)
            Divider()
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
        Button("Start from Beginning", systemImage: "arrow.counterclockwise.circle.fill") { library.clearPosition(key) }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Forget where you stopped, to play from the beginning")
    }
}

/// Downloading to this Mac: a movie (the version Play plays), or a season,
/// whole or its next episodes as they're watched.
private struct DownloadControls: View {
    let detail: TitleDetail
    let items: [TitleDetail.Item]
    let season: Int?
    let rendition: String?
    @Environment(Library.self) private var library

    private static let next = [1, 3, 5, 10]

    var body: some View {
        if let season {
            seasonControls(season)
        } else if let item = items.first {
            movieControls("\(detail.key)/\(item.key)")
        }
    }

    @ViewBuilder
    private func movieControls(_ key: String) -> some View {
        HStack {
            if library.isDownloaded(key) {
                DownloadState(key: key)
                if library.done(key) != nil {
                    Button("Keep") { library.keep(key, true) }
                        .buttonStyle(.borderless)
                        .help("Keep it on this Mac, however it's watched")
                }
                Button("Delete Download", systemImage: "trash") { library.removeDownload(key) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help(library.done(key)?.deletable == false ? "Delete it from this Mac: the only copy" : "Delete it from this Mac")
            } else if library.isWanted(key) {
                ProgressView().controlSize(.small)
                Text("Downloading…").foregroundStyle(.secondary)
                Button("Cancel Download", systemImage: "xmark.circle.fill") { library.removeDownload(key) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Stop downloading it")
            } else {
                Button("Download", systemImage: "arrow.down.circle") { library.download(key, rendition: rendition) }
                    .buttonStyle(.bordered)
                    .help("Download it to this Mac, to watch without a network")
            }
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private func seasonControls(_ season: Int) -> some View {
        let key = detail.key + String(format: "/e/s%02d", season)
        let keys = items.map { "\(detail.key)/\($0.key)" }
        let held = keys.filter(library.isDownloaded).count
        let next = library.nextEpisodes(detail.key)
        HStack {
            Menu {
                Button("Download Season") { library.download(key, rendition: rendition) }
                    .disabled(held == keys.count)
                Picker("Download Next Episodes", selection: Binding(get: { next }, set: { library.downloadNext(detail.key, episodes: $0) })) {
                    Text("Off").tag(0)
                    ForEach(Self.next, id: \.self) { n in Text(n == 1 ? "1 Episode" : "\(n) Episodes").tag(n) }
                }
                if held > 0 {
                    Divider()
                    Button("Delete Season's Downloads", role: .destructive) { library.removeDownload(key) }
                }
            } label: {
                Label("Download", systemImage: held > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
            }
            .fixedSize()
            .help("Download the season, or keep the series' next episodes, to watch without a network")
            if let status = status(held: held, of: keys.count, next: next) {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .controlSize(.small)
    }

    private func status(held: Int, of count: Int, next: Int) -> String? {
        var parts: [String] = []
        if held > 0 { parts.append(held == count ? "All downloaded" : "\(held) of \(count) downloaded") }
        if next > 0 { parts.append(next == 1 ? "downloading the next episode" : "downloading the next \(next)") }
        guard !parts.isEmpty else { return nil }
        let text = parts.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

/// A download's state, in words: kept, watched (waiting for its space to
/// be needed, or the only copy), or downloaded.
private struct DownloadState: View {
    let key: String
    @Environment(Library.self) private var library

    var body: some View {
        if let done = library.done(key) {
            Label(done.deletable ? "Watched: goes when space is needed" : "Watched, and the only copy", systemImage: done.deletable ? "hourglass.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(done.deletable ? Color.secondary : Color.orange)
        } else {
            Label(library.isKept(key) ? "Downloaded, kept" : "Downloaded", systemImage: "arrow.down.circle.fill")
                .foregroundStyle(.secondary)
        }
    }
}

/// Beside an episode: downloaded (and watched, waiting or the only copy),
/// or downloading.
private struct DownloadMark: View {
    let key: String
    @Environment(Library.self) private var library

    var body: some View {
        if let done = library.done(key) {
            Image(systemName: done.deletable ? "hourglass.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(done.deletable ? Color.secondary : Color.orange)
                .help(done.deletable ? "Watched: deleted when its space is needed, as another source has it" : "Watched, and the only copy: delete it, or keep it")
        } else if library.isDownloaded(key) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.secondary)
                .help(library.isKept(key) ? "Downloaded to this Mac, and kept" : "Downloaded to this Mac")
        } else if library.isWanted(key) {
            ProgressView().controlSize(.mini).help("Downloading")
        }
    }
}

/// An item's download, in its context menu.
private struct DownloadMenuItems: View {
    let key: String
    let rendition: String?
    @Environment(Library.self) private var library

    var body: some View {
        if library.isDownloaded(key) {
            if library.done(key) != nil {
                Button("Keep Download") { library.keep(key, true) }
            } else if library.isKept(key) {
                Button("Stop Keeping Download") { library.keep(key, false) }
            }
            Button(library.done(key)?.deletable == false ? "Delete Download (the Only Copy)" : "Delete Download") { library.removeDownload(key) }
        } else if library.isWanted(key) {
            Button("Cancel Download") { library.removeDownload(key) }
        } else {
            Button("Download") { library.download(key, rendition: rendition) }
        }
    }
}
#endif
