#if os(tvOS)
import SwiftUI

/// A movie's page: its cover over a blurred backdrop of it, Play or Resume,
/// the watchlist and watched marks, its versions, and its description.
struct MovieView: View {
    let tile: Tile
    @Environment(Library.self) private var library
    @State private var detail: TitleDetail?
    @State private var playing: PlayRequest?

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
                                playing = Playback.next(in: detail, season: nil, rendition: detail.rendition(for: detail.items), overFromStart: true)
                            }
                            .labelStyle(.iconOnly)
                        }
                        Button(Playback.playLabel(Playback.nextItem(detail, season: nil)), systemImage: "play.fill") {
                            playing = Playback.next(in: detail, season: nil, rendition: detail.rendition(for: detail.items))
                        }
                        Marks(detail: detail, items: detail.items)
                    }
                    if detail.items.count > 1 {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Versions").font(.headline)
                            ForEach(Array(detail.items.enumerated()), id: \.element.id) { index, item in
                                Button(item.versionName, systemImage: item.watched ? "checkmark.circle.fill" : "play.circle") {
                                    playing = Playback.request(detail, items: [item], from: 0, rendition: detail.rendition(for: [item]))
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
        .task(id: library.revision) {
            detail = library.detail(tile.key)
            #if DEBUG
            if Launch.play != nil, playing == nil, let detail { playing = Playback.next(in: detail, season: nil, rendition: detail.rendition(for: detail.items)) }
            #endif
        }
        .fullScreenCover(item: $playing) { TVPlayer(request: $0).ignoresSafeArea() }
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
                                    .overlay { CoverImage(cover: s.cover, thumb: s.thumb, title: s.seasonName ?? "") }
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
                                playing = Playback.next(in: detail, season: tile.season, rendition: detail.rendition(for: items), overFromStart: true)
                            }
                            .labelStyle(.iconOnly)
                        }
                        Button(Playback.playLabel(Playback.nextItem(detail, season: tile.season)), systemImage: "play.fill") {
                            playing = Playback.next(in: detail, season: tile.season, rendition: detail.rendition(for: items))
                        }
                        Marks(detail: detail, items: items)
                    }
                    if let description = detail.fields["description"] {
                        Text(description).lineLimit(4).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            Button {
                                playing = Playback.request(detail, items: items, from: index, rendition: detail.rendition(for: items))
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
        // The chosen season's other episodes, described as it's shown.
        .task(id: season) {
            if let season { await library.describeEpisodes(of: key, season: season) }
        }
        .onAppear {
            // The first season not yet watched through, specials last.
            let ordered = seasons.filter { $0.season != 0 } + seasons.filter { $0.season == 0 }
            if season == nil { season = (ordered.first { !$0.watched } ?? ordered.first)?.season }
        }
        .fullScreenCover(item: $playing) { TVPlayer(request: $0).ignoresSafeArea() }
    }
}

/// An episode's row: its number and title, its runtime, and this user's
/// progress in it.
private struct Episode: View {
    let item: TitleDetail.Item

    var body: some View {
        HStack(spacing: 24) {
            Image(systemName: item.progressSymbol)
            Text(item.episodeName)
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
#endif
