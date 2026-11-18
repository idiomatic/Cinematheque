import SwiftUI

/// How a title and its items read, and what to play of them, the same on
/// every platform; each platform lays them out its own way.
extension TitleDetail {
    /// "Action · 2013 · HBO · 1h 49m": genre, year, network, and, for a
    /// movie (`season` nil), its runtime.
    func facts(season: Int?) -> String {
        let runtime = season == nil ? items.first?.runtime : nil
        return [fields["genre"], fields["released"].map { String($0.prefix(4)) } ?? year.map(String.init), fields["network"], runtime]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// A movie's description, or a season's (its series').
    var summary: String? { fields["description"] ?? items.first?.fields["description"] }

    /// The rendition to play the items in (see `RenditionChoice.best`).
    func rendition(for items: [Item]) -> String? {
        RenditionChoice.best(items)
    }
}

extension TitleDetail.Item {
    /// Its runtime, e.g., "44m" or "1h 49m".
    var runtime: String? { fields["duration"].flatMap(Int.init).flatMap(Runtime.format) }

    /// Begun but not finished.
    var inProgress: Bool { !watched && position > 0 }

    /// "3. Title", or a special's title alone.
    var episodeName: String {
        let number = episode?.number ?? 0
        let title = fields["title"] ?? (number == 0 ? "Special" : "Episode \(number)")
        return number == 0 ? title : "\(number). \(title)"
    }

    /// A symbol of how far this user has watched it.
    var progressSymbol: String {
        watched ? "checkmark.circle.fill" : (inProgress ? "circle.lefthalf.filled" : "circle")
    }
}

enum Runtime {
    /// "44m", "1h 49m", or under a minute, "40s".
    static func format(_ ms: Int) -> String? {
        guard ms > 0 else { return nil }
        let units: Set<Duration.UnitsFormatStyle.Unit> = ms < 60_000 ? [.seconds] : [.hours, .minutes]
        return Duration.milliseconds(ms).formatted(.units(allowed: units, width: .narrow))
    }
}

extension Playback {
    /// What Play plays: a movie's item, or a season's next unwatched
    /// episode (its first, if all are watched).
    static func nextItem(_ detail: TitleDetail, season: Int?) -> TitleDetail.Item? {
        let items = items(detail, season: season)
        return items.first { !$0.watched } ?? items.first
    }

    /// Start Over, beside Resume: the symbol of a button that plays what
    /// Resume would, from its beginning.
    static let startOverSymbol = "backward.fill"

    /// "Play", "Resume", "Play Episode 3", "Resume Special".
    static func playLabel(_ next: TitleDetail.Item?) -> String {
        guard let next else { return "Play" }
        let verb = next.inProgress ? "Resume" : "Play"
        if let e = next.episode { return e.number == 0 ? "\(verb) Special" : "\(verb) Episode \(e.number)" }
        return verb
    }
}

/// Which rendition a player plays: one in a format it plays (MP4, MOV, or
/// M4V; not MKV or ISO), at the most its display shows (`Platform`), else
/// the least above that.
enum RenditionChoice {
    static func best(_ items: [TitleDetail.Item]) -> String? {
        let limit = Platform.displayHeight >= 2160 ? 2160 : 1080
        let renditions = items.flatMap(\.renditions)
        let playable = renditions.filter { r in r.copies.contains { isPlayable($0.url) } }
        return (playable.isEmpty ? renditions : playable).max { score($0.label, limit) < score($1.label, limit) }?.label
    }

    /// A rendition's name for a picker, by its label.
    static func name(_ label: String, in items: [TitleDetail.Item]) -> String {
        items.lazy.flatMap(\.renditions).first { $0.label == label }?.name ?? label
    }

    private static func isPlayable(_ url: String) -> Bool {
        ["mp4", "m4v", "mov"].contains((URL(string: url)?.pathExtension ?? "").lowercased())
    }

    /// The highest resolution up to the limit, then those above it, least
    /// first; a label without one ranks low.
    private static func score(_ label: String, _ limit: Int) -> Int {
        guard let match = label.firstMatch(of: /(\d{3,4})p/), let height = Int(match.1) else { return 0 }
        return height <= limit ? 10_000 + height : 10_000 - height
    }
}

extension Library {
    /// Marks items of a title watched, or not, and reloads tiles' marks.
    func setWatched(_ items: [TitleDetail.Item], of detail: TitleDetail, _ watched: Bool) {
        for item in items { setWatched("\(detail.key)/\(item.key)", watched) }
        reload()
    }
}

/// The watchlist and watched marks of a movie or a season, as two buttons
/// for the platform to lay out and style.
struct Marks: View {
    let detail: TitleDetail
    let items: [TitleDetail.Item]
    @Environment(Library.self) private var library

    var body: some View {
        let listed = library.watchlist.contains(detail.key)
        let watched = !items.isEmpty && items.allSatisfy(\.watched)
        Button(listed ? "On Watchlist" : "Watchlist", systemImage: listed ? "star.fill" : "star") {
            library.setWatchlisted(detail.key, !listed)
        }
        .help(listed ? "Remove from your watchlist" : "Add to your watchlist")
        // A status that pressing toggles: it shows whether it's watched.
        Button(watched ? "Watched" : "Unwatched", systemImage: watched ? "checkmark.circle.fill" : "circle") {
            library.setWatched(items, of: detail, !watched)
        }
        .help(watched ? "Mark as unwatched" : "Mark as watched")
    }
}
