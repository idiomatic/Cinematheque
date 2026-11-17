import CCinematheque
import Foundation
import Observation

/// A cover: a byte range of a file in a repository.
struct Cover: Codable, Hashable {
    let url: String
    let offset: Int
    let length: Int
    /// Changes when the file does.
    let stamp: String
}

/// One tile of the grid: a movie, or a season of a series.
struct Tile: Codable, Identifiable, Hashable {
    let key: String
    let name: String
    let year: Int?
    let kind: String
    let season: Int?
    let cover: Cover?
    /// This user's: every item watched, and how far along (0 to 1).
    let watched: Bool
    let progress: Double

    var id: String { season.map { "\(key)#\($0)" } ?? key }
    var isSeries: Bool { kind == "series" }
}

/// One title in full: its metadata, covers, items, and where each copy is.
struct TitleDetail: Codable {
    struct Copy: Codable, Hashable {
        let url: String
        let size: Int
        let mtime: String
        let repository: String
    }

    struct Rendition: Codable, Hashable {
        let label: String
        let name: String
        let copies: [Copy]
    }

    struct Item: Codable, Hashable, Identifiable {
        let key: String
        /// An episode's `title`, `description`, and `duration`.
        let fields: [String: String]
        let renditions: [Rendition]
        /// This user's playhead, in milliseconds.
        let position: Int
        let duration: Int
        let watched: Bool
        var id: String { key }

        /// The season and episode of `e/s03e17`.
        var episode: (season: Int, number: Int)? {
            let numbers = key.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            return key.hasPrefix("e/s") && numbers.count >= 2 ? (numbers[0], numbers[1]) : nil
        }
    }

    let key: String
    let name: String
    let year: Int?
    let aliasOf: String?
    let aliases: [String]
    /// `description`, `genre`, `released`, and `network`.
    let fields: [String: String]
    /// By field: `art`, `art:s01`...
    let covers: [String: Cover]
    let items: [Item]
}

struct Repository: Codable, Identifiable, Hashable {
    let id: String
    let url: String
    let rendition: String
    let skip: String
    let copies: Int
}

struct Member: Codable, Identifiable, Hashable {
    let key: String
    let founder: Bool
    let you: Bool
    var id: String { key }
}

struct Status: Codable {
    let user: String
    let library: String?
    let founder: String?
    let members: Int
}

/// The core's handle, shared with long operations on other threads, which
/// the core allows (see cinematheque.h).
private nonisolated struct Handle: @unchecked Sendable {
    let pointer: OpaquePointer
}

/// The library, through the core's C interface.
@MainActor @Observable
final class Library {
    private var handle: Handle?
    private(set) var status: Status?
    private(set) var tiles: [Tile] = []
    private(set) var watchlist: Set<String> = []
    private(set) var repositories: [Repository] = []
    private(set) var members: [Member] = []
    var error: String?
    /// What a long operation is doing, if one is running.
    private(set) var activity: String?
    /// Counts changes, so views showing details can refresh.
    private(set) var revision = 0

    var hasLibrary: Bool { status?.library != nil }

    /// Opens the peer's home: `CINEMATHEQUE_HOME`, or the default.
    init() {
        guard let pointer = cq_open(nil) else {
            error = "Couldn't open the peer's home (\(String(cString: cq_error())))."
            return
        }
        handle = Handle(pointer: pointer)
        reload()
    }

    func reload() {
        status = decode(Status.self) { cq_status($0) }
        guard hasLibrary else { return }
        tiles = (decode([Tile].self) { cq_tiles($0) } ?? []).sorted {
            ($0.name.localizedStandardCompare($1.name), $0.year ?? 0, $0.season ?? 0) < (.orderedSame, $1.year ?? 0, $1.season ?? 0)
        }
        watchlist = Set(decode([String].self) { cq_watchlist($0) } ?? [])
        repositories = decode([Repository].self) { cq_repos($0) } ?? []
        members = decode([Member].self) { cq_members($0) } ?? []
        revision += 1
    }

    func detail(_ key: String) -> TitleDetail? {
        decode(TitleDetail.self) { cq_title($0, key) }
    }

    var secret: String? { decode(String.self) { cq_secret($0) } }

    // Setting up.

    /// Creates a library (`founder` nil), or joins the one `founder` founded.
    func found(_ founder: String?) { check { cq_found($0, founder) } }

    /// Acts as the user whose secret it is, before creating or joining.
    func link(_ secret: String) { check { cq_link($0, secret) } }

    // Managing.

    func addRepository(_ url: String, rendition: String?, skip: String?) {
        check { cq_repo_add($0, url, rendition, skip) }
    }

    func setRepository(_ id: String, rendition: String?, skip: String?) {
        check { cq_repo_set($0, id, rendition, skip) }
    }

    func removeRepository(_ id: String) { check { cq_repo_remove($0, id) } }

    func setMember(_ key: String, _ add: Bool) { check { cq_member($0, key, add ? 1 : 0) } }

    /// Crawls every repository, then syncs with peers found or added.
    func refresh() async {
        await long("Crawling") { cq_crawl($0) }
        await long("Syncing") { cq_sync($0, nil) }
    }

    func crawl() async { await long("Crawling") { cq_crawl($0) } }

    func sync(_ url: String? = nil) async { await long("Syncing") { cq_sync($0, url) } }

    /// Reads an item's metadata from its file, in the background.
    func describe(_ itemKey: String) async {
        guard let handle else { return }
        let ok = await Task.detached { cq_describe(handle.pointer, itemKey) == 0 }.value
        if ok { revision += 1 }
    }

    // This user's.

    /// Records this user's playhead in an item (a title's key and an
    /// item's, e.g., "t/m/alien/1979/v/-").
    func setPlayhead(_ item: String, position: Double, duration: Double) {
        guard position.isFinite, duration.isFinite, duration > 0 else { return }
        check(reload: false) { cq_set_playhead($0, item, UInt64(max(0, position) * 1000), UInt64(duration * 1000)) }
        revision += 1
    }

    func setWatched(_ item: String, _ watched: Bool) {
        check(reload: false) { cq_set_watched($0, item, watched ? 1 : 0) }
        revision += 1
    }

    func setWatchlisted(_ title: String, _ on: Bool) {
        check(reload: false) { cq_set_watchlisted($0, title, on ? 1 : 0) }
        watchlist = Set(decode([String].self) { cq_watchlist($0) } ?? [])
    }

    // Calling the core.

    private func long(_ what: String, _ body: @escaping @Sendable (OpaquePointer) -> UnsafeMutablePointer<CChar>?) async {
        guard let handle, activity == nil else { return }
        activity = what
        let failure: String? = await Task.detached {
            guard let text = body(handle.pointer) else { return String(cString: cq_error()) }
            defer { cq_free(text) }
            // Report the first failure among the results, if any.
            let data = Data(bytes: text, count: strlen(text))
            let results = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
            return results.compactMap { r in (r["error"] as? String).map { "\(r["url"] ?? ""): \($0)" } }.first
        }.value
        activity = nil
        if let failure { error = failure }
        reload()
    }

    private func check(reload again: Bool = true, _ body: (OpaquePointer) -> Int32) {
        guard let handle else { return }
        if body(handle.pointer) != 0 {
            let reason = String(cString: cq_error())
            error = reason == "Busy" ? "Wait until \(activity?.lowercased() ?? "the library") finishes." : reason
        }
        if again { reload() }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ body: (OpaquePointer) -> UnsafeMutablePointer<CChar>?) -> T? {
        guard let handle else { return nil }
        guard let text = body(handle.pointer) else {
            error = String(cString: cq_error())
            return nil
        }
        defer { cq_free(text) }
        return try? JSONDecoder().decode(T.self, from: Data(bytes: text, count: strlen(text)))
    }

    isolated deinit {
        if let handle { cq_close(handle.pointer) }
    }
}

extension ComparisonResult: @retroactive Comparable {
    public static func < (a: ComparisonResult, b: ComparisonResult) -> Bool { a.rawValue < b.rawValue }
}
