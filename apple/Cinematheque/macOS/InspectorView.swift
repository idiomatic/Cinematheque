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
            // Before Resume, as a player's timeline starts at its leading edge.
            if next?.inProgress == true {
                Button {
                    if let request = Playback.next(in: detail, season: tile.season, quality: quality, overFromStart: true) { play(request) }
                } label: {
                    Label("Start Over", systemImage: Playback.startOverSymbol)
                        .labelStyle(.titleAndIconOrIconOnly(labeled))
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help("Start Over")
            }
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
                    Text(item.label)
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
                    Text(item.name)
                        .lineLimit(1)
                    Spacer()
                    DownloadMark(key: "\(detail.key)/\(item.key)")
                    if let runtime = item.runtime {
                        Text(runtime).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                if item.inProgress, item.duration > 0 {
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
            DownloadMenuItems(key: "\(detail.key)/\(item.key)", item: item, quality: quality)
            Divider()
            Button(item.watched ? "Mark as Unwatched" : "Mark as Watched") {
                library.setWatched("\(detail.key)/\(item.key)", !item.watched)
            }
        }
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

    private static let counts = [1, 3, 10]

    var body: some View {
        Group {
            if let season {
                seasonControls(season)
            } else if let item = items.first {
                movieControls("\(detail.key)/\(item.key)")
            }
        }
        .task(id: "\(library.revision) \(library.downloadedBytes) \(detail.key) \(season ?? -1) \(quality ?? "")") {
            if season != nil {
                sizes = library.downloadSizes(detail.key, choices: Self.counts.map(String.init) + ["all"])
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

    /// A choice in the menu, with its size (all its files') at the item's
    /// trailing edge, orange if what isn't here yet wouldn't fit.
    private func item(_ choice: String) -> DetailedPopUp.Choice {
        let size = sizes[choice]
        return .init(tag: choice, title: Self.title(choice), detail: size.map { Self.bytes($0.size) }, warning: !fits(size))
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
                .help(fits(size) ? "Download to watch offline" : "More than downloads have room for")
            DownloadGauge(value: library.downloadProgress([key], of: size))
                .opacity(coming ? 1 : 0)
            Spacer()
            showInFinder
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

    /// The movie's trash button's help: what it does, warning of an only
    /// copy.
    private static func deleteHelp(_ library: Library, _ key: String, coming: Bool) -> String {
        if coming { return "Stop downloading it" }
        return library.onlyCopies(key) > 0 ? "The only copy" : "Delete download"
    }

    @ViewBuilder
    private func seasonControls(_ season: Int) -> some View {
        let key = detail.key + String(format: "/e/s%02d", season)
        let keys = items.map { "\(detail.key)/\($0.key)" }
        let held = keys.filter(library.isDownloaded).count
        let chosen = library.downloadChoice(detail.key)
        // Whether any of this season's episodes the choice (or a person, one
        // by one) asks for hasn't come yet.
        let pending = keys.contains { library.isRequested($0) && !library.isDownloaded($0) }
        // One row, nothing in it coming or going: the gauge's place kept
        // while nothing comes, the trash button dimmed while nothing's here.
        HStack {
            // The open menu gives each choice's size, and the space free; the
            // closed one, only the choice, which nothing but picking changes.
            // A count chosen elsewhere (the core takes any).
            let other = Int(chosen).map { !Self.counts.contains($0) } ?? false ? [item(chosen)] : []
            HStack(spacing: 6) {
                // As a SwiftUI pop-up's own label is, whatever the controls' size.
                Text("Download").font(.system(size: NSFont.systemFontSize))
                DetailedPopUp(
                    sections: [
                        .init(choices: [.init(tag: "", title: "Nothing")] + Self.counts.map { item(String($0)) } + other),
                        .init(choices: [item("all")]),
                    ],
                    footer: library.spaceForDownloads.map { ("Free Space", Self.bytes($0)) },
                    selection: chosen,
                    label: Self.title(chosen),
                    select: { library.chooseDownloads(detail.key, $0) }
                )
                .fixedSize()
            }
            .help("Episodes to download as you watch")
            DownloadGauge(value: library.downloadProgress(keys, of: requested))
                .opacity(pending ? 1 : 0)
            Spacer()
            showInFinder
            Button(season == 0 ? "Delete Specials' Downloads" : "Delete Season's Downloads", systemImage: "trash") { library.deleteDownload(key) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(held == 0)
                .help((library.onlyCopies(key) > 0 ? "Delete the season's downloads: some are the only copies" : "Delete the season's downloads") + (keys.contains { library.isRequested($0) && library.isDownloaded($0) } && !chosen.isEmpty ? "; Download becomes Nothing" : ""))
        }
        .controlSize(.small)
    }

    /// Beside the trash button: Show in Finder, what of it is on this Mac
    /// (downloaded, or in its folders), else Open in Browser, a server's
    /// listing of it; dimmed while nothing holds it. Its context menu,
    /// every place that does.
    private var showInFinder: some View {
        let files = items.compactMap(library.fileHere)
        let server = library.places(items).first { !$0.inFinder }
        let title = files.isEmpty && server != nil ? "Open in Browser" : "Show in Finder"
        return Button(title, systemImage: files.isEmpty && server != nil ? "safari" : "folder") {
            if files.isEmpty { server?.open() } else { NSWorkspace.shared.activateFileViewerSelecting(files) }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .disabled(files.isEmpty && server == nil)
        .help(title)
        .contextMenu { PlaceItems(items: items) }
    }

    /// A choice of episodes, as the menu says it: short, read after its
    /// label ("Download Next 3").
    private static func title(_ choice: String) -> String {
        switch choice {
        case "": return "Nothing"
        case "1": return "Next"
        case "all": return "All"
        default: return "Next \(choice)"
        }
    }
}

/// Beside an episode: downloaded, or downloading.
private struct DownloadMark: View {
    let key: String
    @Environment(Library.self) private var library

    var body: some View {
        if library.isDownloaded(key) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.secondary)
                .help("Downloaded")
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
    let item: TitleDetail.Item
    let quality: String?
    @Environment(Library.self) private var library

    var body: some View {
        let file = library.fileHere(item)
        if let file {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
        }
        // Every place that holds it, if there's more than Show in Finder's.
        let places = library.places([item])
        if places.count > (file == nil ? 0 : 1) {
            Menu("Show Files") { PlaceItems(items: [item]) }
        }
        if library.isDownloaded(key) {
            Button(library.onlyCopies(key) > 0 ? "Delete Only Copy…" : "Delete Download") { library.deleteDownload(key) }
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
/// Where a title's files are: its download, then each quality's sources,
/// a folder on this Mac (shown in Finder) or a server (its folder's
/// listing, in the browser), so none needs finding by hand.
struct Place: Identifiable {
    let id: String
    let title: String
    let symbol: String
    /// Shown in Finder, else opened in the browser.
    let inFinder: Bool
    let open: () -> Void
}

extension Library {
    func places(_ items: [TitleDetail.Item]) -> [Place] {
        var out: [Place] = []
        let copies = items.flatMap { $0.qualities.flatMap(\.copies) }
        let downloaded = copies.compactMap(Playback.downloaded).compactMap { URL(string: $0.url) }
        if !downloaded.isEmpty {
            out.append(.init(id: "download", title: "Download", symbol: "arrow.down.circle", inFinder: true) { NSWorkspace.shared.activateFileViewerSelecting(downloaded) })
        }
        // By quality, then source, as the items list them.
        var order: [String] = []
        var groups: [String: (short: String, source: Source, copies: [TitleDetail.Copy])] = [:]
        for item in items {
            for quality in item.qualities {
                for copy in quality.copies where !copy.unavailable {
                    guard let source = sources.first(where: { $0.id == copy.source }), !source.managed else { continue }
                    let key = "\(quality.label)|\(source.id)"
                    if groups[key] == nil {
                        order.append(key)
                        groups[key] = (quality.short, source, [])
                    }
                    groups[key]!.copies.append(copy)
                }
            }
        }
        for key in order {
            guard let g = groups[key] else { continue }
            if let folder = folder(of: g.source) {
                guard !unavailableFolders.contains(folder.prefix) else { continue }
                let files = g.copies.compactMap { copy -> URL? in
                    guard let path = String(copy.url.dropFirst(folder.url.count)).removingPercentEncoding else { return nil }
                    return URL(fileURLWithPath: folder.path).appending(path: path)
                }
                out.append(.init(id: key, title: "\(g.short) — \(folder.name)", symbol: "folder", inFinder: true) { NSWorkspace.shared.activateFileViewerSelecting(files) })
            } else if let listing = URL(string: g.copies[0].url)?.deletingLastPathComponent() {
                out.append(.init(id: key, title: "\(g.short) — \(g.source.displayName)", symbol: "safari", inFinder: false) { NSWorkspace.shared.open(listing) })
            }
        }
        return out
    }
}

/// A menu's items for a title's places (see `Library.places`), under what
/// opening them does, so a server's isn't taken for a folder's.
struct PlaceItems: View {
    let items: [TitleDetail.Item]
    @Environment(Library.self) private var library

    var body: some View {
        let places = library.places(items)
        let here = places.filter(\.inFinder)
        let servers = places.filter { !$0.inFinder }
        if !here.isEmpty {
            Section("Show in Finder") { buttons(here) }
        }
        if !servers.isEmpty {
            Section("Open in Browser") { buttons(servers) }
        }
    }

    /// With their symbols, which macOS's menus leave out unless asked.
    private func buttons(_ places: [Place]) -> some View {
        ForEach(places) { place in
            Button(place.title, systemImage: place.symbol, action: place.open)
                .labelStyle(.titleAndIcon)
        }
    }
}
#endif
