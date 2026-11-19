#if os(macOS)
import SwiftUI

/// A tile's details: a larger cover, its metadata, playing it, and its
/// place in this person's lists.
struct InspectorView: View {
    let tile: Tile
    @Environment(Library.self) private var library
    @Environment(\.play) private var play
    @State private var detail: TitleDetail?
    @State private var quality: String?

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
            if quality == nil { quality = detail.flatMap { $0.quality(for: Playback.items($0, season: tile.season)) } }
        }
        .task(id: tile.id) { await describeEpisodes() }
        // Asked for by deleting an only copy, here or in an episode's menu.
        .confirmationDialog(
            deletionTitle,
            isPresented: Binding(get: { library.deleting != nil }, set: { if !$0 { library.deleting = nil } }),
            presenting: library.deleting
        ) { key in
            Button("Delete", role: .destructive) { library.removeDownload(key) }
            Button("Cancel", role: .cancel) {}
        } message: { key in
            Text(library.onlyCopies(key) == 1
                ? "This Mac holds the only copy: no source has another, so once it's deleted, it's gone from the library, on every device."
                : "This Mac holds the only copies of \(library.onlyCopies(key)) of them: no source has others, so once they're deleted, they're gone from the library, on every device.")
        }
    }

    private var deletionTitle: String {
        guard let key = library.deleting else { return "" }
        let n = library.onlyCopies(key)
        return n == 1 ? "Delete the only copy?" : "Delete \(n) only copies?"
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
        let qualities = Array(Set(items.flatMap { $0.qualities.map(\.label) })).sorted()
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    if let request = Playback.next(in: detail, season: tile.season, quality: quality) { play(request) }
                } label: {
                    Label(Playback.playLabel(next), systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(next == nil)
            }
            .controlSize(.large)
            // On a row of its own: qualities' names are long.
            if qualities.count > 1 {
                Picker("Quality", selection: $quality) {
                    ForEach(qualities, id: \.self) { label in
                        Text(QualityChoice.name(label, in: items)).tag(Optional(label))
                    }
                }
                .labelsHidden()
                .help("The quality to play")
            }
            if tile.season == nil, let item = items.first, item.inProgress, item.duration > 0 {
                progress(item, key: "\(detail.key)/\(item.key)")
            }
            // Labeled where they fit, else icons alone.
            ViewThatFits(in: .horizontal) {
                lists(detail, items: items).labelStyle(.titleAndIcon)
                lists(detail, items: items).labelStyle(.iconOnly)
            }
            DownloadControls(detail: detail, items: items, season: tile.season, quality: quality)
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
                        if let request = Playback.request(detail, items: items, from: 0, quality: quality) { play(request) }
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
                EpisodeRow(item: item, detail: detail, quality: quality) {
                    if let request = Playback.request(detail, items: items, from: index, quality: quality) { play(request) }
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
                        if let request = Playback.request(detail, items: [item], from: 0, quality: quality) { play(request) }
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
    let quality: String?
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
            DownloadMenuItems(key: "\(detail.key)/\(item.key)", quality: quality)
            Divider()
            Button(item.watched ? "Mark as Unwatched" : "Mark as Watched") {
                library.setWatched("\(detail.key)/\(item.key)", !item.watched)
            }
        }
    }
}

/// Beside a progress meter: forgets where this person stopped, so the item
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

/// Downloading to this Mac: a movie (the version Play plays), or for a
/// season, which of its series' episodes download as it's watched, a
/// choice that changes only when a person picks another; a spinner while
/// any comes; and deleting them (which sets the choice to Nothing, if it
/// asks for any of them).
private struct DownloadControls: View {
    let detail: TitleDetail
    let items: [TitleDetail.Item]
    let season: Int?
    let quality: String?
    @Environment(Library.self) private var library

    private static let counts = [1, 3, 5, 10]

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
                Button("Delete Download", systemImage: "trash") { library.deleteDownload(key) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help(library.onlyCopies(key) > 0 ? "Delete it from this Mac: the only copy" : "Delete it from this Mac")
            } else if library.isWanted(key) {
                ProgressView().controlSize(.small)
                Text("Downloading…").foregroundStyle(.secondary)
                Button("Cancel Download", systemImage: "xmark.circle.fill") { library.removeDownload(key) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Stop downloading it")
            } else {
                Button("Download", systemImage: "arrow.down.circle") { library.download(key, quality: quality) }
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
        let chosen = library.downloadChoice(detail.key)
        let here = String(format: "s%02d", season)
        // Whether any of this season's episodes the choice (or a person, one
        // by one) asks for hasn't come yet.
        let pending = keys.contains { library.isRequested($0) && !library.isDownloaded($0) }
        // One row, nothing in it coming or going: the spinner's place kept
        // while nothing comes, the trash button dimmed while nothing's here.
        HStack {
            Picker("Download", selection: Binding(get: { chosen }, set: { library.chooseDownloads(detail.key, $0) })) {
                Section {
                    Text("Nothing").tag("")
                    ForEach(Self.counts, id: \.self) { n in Text(Self.title(String(n))).tag(String(n)) }
                    // A count chosen elsewhere (the core takes any).
                    if Int(chosen).map({ !Self.counts.contains($0) }) ?? false { Text(Self.title(chosen)).tag(chosen) }
                }
                Section {
                    Text(Self.title(here)).tag(here)
                    // Another season's, as chosen there.
                    if chosen.hasPrefix("s"), chosen != here { Text(Self.title(chosen)).tag(chosen) }
                    Text("Unwatched").tag("unwatched")
                    Text("All").tag("all")
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help("Which of the series' episodes download to this Mac as it's watched, to watch without a network; watched ones go as their space is needed, but for All")
            ProgressView().controlSize(.mini).opacity(pending ? 1 : 0)
                .help("Downloading")
            Button(season == 0 ? "Delete Specials' Downloads" : "Delete Season's Downloads", systemImage: "trash") { library.deleteDownload(key) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(held == 0)
                .help((library.onlyCopies(key) > 0 ? "Delete the season's downloads from this Mac: some are the only copies" : "Delete the season's downloads from this Mac") + (keys.contains { library.isRequested($0) && library.isDownloaded($0) } && !chosen.isEmpty ? "; Download becomes Nothing, so they don't come back" : ""))
        }
        .controlSize(.small)
    }

    /// A choice of episodes, as the menu says it: short, read after its
    /// label ("Download Next 3").
    private static func title(_ choice: String) -> String {
        if choice.hasPrefix("s"), let season = Int(choice.dropFirst()) {
            return season == 0 ? "Unwatched Specials" : "Unwatched in Season \(season)"
        }
        switch choice {
        case "1": return "Next"
        case "unwatched": return "Unwatched"
        case "all": return "All"
        default: return "Next \(choice)"
        }
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
    let quality: String?
    @Environment(Library.self) private var library

    var body: some View {
        if library.isDownloaded(key) {
            if library.done(key) != nil {
                Button("Keep Download") { library.keep(key, true) }
            } else if library.isKept(key) {
                Button("Stop Keeping Download") { library.keep(key, false) }
            }
            Button(library.onlyCopies(key) > 0 ? "Delete Download (the Only Copy)…" : "Delete Download") { library.deleteDownload(key) }
        } else if library.isWanted(key) {
            Button("Cancel Download") { library.removeDownload(key) }
        } else {
            Button("Download") { library.download(key, quality: quality) }
        }
    }
}
#endif
