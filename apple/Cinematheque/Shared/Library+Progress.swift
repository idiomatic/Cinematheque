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
        check { cq_set_progress($0, item, UInt64(min(max(0, position), day) * 1000), UInt64(min(duration, day * 10) * 1000)) }
        revision += 1
    }

    /// Marks a tile's items watched, or unwatched (forgetting where this
    /// person stopped, too): a movie's, or a season's.
    func markWatched(_ tile: Tile, _ watched: Bool) {
        guard let detail = detail(tile.key) else { return }
        setWatched(Playback.items(detail, season: tile.season), of: detail, watched)
    }

    /// As `markWatched`, every season of the tile's series.
    func markSeriesWatched(_ tile: Tile, _ watched: Bool) {
        guard let detail = detail(tile.key) else { return }
        setWatched(detail.items, of: detail, watched)
    }

    /// Forgets the titles this person has watched through (Watched's):
    /// each one's items unwatched, as Mark as Unwatched would, an item at a
    /// time, then the tiles reloaded once. What's partway through stays.
    func forgetWatched() {
        for tile in tiles where tile.watched {
            guard let detail = detail(tile.key) else { continue }
            for item in Playback.items(detail, season: tile.season) {
                check { cq_mark_unwatched($0, "\(detail.key)/\(item.key)") }
            }
        }
        revision += 1
        changed()
        reload()
    }

    /// Marks an item watched, or unwatched, forgetting where this person
    /// stopped (the core's rule).
    func setWatched(_ item: String, _ watched: Bool) {
        check { watched ? cq_mark_watched($0, item) : cq_mark_unwatched($0, item) }
        revision += 1
        changed()
    }

    /// What goes on a list: a movie, by its title's key, or a season, by
    /// its tile's (`<title key>#<season>`), each on its own.
    static func listKey(_ title: String, season: Int?) -> String {
        season.map { "\(title)#\($0)" } ?? title
    }

    /// Reads the lists again, assigning only what differs.
    func readLists() {
        let read = decode([UserList].self) { cq_lists($0) } ?? []
        if read != lists {
            lists = read
            listed = Set(read.filter(\.isMine).flatMap(\.titles))
            onAnyList = Set(read.flatMap(\.titles))
        }
    }

    /// This person's lists `key` is on.
    func lists(holding key: String) -> [UserList] {
        myLists.filter { $0.titles.contains(key) }
    }

    /// Puts `key` on the list `id`, or takes it off.
    func setListed(_ key: String, on id: String, _ on: Bool) {
        check { on ? cq_list_add_title($0, id, key) : cq_list_remove_title($0, id, key) }
        readLists()
        changed()
    }

    /// Puts a title not in the library yet on the list `id`, as a
    /// placeholder, keyed as its file will be (`cq_list_want`), so it's on
    /// the list as it comes.
    func want(on id: String, kind: TitleKind, name: String, year: Int?, season: Int?, note: String) {
        let cKind = switch kind {
        case .movie: CQ_MOVIE
        case .series: CQ_SERIES
        }
        _ = name.withCString { cName in
            note.withCString { cNote in
                // Absent integers are -1, as the core takes them.
                var want = cq_want(kind: cKind, name: cName, year: Int32(year ?? -1), season: Int32(season ?? -1), note: cNote)
                return decode(String.self) { cq_list_want($0, id, &want) }
            }
        }
        readLists()
        changed()
    }

    /// The placeholder keyed `key`, on whichever list, if any.
    func wanted(_ key: String) -> UserList.Wanted? {
        for list in lists { if let w = list.wanted?.first(where: { $0.key == key }) { return w } }
        return nil
    }

    /// Takes a placeholder off every list of this person's it's on.
    func unwant(_ key: String) {
        for list in myLists where list.wanted?.contains(where: { $0.key == key }) == true { setListed(key, on: list.id, false) }
    }

    /// Whether a placeholder is on any of this person's lists, to take off.
    func isWantedByMe(_ key: String) -> Bool {
        myLists.contains { $0.wanted?.contains { $0.key == key } == true }
    }

    /// Shares a list of this person's with everyone in the library, or
    /// makes it theirs alone again.
    func shareList(_ id: String, _ on: Bool) {
        check { on ? cq_list_share($0, id) : cq_list_stop_sharing($0, id) }
        readLists()
        changed()
    }

    /// Makes a list, returning its ID.
    @discardableResult
    func createList(named name: String) -> String? {
        let id = decode(String.self) { cq_list_create($0, name) }
        readLists()
        changed()
        return id
    }

    func renameList(_ id: String, to name: String) {
        check { cq_list_rename($0, id, name) }
        readLists()
        changed()
    }

    /// Deletes a list, for good; its titles stay in the library.
    func removeList(_ id: String) {
        check { cq_list_remove($0, id) }
        readLists()
        changed()
    }

    /// Which titles a crawl should describe first: those on screen.
    func prioritize(_ titleKeys: Set<String>) {
        guard let handle else { return }
        _ = withCStrings(Array(titleKeys)) { cq_prioritize(handle.pointer, $0, $1) }
    }

}
