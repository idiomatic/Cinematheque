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
                    // A movie of one version: its quality alone, under its details.
                    if tile.season == nil, detail.items.count <= 1 {
                        HStack {
                            Spacer()
                            qualityPicker(detail.items)
                        }
                    }
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
        VStack(alignment: .leading, spacing: 10) {
            // Play filling its row, the marks beside it, quieter: labeled
            // where they fit, else icons alone.
            ViewThatFits(in: .horizontal) {
                playRow(detail, next: next, items: items, labeled: true)
                playRow(detail, next: next, items: items, labeled: false)
            }
            if tile.season == nil, let item = items.first, item.inProgress, item.duration > 0 {
                progress(item, key: "\(detail.key)/\(item.key)")
            }
            DownloadControls(detail: detail, items: items, season: tile.season, quality: quality)
        }
    }

    private func playRow(_ detail: TitleDetail, next: TitleDetail.Item?, items: [TitleDetail.Item], labeled: Bool) -> some View {
        HStack(spacing: 12) {
            Button {
                if let request = Playback.next(in: detail, season: tile.season, quality: quality) { play(request) }
            } label: {
                Label(Playback.playLabel(next), systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(next == nil)
            HStack {
                Marks(detail: detail, items: items, season: tile.season)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIconOrIconOnly(labeled))
            .fixedSize()
        }
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
                qualityPicker(items)
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
            HStack(alignment: .firstTextBaseline) {
                Text("Versions").font(.headline)
                Spacer()
                qualityPicker(detail.items)
            }
            .padding(.bottom, 6)
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

    /// The quality to play, when there's a choice, by its short name, in the
    /// heading of what it plays; its full name, as its sources give it, is its
    /// help.
    @ViewBuilder
    private func qualityPicker(_ items: [TitleDetail.Item]) -> some View {
        let labels = Array(Set(items.flatMap { $0.qualities.map(\.label) })).sorted()
        if labels.count > 1 {
            let short = QualityChoice.shortNames(labels, in: items)
            Picker("Quality", selection: $quality) {
                ForEach(labels, id: \.self) { label in
                    Text(short[label] ?? label).tag(Optional(label))
                }
            }
            .fixedSize()
            .controlSize(.small)
            .help(quality.map { QualityChoice.name($0, in: items) } ?? "The quality to play")
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
/// choice that changes only when a person picks another; a gauge of how far
/// they've come while any comes; and deleting them (which sets the choice to Nothing, if it
/// asks for any of them).
private struct DownloadControls: View {
    let detail: TitleDetail
    let items: [TitleDetail.Item]
    let season: Int?
    let quality: String?
    @Environment(Library.self) private var library
    /// What each choice (or the movie) would come to, as of the last
    /// change to the library or its downloads.
    @State private var sizes: [String: Library.DownloadSize] = [:]
    /// What the season's episodes asked for come to, for its gauge.
    @State private var requested: Library.DownloadSize?

    private static let counts = [1, 3, 5, 10]

    var body: some View {
        Group {
            if let season {
                seasonControls(season)
            } else if let item = items.first {
                movieControls("\(detail.key)/\(item.key)")
            }
        }
        .task(id: "\(library.revision) \(library.downloadedBytes) \(detail.key) \(season ?? -1) \(quality ?? "")") {
            if let season {
                sizes = library.downloadSizes(detail.key, choices: ["current"] + Self.counts.map(String.init) + [String(format: "s%02d", season), "unwatched", "all"])
                let asked = items.map { "\(detail.key)/\($0.key)" }.filter(library.isRequested)
                let each = asked.compactMap { library.downloadSizes($0, choices: [""])[""] }
                requested = .init(choice: "", size: each.reduce(0) { $0 + $1.size }, needed: each.reduce(0) { $0 + $1.needed })
            } else if let item = items.first {
                sizes = library.downloadSizes("\(detail.key)/\(item.key)", choices: [""], quality: quality)
            }
        }
    }

    /// A size, as Finder gives it ("4.2 GB").
    private static func bytes(_ n: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }

    /// Whether what isn't here yet fits in the space downloads may take.
    private func fits(_ size: Library.DownloadSize?) -> Bool {
        guard let size, let space = library.spaceForDownloads else { return true }
        return size.needed <= space
    }

    /// A choice in the menu, with its size (all its files'), orange if
    /// what isn't here yet wouldn't fit. Only then colored: a menu item
    /// given any color, the primary one too, is drawn as if disabled.
    @ViewBuilder
    private func item(_ choice: String) -> some View {
        let size = sizes[choice]
        let text = Text(size.map { "\(Self.title(choice))  \(Self.bytes($0.size))" } ?? Self.title(choice))
        if fits(size) {
            text.tag(choice)
        } else {
            text.foregroundStyle(.orange).tag(choice)
        }
    }

    /// One row, nothing in it coming or going, as a season's: Download,
    /// dimmed once it's here or coming; a gauge of how far it's come, its
    /// place kept while it doesn't come; and the trash button, canceling while it comes,
    /// deleting once it's here, dimmed while neither. Keeping it is in the
    /// tile's context menu, as an episode's is in its row's.
    @ViewBuilder
    private func movieControls(_ key: String) -> some View {
        let held = library.isDownloaded(key)
        let coming = !held && library.isWanted(key)
        let size = sizes[""]
        HStack {
            // Its size, all its files', fixed for the quality picked; orange
            // if what isn't here yet wouldn't fit.
            Button(size.map { "Download \(Self.bytes($0.size))" } ?? "Download", systemImage: "arrow.down.circle") { library.download(key, quality: quality) }
                .foregroundStyle(fits(size) ? AnyShapeStyle(.foreground) : AnyShapeStyle(.orange))
                .buttonStyle(.bordered)
                .disabled(held || coming)
                .help(fits(size) ? "Download it to this Mac, to watch without a network" : "Download it to this Mac: more than the space downloads may take now")
            DownloadGauge(value: library.downloadProgress([key], of: size))
                .opacity(coming ? 1 : 0)
            Spacer()
            Button(coming ? "Cancel Download" : "Delete Download", systemImage: "trash") {
                if coming { library.removeDownload(key) } else { library.deleteDownload(key) }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(!held && !coming)
            .help(Self.deleteHelp(library, key, coming: coming))
        }
        .controlSize(.small)
    }

    /// The movie's trash button's help, saying what it does and, once
    /// watched, what's become of the download.
    private static func deleteHelp(_ library: Library, _ key: String, coming: Bool) -> String {
        if coming { return "Stop downloading it" }
        if let done = library.done(key) {
            return done.deletable ? "Delete it from this Mac (watched: it goes when its space is needed anyway)" : "Delete it from this Mac: watched, and the only copy (or keep it, in its context menu)"
        }
        if library.onlyCopies(key) > 0 { return "Delete it from this Mac: the only copy" }
        return library.isKept(key) ? "Delete it from this Mac (kept, however it's watched)" : "Delete it from this Mac"
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
        // One row, nothing in it coming or going: the gauge's place kept
        // while nothing comes, the trash button dimmed while nothing's here.
        HStack {
            // The open menu gives each choice's size, and the space free; the
            // closed one, only the choice, which nothing but picking changes.
            Picker("Download", selection: Binding(get: { chosen }, set: { library.chooseDownloads(detail.key, $0) })) {
                Section {
                    Text("Nothing").tag("")
                    item("current")
                    ForEach(Self.counts, id: \.self) { n in item(String(n)) }
                    // A count chosen elsewhere (the core takes any).
                    if Int(chosen).map({ !Self.counts.contains($0) }) ?? false { item(chosen) }
                } header: {
                    if let space = library.spaceForDownloads { Text("\(Self.bytes(space)) free") }
                }
                Section {
                    item(here)
                    // Another season's, as chosen there.
                    if chosen.hasPrefix("s"), chosen != here { item(chosen) }
                    item("unwatched")
                    item("all")
                }
            } currentValueLabel: {
                Text(Self.title(chosen))
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help("Which of the series' episodes download to this Mac as it's watched, to watch without a network; watched ones go as their space is needed, but for All")
            DownloadGauge(value: library.downloadProgress(keys, of: requested))
                .opacity(pending ? 1 : 0)
            Spacer()
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
        case "": return "Nothing"
        case "current": return "Current"
        case "1": return "Next"
        case "unwatched": return "Unwatched"
        case "all": return "All"
        default: return "Next \(choice)"
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
            DownloadGauge(value: library.downloadProgress(key))
        }
    }
}

/// How far a download has come, as a round gauge, as Finder and Safari
/// show one; empty while it waits its turn.
private struct DownloadGauge: View {
    let value: Double

    var body: some View {
        ProgressView(value: value)
            .progressViewStyle(.circular)
            .controlSize(.mini)
            .help("Downloading: \(value.formatted(.percent.precision(.fractionLength(0))))")
    }
}

/// An item's download, in its context menu (an episode's row's, or a
/// movie's tile's).
struct DownloadMenuItems: View {
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

/// Labeled, or icons alone.
private struct TitleAndIconOrIconOnly: LabelStyle {
    let labeled: Bool

    func makeBody(configuration: Configuration) -> some View {
        if labeled { Label(configuration) } else { Label(configuration).labelStyle(.iconOnly) }
    }
}

extension LabelStyle where Self == TitleAndIconOrIconOnly {
    static func titleAndIconOrIconOnly(_ labeled: Bool) -> TitleAndIconOrIconOnly { .init(labeled: labeled) }
}
#endif
