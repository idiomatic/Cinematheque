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
        check(reload: false) { cq_set_listed($0, id, key, on ? 1 : 0) }
        readLists()
        changed()
    }

    /// Puts a title not in the library yet on the list `id`, as a
    /// placeholder, keyed as its file will be (`cq_list_want`), so it's on
    /// the list as it comes.
    func want(on id: String, series: Bool, name: String, year: Int?, season: Int?, note: String) {
        struct Want: Encodable {
            let kind: String
            let name: String
            let year: Int?
            let season: Int?
            let note: String
        }
        guard let data = try? JSONEncoder().encode(Want(kind: series ? "series" : "movie", name: name, year: year, season: season, note: note)) else { return }
        _ = decode(String.self) { cq_list_want($0, id, String(decoding: data, as: UTF8.self)) }
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
        check(reload: false) { cq_list_share($0, id, on ? 1 : 0) }
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
        check(reload: false) { cq_list_rename($0, id, name) }
        readLists()
        changed()
    }

    /// Deletes a list, for good; its titles stay in the library.
    func removeList(_ id: String) {
        check(reload: false) { cq_list_remove($0, id) }
        readLists()
        changed()
    }

    /// Which titles a crawl should describe first: those on screen.
    func prioritize(_ titleKeys: Set<String>) {
        guard let handle, let json = try? JSONEncoder().encode(Array(titleKeys)) else { return }
        _ = cq_prioritize(handle.pointer, String(decoding: json, as: UTF8.self))
    }

}
