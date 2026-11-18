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
                    Text(Facts.line(detail, item: detail.items.first)).foregroundStyle(.secondary)
                    HStack(spacing: 30) {
                        Button(Facts.playLabel(detail.items.first), systemImage: "play.fill") {
                            playing = Playback.next(in: detail, season: nil, rendition: TVRendition.best(detail.items.first))
                        }
                        Marks(detail: detail, items: detail.items)
                    }
                    if detail.items.count > 1 {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Versions").font(.headline)
                            ForEach(Array(detail.items.enumerated()), id: \.element.id) { index, item in
                                Button(item.versionName, systemImage: item.watched ? "checkmark.circle.fill" : "play.circle") {
                                    playing = Playback.request(detail, items: [item], from: 0, rendition: TVRendition.best(item))
                                }
                            }
                        }
                    }
                    if let description = detail.fields["description"] ?? detail.items.first?.fields["description"] {
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
            if TVLaunch.play, playing == nil, let detail { playing = Playback.next(in: detail, season: nil, rendition: TVRendition.best(detail.items.first)) }
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
                        Button(Facts.playLabel(items.first { !$0.watched } ?? items.first), systemImage: "play.fill") {
                            playing = Playback.next(in: detail, season: tile.season, rendition: TVRendition.best(items.first))
                        }
                        Marks(detail: detail, items: items)
                    }
                    if let description = detail.fields["description"] {
                        Text(description).lineLimit(4).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            Button {
                                playing = Playback.request(detail, items: items, from: index, rendition: TVRendition.best(item))
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
            Image(systemName: item.watched ? "checkmark.circle.fill" : (item.position > 0 ? "circle.lefthalf.filled" : "circle"))
            let number = item.episode?.number ?? 0
            let title = item.fields["title"] ?? (number == 0 ? "Special" : "Episode \(number)")
            Text(number == 0 ? title : "\(number). \(title)")
            Spacer()
            if let runtime = item.fields["duration"].flatMap(Int.init).flatMap(Facts.runtime) {
                Text(runtime).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The watchlist and watched marks, for a movie or a season.
private struct Marks: View {
    let detail: TitleDetail
    let items: [TitleDetail.Item]
    @Environment(Library.self) private var library

    var body: some View {
        let listed = library.watchlist.contains(detail.key)
        let watched = !items.isEmpty && items.allSatisfy(\.watched)
        Button(listed ? "On Watchlist" : "Watchlist", systemImage: listed ? "star.fill" : "star") {
            library.setWatchlisted(detail.key, !listed)
        }
        Button(watched ? "Watched" : "Mark Watched", systemImage: watched ? "checkmark.circle.fill" : "checkmark.circle") {
            for item in items { library.setWatched("\(detail.key)/\(item.key)", !watched) }
            library.reload()
        }
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

enum Facts {
    /// "2013 · Action · 1h 49m".
    static func line(_ detail: TitleDetail, item: TitleDetail.Item?) -> String {
        [
            detail.year.map(String.init),
            detail.fields["genre"],
            item?.fields["duration"].flatMap(Int.init).flatMap(runtime),
        ].compactMap { $0 }.joined(separator: " · ")
    }

    /// "Play", or "Resume" partway through.
    static func playLabel(_ item: TitleDetail.Item?) -> String {
        guard let item, !item.watched, item.position > 0 else { return "Play" }
        if let e = item.episode, e.number > 0 { return "Resume Episode \(e.number)" }
        return "Resume"
    }

    static func runtime(_ ms: Int) -> String? {
        guard ms > 0 else { return nil }
        let minutes = ms / 60_000
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}
#endif
