import Foundation

/// What to play: a copy's URL, the item it's a copy of (for its playhead),
/// where to start, and what to play after it (e.g., the rest of a season).
/// Each comes with the item's other copies, to play if one doesn't load.
struct PlayRequest: Codable, Hashable {
    struct Entry: Codable, Hashable {
        var url: URL
        let item: String
        let title: String
        /// The item's other copies, in the order to try them.
        var alternates: [URL] = []
    }

    let url: URL
    let item: String
    let start: Double
    var title: String = ""
    var queue: [Entry] = []
    var alternates: [URL] = []

    /// The first entry, the one `url` plays.
    var first: Entry { Entry(url: url, item: item, title: title, alternates: alternates) }
}

/// What to play next, and the queue after it.
enum Playback {
    /// A movie's first item, resuming where this user left off; or a
    /// season's episode in progress (the latest, if more than one), else its
    /// next unwatched (or its first, if all are watched), with the rest of
    /// the season queued after it; with `overFromStart`, from its beginning
    /// (Start Over).
    static func next(in detail: TitleDetail, season: Int?, rendition: String? = nil, overFromStart: Bool = false) -> PlayRequest? {
        let items = items(detail, season: season)
        guard !items.isEmpty else { return nil }
        return request(detail, items: items, from: nextIndex(items), rendition: rendition, overFromStart: overFromStart)
    }

    /// Which of `items` Play plays: the latest in progress, else the first
    /// unwatched, else the first.
    static func nextIndex(_ items: [TitleDetail.Item]) -> Int {
        items.lastIndex { $0.inProgress } ?? items.firstIndex { !$0.watched } ?? 0
    }

    /// The items of a movie, or of one season, in order.
    static func items(_ detail: TitleDetail, season: Int?) -> [TitleDetail.Item] {
        guard let season else { return detail.items }
        return detail.items
            .filter { $0.episode?.season == season }
            .sorted { ($0.episode?.number ?? 0) < ($1.episode?.number ?? 0) }
    }

    /// Plays `items[index]`, where this user left off unless watched or
    /// `overFromStart`, then the rest in order.
    static func request(_ detail: TitleDetail, items: [TitleDetail.Item], from index: Int, rendition: String? = nil, overFromStart: Bool = false) -> PlayRequest? {
        let queue = items[index...].compactMap { item -> PlayRequest.Entry? in
            let urls = copies(item, rendition: rendition).compactMap { URL(string: $0.url) }
            guard let url = urls.first else { return nil }
            return .init(url: url, item: "\(detail.key)/\(item.key)", title: name(item, in: detail), alternates: Array(urls.dropFirst()))
        }
        guard let first = queue.first else { return nil }
        let item = items[index]
        return PlayRequest(url: first.url, item: first.item, start: item.watched || overFromStart ? 0 : Double(item.position) / 1000, title: first.title, queue: Array(queue.dropFirst()), alternates: first.alternates)
    }

    /// The copies to try, in order: the chosen rendition's (if the item has
    /// it, else its first rendition's), then its other renditions', so one
    /// on a peer that's asleep, or a drive that's unplugged, gives way to
    /// another.
    static func copies(_ item: TitleDetail.Item, rendition: String?) -> [TitleDetail.Copy] {
        let chosen = item.renditions.first { $0.label == rendition } ?? item.renditions.first
        guard let chosen else { return [] }
        let all = chosen.copies + item.renditions.filter { $0.label != chosen.label }.flatMap(\.copies)
        // Those on a drive that isn't there, last.
        return all.filter { !$0.absent } + all.filter(\.absent)
    }

    static func name(_ item: TitleDetail.Item, in detail: TitleDetail) -> String {
        if let e = item.episode, e.season == 0, e.number == 0 {
            return "\(detail.name) · " + (item.fields["title"] ?? "Special")
        }
        if let e = item.episode {
            return "\(detail.name) · S\(e.season)E\(e.number)" + (item.fields["title"].map { " · \($0)" } ?? "")
        }
        return detail.name
    }
}
