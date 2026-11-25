#if !os(macOS)
import SwiftUI

/// How a title's page opens: shown, or playing what Play plays at once,
/// as the Top Shelf's select and Play/Pause do.
enum Opening { case show, play }

/// A movie's or season's page, the Apple TV's and the iPhone's alike: its
/// cover in its own shape, its name (a season's under it), facts, Start
/// Over and Play or Resume, the quality, Lists and the watched mark, its
/// description, and a movie's versions or a season's episodes, each
/// playable; a season's neighbors a press away. On the Apple TV, the cover
/// beside the rest over a blurred backdrop of it, the neighbors in the top
/// corner, Play or Resume focused first; on the iPhone, the cover above,
/// the neighbors (‹ ›) in the navigation bar.
struct TitlePage: View {
    let tile: Tile
    @Environment(Library.self) private var library
    @State private var detail: TitleDetail?
    /// The season shown, moved to its neighbors in place.
    @State private var season: Int?
    /// The quality chosen in its picker, if one was.
    @State private var quality: String?
    @State private var playing: PlayRequest?
    @FocusState private var playFocused: Bool
    /// Playing what Play plays at once, once (a Top Shelf item's Play).
    @State private var playsAtOnce: Bool

    /// With its details as they are, so Play is there to focus first: come
    /// a moment later, focus had gone to the seasons' buttons.
    init(tile: Tile, detail: TitleDetail? = nil, opening: Opening = .show) {
        self.tile = tile
        _detail = State(initialValue: detail)
        _playsAtOnce = State(initialValue: opening == .play)
    }

    var body: some View {
        let seasons = tile.isSeries ? Library.seasons(of: tile.key, in: library.tiles) : []
        let index = seasons.firstIndex { $0.season == (season ?? tile.season) }
        let shown = index.map { seasons[$0] } ?? tile
        let back = index.flatMap { $0 > 0 ? seasons[$0 - 1] : nil }
        let forward = index.flatMap { $0 + 1 < seasons.count ? seasons[$0 + 1] : nil }
        let cover = CoverImage(cover: shown.cover, aspect: shown.aspect, title: shown.name, size: .large, shaped: true)
        Group {
            #if os(tvOS)
            HStack(alignment: .top, spacing: 80) {
                // Its cover in its own shape (a season's square or 4:3), at
                // the top of a 2:3 box.
                Color.clear
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                    .frame(width: 460)
                    .overlay(alignment: .top) { cover.clipShape(.rect(cornerRadius: 16)) }
                ScrollView {
                    details(shown, back: back, forward: forward).padding(.vertical, 20)
                }
                .scrollClipDisabled()
            }
            .padding(80)
            .background { Backdrop(tile: shown) }
            .modifier(FocusesPlayFirst(focus: $playFocused))
            #else
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    cover
                        .clipShape(.rect(cornerRadius: 12))
                        .frame(maxHeight: 280)
                        .frame(maxWidth: .infinity)
                    details(shown, back: back, forward: forward)
                }
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if shown.isSeries, back != nil || forward != nil {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button("Previous Season", systemImage: "chevron.backward") { season = back?.season }
                            .disabled(back == nil)
                        Button("Next Season", systemImage: "chevron.forward") { season = forward?.season }
                            .disabled(forward == nil)
                    }
                }
            }
            #endif
        }
        .task(id: library.detailsRevision) {
            detail = library.detail(tile.key)
            if playsAtOnce, let detail {
                playsAtOnce = false
                playing = Playback.next(in: detail, season: shown.season, quality: quality)
            }
        }
        // A season's other episodes, described as they're shown.
        .task(id: shown.season) { if shown.isSeries { await library.describeItems(of: tile.key, season: shown.season) } }
        #if os(tvOS)
        .modifier(PlaysFullScreen(request: $playing, startsBlack: playsAtOnce))
        #else
        .modifier(PlaysFullScreen(request: $playing))
        #endif
    }

    #if os(tvOS)
    private static let spacing: (page: CGFloat, items: CGFloat) = (30, 12)
    #else
    private static let spacing: (page: CGFloat, items: CGFloat) = (16, 0)
    #endif

    /// Everything but the cover, in order.
    @ViewBuilder
    private func details(_ shown: Tile, back: Tile?, forward: Tile?) -> some View {
        VStack(alignment: .leading, spacing: Self.spacing.page) {
            #if os(tvOS)
            // A season's before and after it in the top corner, beside the
            // series' name, its whole width, so moving up from Play, at the
            // other end, reaches them.
            HStack(spacing: 30) {
                Text(shown.name).font(.title)
                if shown.isSeries {
                    Spacer()
                    Neighbors(back: back, forward: forward) { season = $0 }
                }
            }
            .focusSection()
            if let name = shown.seasonName { Text(name).font(.title3) }
            #else
            VStack(alignment: .leading, spacing: 4) {
                Text(shown.name).font(.title2.bold())
                if let name = shown.seasonName { Text(name).font(.headline).foregroundStyle(.secondary) }
            }
            #endif
            if let detail {
                let items = Playback.items(detail, season: shown.season)
                Text(detail.facts(season: shown.season))
                    #if os(iOS)
                    .font(.subheadline)
                    #endif
                    .foregroundStyle(.secondary)
                controls(detail, items: items, season: shown.season)
                if let description = shown.isSeries ? detail.fields["description"] : detail.summary {
                    Text(description)
                        #if os(tvOS)
                        .lineLimit(shown.isSeries ? 4 : 8)
                        .foregroundStyle(shown.isSeries ? .secondary : .primary)
                        #else
                        .font(.callout)
                        #endif
                }
                if shown.isSeries || items.count > 1 { itemList(detail, items: items, episodes: shown.isSeries) }
            }
        }
    }

    /// Start Over and Play or Resume; the quality; and the lists and
    /// watched mark, quieter than what plays (icons, named for VoiceOver).
    /// One row on the Apple TV; on the iPhone, Play's row its own.
    @ViewBuilder
    private func controls(_ detail: TitleDetail, items: [TitleDetail.Item], season: Int?) -> some View {
        let play = PlayButtons(detail: detail, season: season, quality: quality, playFocus: $playFocused) { playing = $0 }
        let marks = Marks(detail: detail, items: items, season: season).labelStyle(.iconOnly)
        #if os(tvOS)
        HStack(spacing: 30) {
            play
            QualityPicker(detail: detail, items: items, chosen: $quality)
            marks
        }
        #else
        HStack { play }.controlSize(.large)
        HStack(spacing: 20) {
            QualityPicker(detail: detail, items: items, chosen: $quality)
            Spacer()
            marks
        }
        #endif
    }

    /// A season's episodes, each playing on through the season, or a
    /// movie's versions, each alone, by name.
    private func itemList(_ detail: TitleDetail, items: [TitleDetail.Item], episodes: Bool) -> some View {
        VStack(alignment: .leading, spacing: Self.spacing.items) {
            Text(episodes ? "Episodes" : "Versions").font(.headline)
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Button {
                    let queue = episodes ? items : [item]
                    playing = Playback.request(detail, items: queue, from: episodes ? index : 0, quality: detail.quality(for: queue, chosen: quality))
                } label: {
                    ItemLine(item: item, name: episodes ? nil : item.label, widest: items.widestRuntime)
                        #if os(iOS)
                        .padding(.vertical, 10)
                        .contentShape(.rect)
                        #endif
                }
                #if os(iOS)
                .buttonStyle(.plain)
                #endif
                #if os(iOS)
                Divider()
                #endif
            }
        }
    }
}

#if os(tvOS)
/// Play or Resume focused as a page first shows, not Start Over before it:
/// by `defaultFocus`, and once set on appearing, as a page pushed at launch
/// passed `defaultFocus` over; once, so coming back to the page leaves
/// focus where it was.
struct FocusesPlayFirst: ViewModifier {
    let focus: FocusState<Bool>.Binding
    @State private var done = false

    func body(content: Content) -> some View {
        content
            .defaultFocus(focus, true)
            .onAppear {
                if !done { done = true; focus.wrappedValue = true }
            }
    }
}
#endif
#endif
