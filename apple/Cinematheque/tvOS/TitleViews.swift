#if os(tvOS)
import SwiftUI

/// A movie's page: its cover over a blurred backdrop of it, Play or Resume,
/// the watchlist and watched marks, its versions, and its description.
struct MovieView: View {
    let tile: Tile
    @Environment(Library.self) private var library
    @State private var detail: TitleDetail?
    @State private var playing: PlayRequest?
    /// The quality chosen in its picker, if one was.
    @State private var quality: String?

    var body: some View {
        HStack(alignment: .top, spacing: 80) {
            Color.clear
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .frame(width: 460)
                .overlay { CoverImage(cover: tile.cover, thumb: tile.thumb, title: tile.name, size: .large) }
                .clipShape(RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 30) {
                Text(tile.name).font(.title)
                if let detail {
                    Text(detail.facts(season: nil)).foregroundStyle(.secondary)
                    HStack(spacing: 30) {
                        if Playback.nextItem(detail, season: nil)?.inProgress == true {
                            Button("Start Over", systemImage: Playback.startOverSymbol) {
                                playing = Playback.next(in: detail, season: nil, quality: detail.quality(for: detail.items, chosen: quality), overFromStart: true)
                            }
                        }
                        Button(Playback.playLabel(Playback.nextItem(detail, season: nil)), systemImage: "play.fill") {
                            playing = Playback.next(in: detail, season: nil, quality: detail.quality(for: detail.items, chosen: quality))
                        }
                        // The marks, quieter than what plays: icons, named
                        // for VoiceOver.
                        Marks(detail: detail, items: detail.items).labelStyle(.iconOnly)
                    }
                    if detail.items.count > 1 {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                Text("Versions").font(.headline)
                                Spacer()
                                QualityPicker(detail: detail, items: detail.items, chosen: $quality)
                            }
                            ForEach(Array(detail.items.enumerated()), id: \.element.id) { index, item in
                                Button(item.label, systemImage: item.watched ? "checkmark.circle.fill" : "play.circle") {
                                    playing = Playback.request(detail, items: [item], from: 0, quality: detail.quality(for: [item], chosen: quality))
                                }
                            }
                        }
                    }
                    if let description = detail.summary {
                        Text(description).lineLimit(8)
                    }
                    // A movie of one version: its quality alone, under its description.
                    if detail.items.count <= 1 {
                        QualityPicker(detail: detail, items: detail.items, chosen: $quality)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(80)
        .background { Backdrop(tile: tile) }
        .task(id: library.revision) {
            detail = library.detail(tile.key)
            #if DEBUG
            if Launch.play != nil, playing == nil, let detail { playing = Playback.next(in: detail, season: nil, quality: detail.quality(for: detail.items, chosen: quality)) }
            #endif
        }
        .modifier(PlaysFullScreen(request: $playing))
    }
}

/// A series' page: its seasons, then the chosen season's episodes, each
/// playable; Play takes the season's next unwatched episode, and the rest
/// after it.
struct SeriesView: View {
    let key: String
    @Environment(Library.self) private var library
    @State private var detail: TitleDetail?
    @State private var season: Int?
    @State private var playing: PlayRequest?
    /// The quality chosen in its picker, if one was.
    @State private var quality: String?

    var body: some View {
        let seasons = library.tiles.filter { $0.key == key && $0.season != nil }
        let tile = seasons.first { $0.season == season } ?? seasons.first
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                Text(tile?.name ?? "").font(.title)
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 40) {
                        ForEach(seasons) { s in
                            Button {
                                season = s.season
                            } label: {
                                Color.clear
                                    .aspectRatio(1, contentMode: .fit)
                                    .frame(width: 220)
                                    .overlay { CoverImage(cover: s.cover, thumb: s.thumb, title: s.seasonName ?? "", fit: true) }
                                    .overlay(alignment: .bottom) {
                                        Text(s.seasonName ?? "")
                                            .font(.caption)
                                            .padding(8)
                                            .frame(maxWidth: .infinity)
                                            .background(.regularMaterial)
                                    }
                                    // The season shown below.
                                    .overlay {
                                        if s.season == tile?.season {
                                            RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 6)
                                        }
                                    }
                            }
                            .buttonStyle(.card)
                        }
                    }
                    .padding(.vertical, 30)
                }
                .scrollClipDisabled()
                if let detail, let tile {
                    let items = Playback.items(detail, season: tile.season)
                    HStack(spacing: 30) {
                        if Playback.nextItem(detail, season: tile.season)?.inProgress == true {
                            Button("Start Over", systemImage: Playback.startOverSymbol) {
                                playing = Playback.next(in: detail, season: tile.season, quality: detail.quality(for: items, chosen: quality), overFromStart: true)
                            }
                        }
                        Button(Playback.playLabel(Playback.nextItem(detail, season: tile.season)), systemImage: "play.fill") {
                            playing = Playback.next(in: detail, season: tile.season, quality: detail.quality(for: items, chosen: quality))
                        }
                        Marks(detail: detail, items: items, season: tile.season).labelStyle(.iconOnly)
                    }
                    if let description = detail.fields["description"] {
                        Text(description).lineLimit(4).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        // The season's quality, in the heading of the episodes it plays.
                        HStack {
                            Text("Episodes").font(.headline)
                            Spacer()
                            QualityPicker(detail: detail, items: items, chosen: $quality)
                        }
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            Button {
                                playing = Playback.request(detail, items: items, from: index, quality: detail.quality(for: items, chosen: quality))
                            } label: {
                                Episode(item: item)
                            }
                        }
                    }
                }
            }
            .padding(80)
        }
        .background { if let tile { Backdrop(tile: tile) } }
        .task(id: library.revision) { detail = library.detail(key) }
        // The chosen season's other episodes, or a movie's other versions,
        // described as they're shown.
        .task(id: season) {
            if season != nil || key.hasPrefix("t/m/") { await library.describeItems(of: key, season: season) }
        }
        .onAppear {
            // The first season not yet watched through, specials last.
            let ordered = seasons.filter { $0.season != 0 } + seasons.filter { $0.season == 0 }
            if season == nil { season = (ordered.first { !$0.watched } ?? ordered.first)?.season }
        }
        .modifier(PlaysFullScreen(request: $playing))
    }
}

/// An episode's row: its number and title, its runtime, and this person's
/// progress in it.
private struct Episode: View {
    let item: TitleDetail.Item

    var body: some View {
        HStack(spacing: 24) {
            Image(systemName: item.progressSymbol)
            Text(item.name)
            Spacer()
            if let runtime = item.runtime {
                Text(runtime).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A title's cover, blurred, behind its page.
private struct Backdrop: View {
    let tile: Tile

    var body: some View {
        CoverImage(cover: tile.cover, thumb: tile.thumb, title: "", size: .large)
            .blur(radius: 60)
            .opacity(0.35)
            .ignoresSafeArea()
    }
}

/// The quality to play, when there's a choice: the best this Apple TV plays
/// (MP4, MOV, or M4V, up to its display's resolution), unless one's chosen,
/// as a quicker copy in another quality may be, or a direct one.
private struct QualityPicker: View {
    let detail: TitleDetail
    let items: [TitleDetail.Item]
    @Binding var chosen: String?

    var body: some View {
        let labels = QualityChoice.labels(items)
        if labels.count > 1 {
            let short = QualityChoice.shortNames(labels, in: items)
            Picker(selection: Binding(get: { detail.quality(for: items, chosen: chosen) }, set: { chosen = $0 })) {
                ForEach(labels, id: \.self) { label in
                    Text(short[label] ?? label).tag(Optional(label))
                }
            } label: {
                Label("Quality", systemImage: "slider.horizontal.3")
            }
            .pickerStyle(.menu)
        }
    }
}
#endif
