import Foundation

/// What to play: a copy's URL, the item it's a copy of (for its playhead),
/// where to start, and what to play after it (e.g., the rest of a season).
struct PlayRequest: Codable, Hashable {
    struct Entry: Codable, Hashable {
        let url: URL
        let item: String
        let title: String
    }

    let url: URL
    let item: String
    let start: Double
    var title: String = ""
    var queue: [Entry] = []
}

/// What to play next, and the queue after it.
enum Playback {
    /// A movie's first item, resuming where this user left off; or a
    /// season's next unwatched episode (or its first, if all are watched),
    /// with the rest of the season queued after it; with `overFromStart`,
    /// from its beginning (Start Over).
    static func next(in detail: TitleDetail, season: Int?, rendition: String? = nil, overFromStart: Bool = false) -> PlayRequest? {
        let items = items(detail, season: season)
        guard !items.isEmpty else { return nil }
        let start = items.firstIndex { !$0.watched } ?? 0
        return request(detail, items: items, from: start, rendition: rendition, overFromStart: overFromStart)
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
            guard let copy = copy(item, rendition: rendition), let url = URL(string: copy.url) else { return nil }
            return .init(url: url, item: "\(detail.key)/\(item.key)", title: name(item, in: detail))
        }
        guard let first = queue.first else { return nil }
        let item = items[index]
        return PlayRequest(url: first.url, item: first.item, start: item.watched || overFromStart ? 0 : Double(item.position) / 1000, title: first.title, queue: Array(queue.dropFirst()))
    }

    /// The copy to play: of the chosen rendition if the item has one, else
    /// its first.
    static func copy(_ item: TitleDetail.Item, rendition: String?) -> TitleDetail.Copy? {
        let chosen = item.renditions.first { $0.label == rendition } ?? item.renditions.first
        return chosen?.copies.first
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
