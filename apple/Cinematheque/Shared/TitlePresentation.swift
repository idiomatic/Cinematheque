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

    /// The quality to play the items in (see `QualityChoice.best`).
    func quality(for items: [Item]) -> String? {
        QualityChoice.best(items)
    }

    /// `chosen`, if any of `items` has it, else the best this device plays.
    func quality(for items: [Item], chosen: String?) -> String? {
        guard let chosen, items.contains(where: { $0.qualities.contains { $0.label == chosen } }) else { return quality(for: items) }
        return chosen
    }
}

extension TitleDetail.Item {
    /// Its runtime, e.g., "44m" or "1h 49m".
    var runtime: String? { fields["duration"].flatMap(Int.init).flatMap(Runtime.format) }

    /// Begun but not finished.
    var inProgress: Bool { !watched && position > 0 }


    /// A symbol of how far this person has watched it.
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
    /// What Play plays: a movie's item, or a season's episode in progress,
    /// else its next unwatched (its first, if all are watched).
    static func nextItem(_ detail: TitleDetail, season: Int?) -> TitleDetail.Item? {
        let items = items(detail, season: season)
        return items.isEmpty ? nil : items[nextIndex(items)]
    }

    /// Start Over, beside Resume (on the Apple TV): the symbol of a button
    /// that plays what Resume would, from its beginning (to the start, not
    /// rewinding).
    static let startOverSymbol = "backward.end.fill"

    /// "Play", "Resume", "Play Episode 3", "Resume Special", "Play March 12"
    /// (the episode's label, as the core gives it).
    static func playLabel(_ next: TitleDetail.Item?) -> String {
        guard let next else { return "Play" }
        let verb = next.inProgress ? "Resume" : "Play"
        if next.episode != nil { return "\(verb) \(next.label)" }
        return verb
    }
}

/// Which quality a player plays: one in a format it plays (MP4, MOV, or
/// M4V; not MKV or ISO), at the most its display shows (`Platform`), else
/// the least above that.
enum QualityChoice {
    static func best(_ items: [TitleDetail.Item]) -> String? {
        let limit = Platform.displayHeight >= 2160 ? 2160 : 1080
        let qualities = items.flatMap(\.qualities)
        let playable = qualities.filter { r in r.copies.contains { isPlayable($0.url) } }
        return (playable.isEmpty ? qualities : playable).max { score($0.height, limit) < score($1.height, limit) }?.label
    }

    /// The items' qualities for a picker, by label: highest resolution
    /// first, those of unknown resolution last, then by short name.
    static func labels(_ items: [TitleDetail.Item]) -> [String] {
        var seen: [String: TitleDetail.Quality] = [:]
        for q in items.lazy.flatMap(\.qualities) where seen[q.label] == nil { seen[q.label] = q }
        return seen.values.sorted {
            ($0.height ?? 0, $1.short) > ($1.height ?? 0, $0.short)
        }.map(\.label)
    }

    /// A quality's name for a picker, by its label.
    static func name(_ label: String, in items: [TitleDetail.Item]) -> String {
        items.lazy.flatMap(\.qualities).first { $0.label == label }?.name ?? label
    }

    /// Each quality's short name for a picker, as the core names it (see
    /// views.zig); the full name is the picker's help.
    static func shortNames(_ labels: [String], in items: [TitleDetail.Item]) -> [String: String] {
        var out: [String: String] = [:]
        for q in items.lazy.flatMap(\.qualities) where labels.contains(q.label) && out[q.label] == nil { out[q.label] = q.short }
        return out
    }

    private static func isPlayable(_ url: String) -> Bool {
        ["mp4", "m4v", "mov"].contains((URL(string: url)?.pathExtension ?? "").lowercased())
    }

    /// The highest resolution up to the limit, then those above it, least
    /// first; one of unknown resolution ranks low.
    private static func score(_ height: Int?, _ limit: Int) -> Int {
        guard let height else { return 0 }
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
    /// The season they're of, which is on the watchlist on its own.
    var season: Int? = nil
    @Environment(Library.self) private var library

    var body: some View {
        let key = Library.watchlistKey(detail.key, season: season)
        let listed = library.watchlist.contains(key)
        let watched = !items.isEmpty && items.allSatisfy(\.watched)
        Button(listed ? "On Watchlist" : "Watchlist", systemImage: listed ? "star.fill" : "star") {
            library.setWatchlisted(key, !listed)
        }
        .help(listed ? "Remove from your watchlist" : "Add to your watchlist")
        // A status that pressing toggles: it shows whether it's watched.
        Button(watched ? "Watched" : "Unwatched", systemImage: watched ? "checkmark.circle.fill" : "circle") {
            library.setWatched(items, of: detail, !watched)
        }
        .help(watched ? "Mark as unwatched" : "Mark as watched")
    }
}

/// A cover's marks: a star at its top leading corner if it's on the
/// watchlist, and a check at its trailing one if it's watched.
struct CoverMarks: View {
    let listed: Bool
    let watched: Bool
    var padding: CGFloat = 6

    var body: some View {
        HStack(alignment: .top) {
            if listed { mark("star.circle.fill", .yellow) }
            Spacer()
            // Green, not the accent color, which is white on tvOS.
            if watched { mark("checkmark.circle.fill", .green) }
        }
        .padding(padding)
    }

    private func mark(_ symbol: String, _ color: Color) -> some View {
        Image(systemName: symbol)
            #if os(macOS)
            .font(.title3)
            #endif
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, color)
            .shadow(color: .black.opacity(0.3), radius: 2)
    }
}
