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
    /// The cover's placeholder, a ThumbHash in base64.
    let thumb: String?
    /// This user's: every item watched, and how far along (0 to 1).
    let watched: Bool
    let progress: Double

    var id: String { season.map { "\(key)#\($0)" } ?? key }
    var isSeries: Bool { kind == "series" }
    /// "Season 3", or "Specials" for season 0.
    var seasonName: String? { season.map { $0 == 0 ? "Specials" : "Season \($0)" } }
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

        /// The season and episode of `e/s03e17`; a special (`e/s00-name`)
        /// is season 0, episode 0.
        var episode: (season: Int, number: Int)? {
            if key.hasPrefix("e/s00-") { return (0, 0) }
            let numbers = key.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            return key.hasPrefix("e/s") && numbers.count >= 2 ? (numbers[0], numbers[1]) : nil
        }

        /// A version's name: its edition as written, or "Standard".
        var versionName: String {
            fields["edition"] ?? (key.hasPrefix("v/-") ? "Standard" : key.dropFirst(2).replacingOccurrences(of: "-", with: " ").capitalized)
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

    /// Its server and folders, as a person reads them: "art › Movies ›
    /// 2160p".
    var displayName: String {
        guard let u = URL(string: url), let host = u.host() else { return url.removingPercentEncoding ?? url }
        let parts = u.pathComponents.filter { $0 != "/" }.compactMap { $0.removingPercentEncoding }
        // A NAS's shared folder (e.g., Video) is seldom worth showing.
        let shown = parts.count > 2 ? Array(parts.dropFirst()) : parts
        return ([host.replacing(/\.local$/, with: "")] + shown).joined(separator: " › ")
    }
}

struct Member: Codable, Identifiable, Hashable {
    let key: String
    let name: String?
    let founder: Bool
    let you: Bool
    var id: String { key }
}

/// One of this user's devices that has a name.
struct Device: Codable, Identifiable, Hashable {
    let key: String
    let name: String
    let you: Bool
    var id: String { key }
}

/// A peer found nearby, or added by address.
struct Peer: Codable, Identifiable, Hashable {
    let url: String
    let device: String?
    let person: String?
    /// Its user's key.
    let user: String?
    /// Of this library.
    let ours: Bool
    /// Its user is a member.
    let member: Bool
    let added: Bool
    var id: String { url }
}

/// A folder on this device, served as a repository at `prefix`.
struct Folder: Codable, Identifiable, Hashable {
    let prefix: String
    let path: String
    /// The repository's URL, as added.
    var url: String
    var id: String { prefix }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

struct Status: Codable {
    let user: String
    /// Acting as the user of another of the user's devices.
    let linked: Bool
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
    private(set) var devices: [Device] = []
    /// What last went wrong, shown modelessly (`ProblemBar`) until the
    /// next action of its kind succeeds or it's dismissed; never an alert.
    var problem: String?
    private enum Kind { case refresh, change, read, serve }
    private var problemKind: Kind?
    private var refreshedAtLaunch = false
    /// What a long operation is doing, if one is running.
    private(set) var activity: String?
    /// How far it has come, from the core, while one runs.
    private(set) var progress: Progress?

    struct Progress: Codable, Equatable {
        /// `crawling`, `describing`, or `syncing`.
        let phase: String?
        let done: Int
        let total: Int
    }
    /// Counts changes, so views showing details can refresh.
    private(set) var revision = 0

    var hasLibrary: Bool { status?.library != nil }
    var linked: Bool { status?.linked ?? false }

    /// Opens the peer's home: `home`, else `CINEMATHEQUE_HOME`, else the
    /// platform's default (see the core's `defaultHome`).
    init(home: String? = nil) {
        guard let pointer = cq_open(home) else {
            problem = "Couldn't open the peer's home (\(String(cString: cq_error())))."
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
        devices = decode([Device].self) { cq_devices($0) } ?? []
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

    /// Once a launch, if there's a library: serves it, syncs, names this
    /// device and user if they have no names yet (e.g., the computer's name
    /// and the account's first name), then crawls (peers may bring its
    /// repositories to a device that has none yet).
    func startAtLaunch(device: String, user: String? = nil) async {
        guard !refreshedAtLaunch, hasLibrary else { return }
        refreshedAtLaunch = true
        if sharing { serve() }
        // Syncing before writing anything: a device whose replica was lost
        // (as tvOS may purge one) learns its own writes back, and so where
        // its numbering left off, before it writes again.
        let synced = await long("Syncing") { cq_sync($0, nil) }
        if !devices.contains(where: \.you), !device.isEmpty { setName(.device, device) }
        if let user, !user.isEmpty, members.first(where: \.you)?.name == nil { setName(.user, user) }
        let crawled = await long("Crawling") { cq_crawl($0) }
        report(.refresh, synced ?? crawled)
    }

    // Names and peers.

    enum Named: String { case user, device }

    /// Names this user or this device, for every peer to show in place of
    /// keys, and advertises the new name.
    func setName(_ which: Named, _ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        check { cq_set_name($0, which.rawValue, trimmed) }
        if servingPort != nil { serve() }
    }

    /// This user's name, and this device's.
    var userName: String? { members.first(where: \.you)?.name }
    var deviceName: String? { devices.first(where: \.you)?.name }

    /// Peers found nearby (listening for 2 seconds) and added by address.
    func peers() async -> [Peer] {
        guard let handle else { return [] }
        let data: Data? = await Task.detached {
            guard let text = cq_peers(handle.pointer) else { return nil }
            defer { cq_free(text) }
            return Data(bytes: text, count: strlen(text))
        }.value
        return data.flatMap { try? JSONDecoder().decode([Peer].self, from: $0) } ?? []
    }

    /// Adds a peer by address (e.g., one off the network), or removes one.
    func setPeer(_ url: String, _ add: Bool) { check(reload: false) { cq_peer($0, url, add ? 1 : 0) } }

    // Folders on this device.

    /// This device's folders served as repositories, for this library.
    private(set) var folders: [Folder] = []

    private var foldersKey: String { "folders-" + (status?.library ?? "") }

    private func loadFolders() {
        let data = UserDefaults.standard.data(forKey: foldersKey)
        folders = data.flatMap { try? JSONDecoder().decode([Folder].self, from: $0) } ?? []
    }

    private func saveFolders() {
        UserDefaults.standard.set(try? JSONEncoder().encode(folders), forKey: foldersKey)
    }

    /// The folder a repository serves from this device, if it's one.
    func folder(of repository: Repository) -> Folder? {
        folders.first { $0.url == repository.url }
    }

    /// Serves a folder of this device as a repository at `http://HOST:PORT/
    /// NAME/` (`host` being this device's name on the network, e.g.,
    /// `firefly.local`), adds it, and crawls it.
    func addFolder(_ path: String, host: String) async {
        let base = URL(fileURLWithPath: path).lastPathComponent
            .lowercased().replacing(/[^a-z0-9]+/, with: "-").trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        var prefix = base.isEmpty ? "folder" : base
        var n = 2
        while folders.contains(where: { $0.prefix == prefix }) {
            prefix = "\(base)-\(n)"
            n += 1
        }
        folders.append(Folder(prefix: prefix, path: path, url: ""))
        serve()
        guard let port = servingPort else {
            folders.removeLast()
            return
        }
        folders[folders.count - 1].url = "http://\(host):\(port)/\(prefix)/"
        saveFolders()
        addRepository(folders[folders.count - 1].url, rendition: nil, skip: ",")
        await crawl()
    }

    /// Stops serving a folder, and removes its repository.
    func removeFolder(_ folder: Folder) {
        if let repo = repositories.first(where: { $0.url == folder.url }) { removeRepository(repo.id) }
        folders.removeAll { $0.prefix == folder.prefix }
        saveFolders()
        serve()
    }

    /// The port this device serves on, while it does.
    private(set) var servingPort: Int?

    /// Serves this library to peers (their syncs, so this device's changes,
    /// such as playheads, reach them), and this device's folders, while the
    /// app runs, on the port it served on last, so folders' addresses stay
    /// put.
    func serve() {
        guard let handle, hasLibrary else { return }
        if folders.isEmpty { loadFolders() }
        let defaults = UserDefaults.standard
        let mounts = folders.map { ["prefix": $0.prefix, "path": $0.path] }
        let json = String(decoding: (try? JSONSerialization.data(withJSONObject: mounts)) ?? Data("[]".utf8), as: UTF8.self)
        let port = cq_serve(handle.pointer, Int32(defaults.integer(forKey: "servingPort")), json)
        if port < 0 {
            servingPort = nil
            report(.serve, "Couldn't share the library with your other devices: \(String(cString: cq_error())).")
        } else {
            servingPort = Int(port)
            defaults.set(Int(port), forKey: "servingPort")
            report(.serve, nil)
            repoint(Int(port))
        }
    }

    /// Whether this device shares the library (serves it) while the app
    /// runs: on unless turned off.
    var sharing: Bool {
        get { UserDefaults.standard.object(forKey: "sharing") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "sharing")
            if newValue { serve() } else { stopServing() }
        }
    }

    func stopServing() {
        guard let handle else { return }
        cq_stop_serving(handle.pointer)
        servingPort = nil
    }

    /// Moves this device's folders' repositories to the port it got, if it
    /// had to take another (another program had the last one).
    private func repoint(_ port: Int) {
        for (i, folder) in folders.enumerated() {
            guard var parts = URLComponents(string: folder.url), parts.port != nil, parts.port != port else { continue }
            parts.port = port
            guard let moved = parts.string else { continue }
            let old = repositories.first { $0.url == folder.url }
            addRepository(moved, rendition: old?.rendition.isEmpty == false ? old?.rendition : nil, skip: old?.skip ?? ",")
            if let old { removeRepository(old.id) }
            folders[i].url = moved
        }
        saveFolders()
    }

    /// Syncs with peers found or added, then crawls every repository: what
    /// peers have crawled and described arrives first, so crawling then
    /// finds little to do.
    func refresh() async {
        let synced = await long("Syncing") { cq_sync($0, nil) }
        let crawled = await long("Crawling") { cq_crawl($0) }
        report(.refresh, synced ?? crawled)
    }

    func crawl() async { report(.refresh, await long("Crawling") { cq_crawl($0) }) }

    func sync(_ url: String? = nil) async { report(.refresh, await long("Syncing") { cq_sync($0, url) }) }

    /// Reads an item's metadata from its file, in the background.
    func describe(_ itemKey: String) async {
        guard let handle else { return }
        let ok = await Task.detached { cq_describe(handle.pointer, itemKey) == 0 }.value
        if ok { revision += 1 }
    }

    /// Reads a season's episodes' metadata (titles, descriptions,
    /// durations), one at a time, where not yet read: a crawl reads only a
    /// season's first episode.
    func describeEpisodes(of key: String, season: Int) async {
        guard let detail = detail(key) else { return }
        for item in Playback.items(detail, season: season) where item.fields["duration"] == nil {
            if Task.isCancelled { return }
            await describe("\(detail.key)/\(item.key)")
        }
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

    /// Which titles a crawl should describe first: those on screen.
    func prioritize(_ titleKeys: Set<String>) {
        guard let handle, let json = try? JSONEncoder().encode(Array(titleKeys)) else { return }
        _ = cq_prioritize(handle.pointer, String(decoding: json, as: UTF8.self))
    }

    // Calling the core.

    /// A long operation's failures in a sentence: the first, by its
    /// server's name and the error in words, and how many more there were.
    nonisolated static func describe(_ failed: [(url: String, error: String)], _ what: String) -> String? {
        guard let first = failed.first else { return nil }
        let host = URL(string: first.url)?.host() ?? first.url
        // "ConnectionRefused" to "connection refused".
        let reason = first.error.replacing(/([a-z])([A-Z])/) { "\($0.1) \($0.2)" }.lowercased()
        let others = failed.count - 1
        let more = others == 0 ? "" : " (and \(others) more)"
        return "\(what) failed for \(host)\(more): \(reason)."
    }

    /// Shows a problem, or with none, clears one of the same kind.
    private func report(_ kind: Kind, _ failure: String?) {
        if let failure {
            problem = failure
            problemKind = kind
        } else if problemKind == kind {
            problem = nil
            problemKind = nil
        }
    }

    /// Runs a long operation off the main thread; returns why it failed, if
    /// it did.
    private func long(_ what: String, _ body: @escaping @Sendable (OpaquePointer) -> UnsafeMutablePointer<CChar>?) async -> String? {
        guard let handle, activity == nil else { return nil }
        activity = what
        // Show what the operation commits as it commits it (titles once
        // crawled, covers as they're found), reloading at most each second,
        // and how far it has come, twice a second.
        let watcher = Task { [weak self] in
            var seen = cq_data_version(handle.pointer)
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                let progress = self.decode(Progress.self) { cq_progress($0) }
                if progress != self.progress { self.progress = progress }
                tick += 1
                guard tick % 2 == 0 else { continue }
                let now = cq_data_version(handle.pointer)
                if now != seen {
                    seen = now
                    self.reload()
                }
            }
        }
        defer {
            watcher.cancel()
            progress = nil
        }
        let failure: String? = await Task.detached {
            guard let text = body(handle.pointer) else { return String(cString: cq_error()) }
            defer { cq_free(text) }
            let data = Data(bytes: text, count: strlen(text))
            let results = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
            let failed = results.compactMap { r in (r["error"] as? String).map { (url: r["url"] as? String ?? "", error: $0) } }
            return Library.describe(failed, what)
        }.value
        activity = nil
        reload()
        return failure
    }

    private func check(reload again: Bool = true, _ body: (OpaquePointer) -> Int32) {
        guard let handle else { return }
        if body(handle.pointer) != 0 {
            let reason = String(cString: cq_error())
            report(.change, reason == "Busy" ? "Couldn't change the library while \(activity?.lowercased() ?? "it's busy"); try again when it's done." : reason)
        } else {
            report(.change, nil)
        }
        if again { reload() }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ body: (OpaquePointer) -> UnsafeMutablePointer<CChar>?) -> T? {
        guard let handle else { return nil }
        guard let text = body(handle.pointer) else {
            report(.read, String(cString: cq_error()))
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
