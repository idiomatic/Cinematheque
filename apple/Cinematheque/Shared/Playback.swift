import Foundation

/// What to play: a copy's URL, the item it's a copy of (for its progress),
/// where to start, and what to play after it (e.g., the rest of a season).
/// Each comes with the item's other copies, to play if one doesn't load.
struct PlayRequest: Codable, Hashable {
    struct Entry: Codable, Hashable {
        var url: URL
        let item: String
        let title: String
        /// The item's other copies, in the order to try them.
        var alternates: [URL] = []
        /// How many copies, from `url` on, copy racing orders: the chosen
        /// quality's (available) ones. The rest, other qualities' and
        /// those on drives that aren't there, stay after them, in order,
        /// for when none of them loads: the race picks the fastest copy,
        /// never another quality.
        var contenders = 1
    }

    let url: URL
    let item: String
    let start: Double
    var title: String = ""
    var queue: [Entry] = []
    var alternates: [URL] = []
    var contenders = 1

    /// The first entry, the one `url` plays.
    var first: Entry { Entry(url: url, item: item, title: title, alternates: alternates, contenders: contenders) }

    /// The same, from its first item's beginning (Start Over).
    var fromBeginning: PlayRequest {
        PlayRequest(url: url, item: item, start: 0, title: title, queue: queue, alternates: alternates, contenders: contenders)
    }
}

/// What to play next, and the queue after it.
enum Playback {
    /// A movie's first item, resuming where this person left off; or a
    /// season's episode in progress (the latest, if more than one), else its
    /// next unwatched (or its first, if all are watched), with the rest of
    /// the season queued after it (`fromBeginning` for Start Over). In the
    /// `quality` chosen, if its items have it, else the one Play plays, so
    /// every way of playing them (a tile's, a series') plays the same.
    static func next(in detail: TitleDetail, season: Int?, quality: String? = nil) -> PlayRequest? {
        let items = items(detail, season: season)
        guard !items.isEmpty else { return nil }
        return request(detail, items: items, from: nextIndex(items), quality: detail.quality(for: items, chosen: quality))
    }

    /// Which of `items` Play plays, as the core marks it (`next`).
    static func nextIndex(_ items: [TitleDetail.Item]) -> Int {
        items.firstIndex(where: \.next) ?? 0
    }

    /// The items of a movie, or of one season, in the core's order.
    static func items(_ detail: TitleDetail, season: Int?) -> [TitleDetail.Item] {
        guard let season else { return detail.items }
        return detail.items.filter { $0.episode?.season == season }
    }

    /// Plays `items[index]`, where this person left off unless watched, then
    /// the rest in order.
    static func request(_ detail: TitleDetail, items: [TitleDetail.Item], from index: Int, quality: String? = nil) -> PlayRequest? {
        let queue = items[index...].compactMap { item -> PlayRequest.Entry? in
            let ordered = copies(item, quality: quality, in: detail)
            let urls = ordered.copies.compactMap { URL(string: $0.url) }
            guard let url = urls.first else { return nil }
            return .init(url: url, item: "\(detail.key)/\(item.key)", title: name(item, in: detail), alternates: Array(urls.dropFirst()), contenders: max(1, min(ordered.contenders, urls.count)))
        }
        guard let first = queue.first else { return nil }
        let item = items[index]
        return PlayRequest(url: first.url, item: first.item, start: item.watched ? 0 : Double(item.position) / 1000, title: first.title, queue: Array(queue.dropFirst()), alternates: first.alternates, contenders: first.contenders)
    }

    /// An item's qualities in the order to play them: the chosen one, then
    /// the nearest at or below its resolution (so a missing quality costs
    /// picture, not bandwidth or space), then the nearest above, those of
    /// unknown resolution last.
    static func qualities(_ item: TitleDetail.Item, near quality: String?, in detail: TitleDetail) -> [TitleDetail.Quality] {
        let height = detail.items.lazy.flatMap(\.qualities).first { $0.label == quality }?.height
        func rank(_ q: TitleDetail.Quality, _ offset: Int) -> (Int, Int, Int) {
            if q.label == quality { return (0, 0, offset) }
            guard let height, let h = q.height else { return (3, 0, offset) }
            return h <= height ? (1, -h, offset) : (2, h, offset)
        }
        return item.qualities.enumerated().sorted { rank($0.element, $0.offset) < rank($1.element, $1.offset) }.map(\.element)
    }

    /// The quality an item plays in place of the chosen one, which it
    /// lacks; nil if it has it.
    static func standIn(_ item: TitleDetail.Item, for quality: String?, in detail: TitleDetail) -> TitleDetail.Quality? {
        guard let quality, !item.qualities.contains(where: { $0.label == quality }) else { return nil }
        return qualities(item, near: quality, in: detail).first
    }

    /// The copies to try, in order: by quality (see `qualities`), so one
    /// on a device that's asleep, or a drive that's unplugged, gives way to
    /// another.
    /// With how many of them, from the first, copy racing orders: the
    /// first quality's available copies (none to race before a download).
    static func copies(_ item: TitleDetail.Item, quality: String?, in detail: TitleDetail) -> (copies: [TitleDetail.Copy], contenders: Int) {
        let ordered = qualities(item, near: quality, in: detail)
        guard let chosen = ordered.first else { return ([], 0) }
        let others = ordered.dropFirst().flatMap(\.copies)
        // A download on this device first, from its file, in whatever
        // quality: it's there to play, online or not; by this device's own
        // record first, as its shared one may have gone with a source.
        let own = localFiles["\(detail.key)/\(item.key)"].flatMap { file in
            FileManager.default.fileExists(atPath: file.url.path) ? TitleDetail.Copy(url: file.url.absoluteString, size: file.size, source: downloads?.source ?? "", unavailable: false) : nil
        }
        let recorded = (chosen.copies + others).compactMap(downloaded)
        let local = (own.map { [$0] } ?? []) + recorded.filter { $0.url != own?.url }
        let streamed = { (copies: [TitleDetail.Copy]) in copies.filter { $0.source != downloads?.source } }
        let mine = streamed(chosen.copies).filter { !$0.unavailable }
        let theirs = streamed(others).filter { !$0.unavailable }
        // Those on a drive that isn't there, last.
        let gone = streamed(chosen.copies + others).filter(\.unavailable)
        return (local + mine + theirs + gone, local.isEmpty ? mine.count : 0)
    }

    /// This device's downloads, if it has any: their source, the URL
    /// it's served at, and their folder.
    struct Downloads {
        let source: String
        let base: String
        let dir: String
    }

    static var downloads: Downloads?

    /// This device's downloads by its own records: each item's file (its
    /// full key's) and size, played first, whether or not a source's record
    /// of it is left.
    static var localFiles: [String: (url: URL, size: Int)] = [:]

    /// A copy of this device's downloads, as its file, if it's there.
    static func downloaded(_ copy: TitleDetail.Copy) -> TitleDetail.Copy? {
        guard let d = downloads, copy.source == d.source, copy.url.hasPrefix(d.base),
              let path = String(copy.url.dropFirst(d.base.count)).removingPercentEncoding,
              let file = URL(fileURLWithPath: d.dir).within(path) else { return nil }
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return TitleDetail.Copy(url: file.absoluteString, size: copy.size, source: copy.source, unavailable: false)
    }

    static func name(_ item: TitleDetail.Item, in detail: TitleDetail) -> String {
        if let e = item.episode, e.season == 0 || item.aired != nil {
            // A special by its title; a dated episode by its date, then title.
            return "\(detail.name) · " + (item.aired == nil ? item.name : item.label + (item.fields["title"].map { " · \($0)" } ?? ""))
        }
        if let e = item.episode {
            return "\(detail.name) · S\(e.season)E\(e.number)" + (item.fields["title"].map { " · \($0)" } ?? "")
        }
        return detail.name
    }
}
