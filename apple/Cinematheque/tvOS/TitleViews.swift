#if os(tvOS)
import SwiftUI

/// A movie's page: its cover over a blurred backdrop of it, Play or Resume,
/// the watchlist and watched marks, its versions, and its description.
/// How a title's page opens: shown, or playing what Play plays at once,
/// as the Top Shelf's select and Play/Pause do.
enum Opening { case show, play }

struct MovieView: View {
    let tile: Tile
    @Environment(Library.self) private var library
    @State private var detail: TitleDetail?
    @State private var playing: PlayRequest?
    /// The quality chosen in its picker, if one was.
    @State private var quality: String?
    @FocusState private var playFocused: Bool

    /// Playing what Play plays at once, once (a Top Shelf item's Play).
    @State private var playsAtOnce: Bool

    /// With its details as they are, so Play is there to focus first.
    init(tile: Tile, detail: TitleDetail?, opening: Opening = .show) {
        self.tile = tile
        _detail = State(initialValue: detail)
        _playsAtOnce = State(initialValue: opening == .play)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 80) {
            Color.clear
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .frame(width: 460)
                .overlay { CoverImage(cover: tile.cover, aspect: tile.aspect, title: tile.name, size: .large) }
                .clipShape(RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 30) {
                Text(tile.name).font(.title)
                if let detail {
                    Text(detail.facts(season: nil)).foregroundStyle(.secondary)
                    HStack(spacing: 30) {
                        if Playback.nextItem(detail, season: nil)?.inProgress == true {
                            Button("Start Over", systemImage: Playback.startOverSymbol) {
                                playing = Playback.next(in: detail, season: nil, quality: quality)?.fromBeginning
                            }
                        }
                        Button(Playback.playLabel(Playback.nextItem(detail, season: nil), in: detail, quality: quality), systemImage: "play.fill") {
                            playing = Playback.next(in: detail, season: nil, quality: quality)
                        }
                        .focused($playFocused)
                        // What Play plays in, beside it.
                        QualityPicker(detail: detail, items: detail.items, chosen: $quality)
                        // The marks, quieter than what plays: icons, named
                        // for VoiceOver.
                        Marks(detail: detail, items: detail.items).labelStyle(.iconOnly)
                    }
                    if detail.items.count > 1 {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Versions").font(.headline)
                            ForEach(detail.items) { item in
                                Button {
                                    playing = Playback.request(detail, items: [item], from: 0, quality: detail.quality(for: [item], chosen: quality))
                                } label: {
                                    ItemLine(item: item, name: item.label, widest: detail.items.widestRuntime)
                                }
                            }
                        }
                    }
                    if let description = detail.summary {
                        Text(description).lineLimit(8)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(80)
        .background { Backdrop(tile: tile) }
        // Play or Resume first, not Start Over before it.
        .defaultFocus($playFocused, true)
        .task(id: library.detailsRevision) {
            detail = library.detail(tile.key)
            if playsAtOnce, let detail {
                playsAtOnce = false
                playing = Playback.next(in: detail, season: nil, quality: quality)
            }
        }
        .modifier(PlaysFullScreen(request: $playing, startsBlack: playsAtOnce))
    }
}

/// A season's page: its cover, Play or Resume (the season's next
/// unwatched episode, and the rest after it), its lists and marks, and its
/// episodes, each playable; the seasons before and after it a press away.
struct SeasonView: View {
    let tile: Tile
    @Environment(Library.self) private var library
    @State private var detail: TitleDetail?
    /// The season shown, moved to its neighbors in place.
    @State private var season: Int?
    @State private var playing: PlayRequest?
    /// The quality chosen in its picker, if one was.
    @State private var quality: String?
    @FocusState private var focus: Focus?

    private enum Focus: Hashable {
        case play, back, forward
    }

    /// Playing what Play plays at once, once (a Top Shelf item's Play).
    @State private var playsAtOnce: Bool

    /// With its details as they are, so Play is there to focus first: come
    /// a moment later, focus had gone to the seasons' buttons.
    init(tile: Tile, detail: TitleDetail?, opening: Opening = .show) {
        self.tile = tile
        _detail = State(initialValue: detail)
        _playsAtOnce = State(initialValue: opening == .play)
    }

    var body: some View {
        let seasons = Library.seasons(of: tile.key, in: library.tiles)
        let index = seasons.firstIndex { $0.season == (season ?? tile.season) }
        let shown = index.map { seasons[$0] } ?? tile
        HStack(alignment: .top, spacing: 80) {
            // A season's cover in its own shape, square or 4:3, at the top.
            Color.clear
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .frame(width: 460)
                .overlay(alignment: .top) {
                    CoverImage(cover: shown.cover, aspect: shown.aspect, title: shown.name, size: .large, shaped: true)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    // The seasons before and after it in the top corner,
                    // beside the series' name.
                    HStack(spacing: 30) {
                        Text(shown.name).font(.title)
                        Spacer()
                        let back = index.flatMap { $0 > 0 ? seasons[$0 - 1] : nil }
                        let forward = index.flatMap { $0 + 1 < seasons.count ? seasons[$0 + 1] : nil }
                        Neighbor(season: back, forward: false) { season = $0 }
                            .focused($focus, equals: .back)
                        Neighbor(season: forward, forward: true) { season = $0 }
                            .focused($focus, equals: .forward)
                            // Reaching an end, focus goes to the other, as a
                            // dimmed button kept it.
                            .onChange(of: shown.season) {
                                if focus == .forward, forward == nil { focus = .back }
                                if focus == .back, back == nil { focus = .forward }
                            }
                    }
                    // Its whole width, so moving up from Play, at the
                    // other end, reaches them.
                    .focusSection()
                    Text(shown.seasonName ?? "").font(.title3)
                    if let detail {
                        let items = Playback.items(detail, season: shown.season)
                        Text(detail.facts(season: shown.season)).foregroundStyle(.secondary)
                        HStack(spacing: 30) {
                            if Playback.nextItem(detail, season: shown.season)?.inProgress == true {
                                Button("Start Over", systemImage: Playback.startOverSymbol) {
                                    playing = Playback.next(in: detail, season: shown.season, quality: quality)?.fromBeginning
                                }
                            }
                            Button(Playback.playLabel(Playback.nextItem(detail, season: shown.season), in: detail, quality: quality), systemImage: "play.fill") {
                                playing = Playback.next(in: detail, season: shown.season, quality: quality)
                            }
                            .focused($focus, equals: .play)
                            QualityPicker(detail: detail, items: items, chosen: $quality)
                            // The lists and marks, quieter than what plays:
                            // icons, named for VoiceOver.
                            Marks(detail: detail, items: items, season: shown.season).labelStyle(.iconOnly)
                        }
                        if let description = detail.fields["description"] {
                            Text(description).lineLimit(4).foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Episodes").font(.headline)
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                Button {
                                    playing = Playback.request(detail, items: items, from: index, quality: detail.quality(for: items, chosen: quality))
                                } label: {
                                    ItemLine(item: item, widest: items.widestRuntime)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 20)
            }
            .scrollClipDisabled()
        }
        .padding(80)
        .background { Backdrop(tile: shown) }
        .defaultFocus($focus, .play)
        .task(id: library.detailsRevision) {
            detail = library.detail(tile.key)
            if playsAtOnce, let detail {
                playsAtOnce = false
                playing = Playback.next(in: detail, season: shown.season, quality: quality)
            }
        }
        // Its other episodes, described as they're shown.
        .task(id: shown.season) { await library.describeItems(of: tile.key, season: shown.season) }
        .modifier(PlaysFullScreen(request: $playing, startsBlack: playsAtOnce))
    }
}

/// The season before or after, by name, with a chevron; at the end of the
/// series, the chevron alone, dimmed.
private struct Neighbor: View {
    let season: Tile?
    let forward: Bool
    let go: (Int?) -> Void

    var body: some View {
        let symbol = forward ? "chevron.forward" : "chevron.backward"
        Button { go(season?.season) } label: {
            if let name = season?.seasonName {
                if forward {
                    HStack(spacing: 12) { Text(name); Image(systemName: symbol) }
                } else {
                    HStack(spacing: 12) { Image(systemName: symbol); Text(name) }
                }
            } else {
                Image(systemName: symbol).accessibilityLabel(forward ? "Next Season" : "Previous Season")
            }
        }
        .disabled(season == nil)
    }
}

/// A title's cover, blurred, behind its page.
private struct Backdrop: View {
    let tile: Tile

    var body: some View {
        CoverImage(cover: tile.cover, aspect: tile.aspect, title: "", size: .large)
            .blur(radius: 60)
            .opacity(0.35)
            .ignoresSafeArea()
    }
}

/// A placeholder's page: a title not in the library yet, on a list by
/// name, as the Mac's inspector shows one (the command-line app adds and
/// removes them).
struct WantedPage: View {
    let key: String
    @Environment(Library.self) private var library

    var body: some View {
        let fields = library.wanted(key).map(Wanting.init) ?? .init()
        SettingsPage(title: fields.name, explanation: "Not in the library yet. It takes this place on its list as it comes, if its file is named as this is.") {
            Form {
                Section {
                    ValueLabel(title: "Kind", value: fields.kind == .series ? "Series" : "Movie")
                    if let year = fields.year { ValueLabel(title: "Year", value: String(year)) }
                    if fields.kind == .series { ValueLabel(title: "Season", value: String(fields.season ?? 1)) }
                    if !fields.note.isEmpty { ValueLabel(title: "Note", value: fields.note) }
                }
                .listRowInsets(SettingsView.rowInsets)
            }
            .scrollClipDisabled()
        }
    }
}

#endif
