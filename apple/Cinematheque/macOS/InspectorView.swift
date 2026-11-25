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
                heading(detail)
                if let detail {
                    controls(detail)
                    metadata(detail)
                    if tile.season != nil { episodes(detail) }
                    if tile.season == nil, detail.items.count > 1 { versions(detail) }
                }
            }
            .padding(16)
        }
        .task(id: library.detailsRevision) {
            detail = library.detail(tile.key)
            // At first, the best of what Play plays, so it needs no stand-in.
            if quality == nil { quality = detail.flatMap { d in Playback.nextItem(d, season: tile.season).flatMap { d.quality(for: [$0]) } ?? d.quality(for: Playback.items(d, season: tile.season)) } }
        }
        .task(id: tile.id) { await library.describeItems(of: tile.key, season: tile.season) }
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

    /// Its name, and its marks (lists, watched) at the line's end, as a
    /// tile's are, quieter than Play: there, beside Play, their words set
    /// the inspector's least width, which grew beyond the person's say.
    private func heading(_ detail: TitleDetail?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tile.name).font(.title2.weight(.semibold))
                Text([tile.seasonName, tile.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let detail {
                HStack(spacing: 10) {
                    Marks(detail: detail, items: Playback.items(detail, season: tile.season), season: tile.season)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .labelStyle(.iconOnly)
                .fixedSize()
            }
        }
    }

    @ViewBuilder
    private func controls(_ detail: TitleDetail) -> some View {
        let items = Playback.items(detail, season: tile.season)
        let next = Playback.nextItem(detail, season: tile.season)
        VStack(alignment: .leading, spacing: 10) {
            // The quality first, so choosing it changes only what's below.
            qualityPicker(items)
            playRow(detail, next: next)
            if tile.season == nil, let item = items.first, item.inProgress, item.duration > 0 {
                progress(item, key: "\(detail.key)/\(item.key)")
            }
            DownloadControls(detail: detail, items: items, season: tile.season, quality: quality)
        }
    }

    /// Play filling its row, Start Over (its symbol, named as help) before
    /// it, as a player's timeline starts at its leading edge.
    private func playRow(_ detail: TitleDetail, next: TitleDetail.Item?) -> some View {
        HStack(spacing: 12) {
            if next?.inProgress == true {
                Button {
                    if let request = Playback.next(in: detail, season: tile.season, quality: quality)?.fromBeginning { play(request) }
                } label: {
                    Label("Start Over", systemImage: Playback.startOverSymbol)
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help("Start Over")
            }
            Button {
                if let request = Playback.next(in: detail, season: tile.season, quality: quality) { play(request) }
            } label: {
                Label(Playback.playLabel(next, in: detail, quality: quality), systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(next == nil)
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
            Text("Episodes").font(.headline)
                .padding(.bottom, 6)
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                ItemRow(item: item, detail: detail, quality: quality, widest: items.widestRuntime) {
                    if let request = Playback.request(detail, items: items, from: index, quality: quality) { play(request) }
                }
                Divider()
            }
        }
    }

    /// A movie's versions (e.g., a director's cut), each playable.
    private func versions(_ detail: TitleDetail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Versions").font(.headline)
                .padding(.bottom, 6)
            ForEach(detail.items) { item in
                ItemRow(item: item, detail: detail, quality: quality, widest: detail.items.widestRuntime) {
                    if let request = Playback.request(detail, items: [item], from: 0, quality: quality) { play(request) }
                }
                Divider()
            }
        }
    }

    /// The quality to play and download, by its short name, in a row of its
    /// own above Play; its full name, as its sources give it, is its help.
    /// Of one quality, it's said, not offered, so a title still says what
    /// it plays in. Where the inspector's narrow, the picker gives up its
    /// label.
    @ViewBuilder
    private func qualityPicker(_ items: [TitleDetail.Item]) -> some View {
        let labels = QualityChoice.labels(items)
        if labels.count == 1, let label = labels.first {
            LabeledContent("Quality", value: QualityChoice.shortNames(labels, in: items)[label] ?? label)
                .fixedSize()
                .help(QualityChoice.name(label, in: items))
        } else if labels.count > 1 {
            let short = QualityChoice.shortNames(labels, in: items)
            let picker = Picker("Quality", selection: $quality) {
                ForEach(labels, id: \.self) { label in
                    Text(short[label] ?? label).tag(Optional(label))
                }
            }
            .help(quality.map { QualityChoice.name($0, in: items) } ?? "The quality to play")
            ViewThatFits(in: .horizontal) {
                picker.fixedSize()
                picker.labelsHidden().fixedSize()
            }
        }
    }
}

/// A placeholder's details: a title not in the library yet, put on a list
/// by name, which its file's tile takes the place of when it comes.
struct WantedInspectorView: View {
    let wanted: UserList.Wanted
    /// Selects it anew, under its key as edited.
    let select: (String) -> Void
    @Environment(Library.self) private var library
    @State private var editing = false

    var body: some View {
        let tile = Tile(wanted: wanted)
        VStack(alignment: .leading, spacing: 12) {
            // Set as a title's heading is.
            VStack(alignment: .leading, spacing: 2) {
                Text(wanted.name).font(.title2.weight(.semibold))
                Text([tile.seasonName, tile.year.map(String.init), tile.isSeries ? "Series" : "Movie"].compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
            }
            Text("Not in the library yet. It takes this place on its list as it comes, if its file is named as this is.")
                .foregroundStyle(.secondary)
            if !wanted.note.isEmpty {
                // An article's address, opened in the browser; else the note.
                if let url = URL(web: wanted.note) {
                    Link(wanted.note, destination: url).lineLimit(2)
                } else {
                    Text(wanted.note).textSelection(.enabled)
                }
            }
            if library.isWantedByMe(wanted.key) {
                HStack {
                    Button("Edit…") { editing = true }
                    Button("Remove from List") { library.unwant(wanted.key) }
                }
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $editing) {
            WantSheet(heading: "Edit \(wanted.name)", action: "Save", fields: Wanting(wanted)) { changed in
                if let key = library.editWant(wanted.key, changed) { select(key) }
            }
        }
    }
}

/// A title not in the library yet, by name, to put on a list or change
/// there: a movie, or a series' season, with its year (as its file will be
/// named, so it's matched as it comes), and a note, as an article's
/// address.
struct WantSheet: View {
    let heading: String
    /// The confirming button's name ("Add", "Save").
    let action: String
    let save: (Wanting) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kind: TitleKind
    @State private var name: String
    @State private var year: String
    @State private var season: Int
    @State private var note: String

    init(heading: String, action: String, fields: Wanting = .init(), save: @escaping (Wanting) -> Void) {
        self.heading = heading
        self.action = action
        self.save = save
        _kind = State(initialValue: fields.kind)
        _name = State(initialValue: fields.name)
        _year = State(initialValue: fields.year.map(String.init) ?? "")
        _season = State(initialValue: fields.season ?? 1)
        _note = State(initialValue: fields.note)
    }

    /// Adding to `list`.
    static func adding(to list: UserList, in library: Library) -> WantSheet {
        WantSheet(heading: "Add Missing Title to \(list.name)", action: "Add") { library.want(on: list.id, $0) }
    }

    var body: some View {
        Form {
            // Its title, in the form, as a sheet shows no navigation title.
            Section {
                Picker("Kind", selection: $kind) {
                    Text("Movie").tag(TitleKind.movie)
                    Text("Series").tag(TitleKind.series)
                }
                .pickerStyle(.segmented)
                TextField("Name", text: $name)
                TextField("Year", text: $year, prompt: Text("As its file will have it"))
                if kind == .series {
                    Stepper("Season \(season)", value: $season, in: 0...999)
                }
                TextField("Note", text: $note, prompt: Text("Optional, as an article's address"))
            } header: {
                Text(heading).font(.headline)
            } footer: {
                Text("It takes this place on the list as it comes, if its file is named as this is.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(action) {
                    var fields = Wanting()
                    fields.kind = kind
                    fields.name = name
                    fields.year = Int(year)
                    fields.season = kind == .series ? season : nil
                    fields.note = note
                    save(fields)
                    dismiss()
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || (!year.isEmpty && Int(year) == nil))
            }
        }
    }
}

/// A series' details, selected as a whole on the Series shelf: its
/// cover, Play for the season to watch, the whole series' watched mark,
/// its description, and its seasons, each selected by clicking it.
struct SeriesInspectorView: View {
    let series: Tile
    /// Selects one of its seasons, by its tile's ID.
    let select: (String) -> Void
    @Environment(Library.self) private var library
    @Environment(\.play) private var play
    @State private var detail: TitleDetail?

    var body: some View {
        let seasons = Library.seasons(of: series.key, in: library.tiles)
        let up = Library.nextSeason(seasons)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay { CoverImage(cover: series.cover, thumb: series.thumb, title: series.name, size: .large, fit: true) }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                    .frame(maxHeight: 340)
                    .frame(maxWidth: .infinity)
                // The whole series' watched mark at its name's line's end, as
                // a season's marks are: a status that pressing toggles.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(series.name).font(.title2.weight(.semibold))
                        Text([Library.seasonsCaption(seasons), series.year.map(String.init)].filter { $0?.isEmpty == false }.compactMap { $0 }.joined(separator: " · "))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    WatchedToggle(watched: series.watched) { library.markSeriesWatched(series, !series.watched) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(series.watched ? "Mark the series as unwatched" : "Mark the series as watched")
                    .fixedSize()
                }
                if let detail {
                    let next = Playback.nextItem(detail, season: up?.season)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 12) {
                            Button {
                                if let request = Playback.next(in: detail, season: up?.season) { play(request) }
                            } label: {
                                Label(Playback.playLabel(next, in: detail, quality: nil), systemImage: "play.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(next == nil)
                        }
                        if let name = up?.seasonName {
                            Text("Up next: \(name)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    // A series' (no runtime, which a movie's facts give as
                    // its first item's).
                    let facts = detail.facts(season: up?.season ?? 0)
                    if !facts.isEmpty { Text(facts).foregroundStyle(.secondary) }
                    if let description = detail.fields["description"] {
                        Text(description).textSelection(.enabled)
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("Seasons").font(.headline)
                        .padding(.bottom, 6)
                    ForEach(seasons) { season in
                        Button { select(season.id) } label: {
                            // Marked as its tile is: downloaded, on a list,
                            // and watched at its line's end, partway by a
                            // thin bar.
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(season.seasonName ?? "")
                                    Spacer()
                                    if library.downloadedTiles.contains(season.id) { DownloadedMark() }
                                    if library.isListed(season) { ListedMark() }
                                    if season.watched { WatchedMark() }
                                    Text("\(season.items) \(season.items == 1 ? "episode" : "episodes")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if season.started, !season.watched {
                                    ProgressView(value: season.progress).controlSize(.mini)
                                }
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
            .padding(16)
        }
        .task(id: library.detailsRevision) { detail = library.detail(series.key) }
    }
}

/// A version, part, or episode: played by its button, with its download's
/// mark, and its downloading and watched mark in its context menu.
private struct ItemRow: View {
    let item: TitleDetail.Item
    let detail: TitleDetail
    let quality: String?
    /// Its list's widest runtime, the width its own keeps, so the marks
    /// line up.
    let widest: String?
    let play: () -> Void
    @Environment(Library.self) private var library

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: play) {
                Image(systemName: "play.circle")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .help("Play")
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    StandIn(text: item.name, item: item, quality: quality, detail: detail)
                        .lineLimit(item.season == nil ? nil : 1)
                    Spacer()
                    DownloadMark(key: "\(detail.key)/\(item.key)")
                    if item.watched { WatchedMark() }
                    RuntimeText(runtime: item.runtime, widest: widest).font(.caption).foregroundStyle(.secondary)
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
            DownloadMenuItems(key: "\(detail.key)/\(item.key)", items: [item], title: detail.key)
            Divider()
            Button(item.watched ? "Mark as Unwatched" : "Mark as Watched") {
                library.setWatched("\(detail.key)/\(item.key)", !item.watched)
            }
        }
    }
}

/// Downloading to this Mac: a movie (see `TitleDetail.downloadTarget`), or for a
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
    /// The pop-up's Available item's tag, which no choice is.
    private static let available = "-available"

    var body: some View {
        Group {
            if let season {
                seasonControls(season)
            } else if let target = detail.downloadTarget {
                movieControls(target)
            }
        }
        .task(id: "\(library.revision) \(library.downloadedBytes) \(detail.key) \(season ?? -1) \(quality ?? "")") {
            if season != nil {
                sizes = library.downloadSizes(detail.key, choices: Self.counts.map(String.init) + ["all"])
                let asked = items.map { "\(detail.key)/\($0.key)" }.filter(library.isRequested)
                let each = asked.compactMap { library.downloadSizes($0, choices: [""])[""] }
                requested = .init(choice: "", size: each.reduce(0) { $0 + $1.size }, needed: each.reduce(0) { $0 + $1.needed })
            } else if let target = detail.downloadTarget {
                sizes = library.downloadSizes(target.key, choices: [""], quality: quality)
            }
        }
    }

    /// A size, as Finder gives it ("4.2 GB").
    private static func bytes(_ n: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }

    /// Whether what isn't here yet fits in the space available for
    /// downloads.
    private func fits(_ size: Library.DownloadSize?) -> Bool {
        guard let size, let space = library.availableForDownloads else { return true }
        return size.needed <= space
    }

    /// A warning that what isn't here yet wouldn't fit, saying what would;
    /// else nothing, as the control says the rest.
    private func fitHelp(_ size: Library.DownloadSize?) -> String {
        guard !fits(size), let space = library.availableForDownloads else { return "" }
        return "More than the \(Self.bytes(space)) available for downloads"
    }

    /// A choice in the pop-up, with its size (all its files'), a warning
    /// symbol if what isn't here yet wouldn't fit, as the other download
    /// menus have it.
    private func choice(_ choice: String) -> some View {
        let size = sizes[choice]
        let title = size.map { "\(Self.title(choice)) — \(Self.bytes($0.size))" } ?? Self.title(choice)
        return Group {
            if fits(size) { Text(title) } else { Label(title, systemImage: "exclamationmark.triangle").labelStyle(.titleAndIcon) }
        }
        .tag(choice)
    }

    /// One row, nothing in it coming or going, as a season's: Download,
    /// dimmed once it's here or coming; a gauge of how far it's come, its
    /// place kept while it doesn't come; and the trash button, canceling while it comes,
    /// deleting once it's here, dimmed while neither. Keeping it is in the
    /// tile's context menu, as an episode's is in its row's.
    @ViewBuilder
    private func movieControls(_ target: (key: String, items: [TitleDetail.Item], name: String)) -> some View {
        let key = target.key
        let keys = target.items.map { "\(detail.key)/\($0.key)" }
        let held = keys.allSatisfy(library.isDownloaded)
        let coming = !held && keys.contains(where: library.isWanted)
        let size = sizes[""]
        // Of several versions, the one it downloads, by name.
        let what = detail.items.count > 1 ? "Download \(target.name)" : "Download"
        HStack {
            // Its size, all its files', fixed for the quality picked; orange
            // if what isn't here yet wouldn't fit. Another quality by
            // Control-click.
            // The quality it comes in, dimmed, if not the one picked, as the
            // rows say it.
            let standIn = target.items.first.flatMap { Playback.standIn($0, for: quality, in: detail) }.map { " (\($0.short))" } ?? ""
            let bytes = size.map { " \(Self.bytes($0.size))" } ?? ""
            // Its words where they fit, else its symbol and size, the words
            // as help: a button's title doesn't shrink, so a long one set
            // the inspector's least width.
            ViewThatFits(in: .horizontal) {
                downloadButton(key: key, items: target.items, held: held, coming: coming, size: size, help: fitHelp(size)) {
                    Text(what) + Text(standIn).foregroundStyle(.secondary) + Text(bytes)
                }
                downloadButton(key: key, items: target.items, held: held, coming: coming, size: size, help: [what + standIn + bytes, fitHelp(size)].filter { !$0.isEmpty }.joined(separator: ": ")) {
                    Text(bytes.trimmingCharacters(in: .whitespaces))
                }
            }
            DownloadGauge(value: library.downloadProgress(keys, of: size))
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
    }

    /// A movie's Download button, `title` beside its symbol, `help` its help:
    /// orange if what isn't here yet wouldn't fit; another quality by
    /// Control-click.
    private func downloadButton(key: String, items: [TitleDetail.Item], held: Bool, coming: Bool, size: Library.DownloadSize?, help: String, title: () -> Text) -> some View {
        Button { library.download(key, quality: quality) } label: {
            Label { title() } icon: { Image(systemName: "arrow.down.circle") }
        }
        .foregroundStyle(fits(size) ? AnyShapeStyle(.foreground) : AnyShapeStyle(.orange))
        .buttonStyle(.bordered)
        .disabled(held || coming)
        .help(help)
        // Under a heading, as Show in Finder's places are.
        .contextMenu { if !held { DownloadSection(key: key, items: items) } }
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
            // A pop-up, so the choice opens under the pointer, each with its
            // size, then the space available, said, not offered (a disabled
            // item, as the other download menus show text), its tag no
            // choice. A count chosen elsewhere (the core takes any).
            let other = Int(chosen).map { !Self.counts.contains($0) } ?? false
            Picker("Download", selection: Binding(get: { chosen }, set: { if $0 != Self.available { library.chooseDownloads(detail.key, $0) } })) {
                choice("")
                ForEach(Self.counts, id: \.self) { choice(String($0)) }
                if other { choice(chosen) }
                Divider()
                choice("all")
                if let space = library.availableForDownloads {
                    Divider()
                    Text("Available — \(Self.bytes(space))")
                        .tag(Self.available)
                        .selectionDisabled()
                }
            }
            // Narrower than its longest choice, if the inspector is: as
            // wide as that choice, it set the inspector's least width, which
            // grew with sizes and warnings, beyond the person's say.
            .frame(minWidth: 90)
            .layoutPriority(1)
            .help("Episodes to download as you watch")
            DownloadGauge(value: library.downloadProgress(keys, of: requested))
                .opacity(pending ? 1 : 0)
            Spacer()
            showInFinder
            // Canceling what's coming, as nothing's here yet (episodes
            // waiting for a drive, say); else deleting what's here, and
            // canceling the rest.
            let canceling = held == 0
            Button(canceling ? (season == 0 ? "Cancel Specials' Downloads" : "Cancel Season's Downloads") : (season == 0 ? "Delete Specials' Downloads" : "Delete Season's Downloads"), systemImage: "trash") {
                if canceling { library.removeDownload(key) } else { library.deleteDownload(key) }
            }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(held == 0 && !pending)
                .help(canceling ? "Stop downloading the season's episodes" + (chosen.isEmpty ? "" : "; Download becomes Nothing") : (library.onlyCopies(key) > 0 ? "Delete the season's downloads: some are the only copies" : "Delete the season's downloads") + (keys.contains { library.isRequested($0) && library.isDownloaded($0) } && !chosen.isEmpty ? "; Download becomes Nothing" : ""))
        }
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

/// An item's name, and if it lacks the chosen quality, the one it plays
/// instead, dimmed: "Standard (720p Very Fast)".
private struct StandIn: View {
    let text: String
    let item: TitleDetail.Item
    let quality: String?
    let detail: TitleDetail

    var body: some View {
        if let q = Playback.standIn(item, for: quality, in: detail) {
            // Its spaces unbreaking, so it wraps whole, if at all.
            Text(text) + Text(" (\(q.short.replacingOccurrences(of: " ", with: "\u{00A0}")))").foregroundStyle(.secondary)
        } else {
            Text(text)
        }
    }
}

/// Beside an episode: downloaded, or downloading.
private struct DownloadMark: View {
    let key: String
    @Environment(Library.self) private var library

    var body: some View {
        if library.isDownloaded(key) {
            DownloadedMark()
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

/// A download, in a context menu (a row's, or a movie's tile's): `key`,
/// downloading `items` of the title `title`.
struct DownloadMenuItems: View {
    let key: String
    let items: [TitleDetail.Item]
    let title: String
    @Environment(Library.self) private var library

    var body: some View {
        // Every place that holds it, flat, under what opening it does.
        PlaceItems(items: items)
        Divider()
        let keys = items.map { "\(title)/\($0.key)" }
        if keys.allSatisfy(library.isDownloaded) {
            Button(library.onlyCopies(key) > 0 ? "Delete Only Copy…" : "Delete Download") { library.deleteDownload(key) }
        } else {
            // A quality waiting is canceled where it was chosen.
            DownloadSection(key: key, items: items)
        }
    }
}

/// Downloading, in a menu: under a heading, each quality the items have,
/// by its short name, with what its files come to (a warning symbol for one
/// whose files not here yet wouldn't fit, as menus can't be colored), then
/// the space available. One whose copies are all unavailable (a drive
/// unplugged) may still be chosen, to come when it's back, as a clock says.
/// One chosen and still coming is, in its place, its Cancel; choosing
/// another (one that's there) takes its place.
struct DownloadSection: View {
    let key: String
    let items: [TitleDetail.Item]
    @Environment(Library.self) private var library

    var body: some View {
        let space = library.availableForDownloads
        Section("Download") {
            ForEach(QualityChoice.labels(items), id: \.self) { label in
                let qualities = items.compactMap { $0.qualities.first { $0.label == label } }
                let size = qualities.reduce(0) { $0 + ($1.copies.first?.size ?? 0) }
                let short = qualities.first?.short ?? label
                // What isn't here yet, as the inspector's Download weighs it.
                let needed = library.downloadSizes(key, choices: [""], quality: label)[""]?.needed ?? size
                let fits = space.map { needed <= $0 } ?? true
                // Every copy unavailable (a drive unplugged): still chosen,
                // to come when it's back, as said.
                let away = qualities.allSatisfy { $0.copies.allSatisfy(\.unavailable) } ? qualities.first?.copies.first.map { library.sourceName($0.source) } : nil
                if library.wantedQualities(key).contains(label) {
                    Button("Cancel \(short) Download" + (away.map { " (waiting for \($0))" } ?? ""), systemImage: "xmark.circle") {
                        library.removeDownload(key)
                    }
                } else {
                    let title = "\(short) — \(Self.bytes(size))" + (away.map { ", when \($0) is back" } ?? "")
                    Button(title, systemImage: away != nil ? "clock" : fits ? "arrow.down.circle" : "exclamationmark.triangle") {
                        library.download(key, quality: label)
                    }
                }
            }
            if let space {
                // Said, not offered: a menu shows text as a dimmed item.
                Text("Available — \(Self.bytes(space))")
            }
        }
        .labelStyle(.titleAndIcon)
    }

    private static func bytes(_ n: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }
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
        // By quality, then source.
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
        // Highest resolution first, as the picker lists them.
        let ranked = QualityChoice.labels(items)
        let rank = { (key: String) in ranked.firstIndex(of: String(key.prefix { $0 != "|" })) ?? ranked.count }
        for key in order.enumerated().sorted(by: { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }).map(\.element) {
            guard let g = groups[key] else { continue }
            if let folder = folder(of: g.source) {
                guard !unavailableFolders.contains(folder.prefix) else { continue }
                let files = g.copies.compactMap { Library.file(of: $0, in: folder, at: g.source) }
                out.append(.init(id: key, title: "\(g.short) — \(folder.name)", symbol: "folder", inFinder: true) { NSWorkspace.shared.activateFileViewerSelecting(files) })
            } else if let listing = URL(web: g.copies[0].url)?.deletingLastPathComponent() {
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
