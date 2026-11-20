import CCinematheque
import Foundation

extension Library {
    // This person's.

    /// Records this person's progress in an item (a title's key and an
    /// item's, e.g., "t/m/alien/1979/v/-").
    func setProgress(_ item: String, position: Double, duration: Double) {
        guard position.isFinite, duration.isFinite, duration > 0 else { return }
        // Clamped (a position to a day, a duration to ten): a huge finite
        // value would trap in the conversion.
        let day = 86_400.0
        check(reload: false) { cq_set_progress($0, item, UInt64(min(max(0, position), day) * 1000), UInt64(min(duration, day * 10) * 1000)) }
        revision += 1
    }

    /// Marks a tile's items watched, or unwatched (forgetting where this
    /// person stopped, too): a movie's, a season's, or with `wholeTitle`,
    /// every season's.
    func markWatched(_ tile: Tile, _ watched: Bool, wholeTitle: Bool = false) {
        guard let detail = detail(tile.key) else { return }
        setWatched(wholeTitle ? detail.items : Playback.items(detail, season: tile.season), of: detail, watched)
    }

    /// Marks an item watched, or unwatched, forgetting where this person
    /// stopped (the core's rule).
    func setWatched(_ item: String, _ watched: Bool) {
        check(reload: false) { cq_set_watched($0, item, watched ? 1 : 0) }
        revision += 1
        changed()
    }

    /// What's on the watchlist: a movie, by its title's key, or a season,
    /// by its tile's (`<title key>#<season>`), each on its own.
    static func watchlistKey(_ title: String, season: Int?) -> String {
        season.map { "\(title)#\($0)" } ?? title
    }

    func setWatchlisted(_ key: String, _ on: Bool) {
        check(reload: false) { cq_set_watchlisted($0, key, on ? 1 : 0) }
        watchlist = Set(decode([String].self) { cq_watchlist($0) } ?? [])
        changed()
    }

    /// Which titles a crawl should describe first: those on screen.
    func prioritize(_ titleKeys: Set<String>) {
        guard let handle, let json = try? JSONEncoder().encode(Array(titleKeys)) else { return }
        _ = cq_prioritize(handle.pointer, String(decoding: json, as: UTF8.self))
    }

}
