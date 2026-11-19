import CCinematheque
import Foundation
import Observation
#if os(macOS)
import SystemConfiguration
#endif

/// A cover: a byte range of a file in a source.
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
    /// This user's: every item watched; how far along (0 to 1), by running
    /// time: how many milliseconds have `elapsed` (watched items whole,
    /// those partway to their positions) of the `runtime`; and whether any
    /// item has a playhead.
    let watched: Bool
    let progress: Double
    let elapsed: Int
    let runtime: Int
    let started: Bool
    /// Every copy it has is on a drive that isn't there (an absent
    /// directory of its source's): shown dimmed.
    var absent = false

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
        let source: String
        /// On a drive that isn't there: tried last.
        var absent = false
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
    /// `description`, `genre`, `released`, and `network`.
    let fields: [String: String]
    /// By field: `art`, `art:s01`...
    let covers: [String: Cover]
    let items: [Item]
}

struct Source: Codable, Identifiable, Hashable {
    /// A directory of it that held files and lists none now (an unplugged
    /// drive's mount point): relative to it, empty for the whole of it, and
    /// when it was noticed, in milliseconds since the epoch.
    struct Absence: Codable, Hashable {
        let dir: String
        let since: Double

        var name: String { dir.isEmpty ? "All of it" : dir }
        var date: Date { Date(timeIntervalSince1970: since / 1000) }
    }

    let id: String
    let url: String
    let rendition: String
    let skip: String
    let copies: Int
    var absent: [Absence] = []
    /// A device's downloads, which no one crawls (see the core's
    /// download.zig).
    var managed = false

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
    /// For a new device offering to pair (`url` is where to pair it), what
    /// for: `link`, to be another of this user's, or `join`, a new member's.
    let pairing: String?
    var id: String { url }
    var linking: Bool { pairing == "link" }
    var joining: Bool { pairing == "join" }
    /// Its device's and person's names, if they advertise any.
    var deviceName: String? { device.flatMap { $0.isEmpty ? nil : $0 } }
    var personName: String? { person.flatMap { $0.isEmpty ? nil : $0 } }
}

/// A device just paired: its user's key and its own.
nonisolated struct Paired: Decodable {
    let user: String
    let device: String
}

/// A folder on this device, served as a source at `prefix`.
struct Folder: Codable, Identifiable, Hashable {
    let prefix: String
    let path: String
    /// The source's URL, as added.
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
    private(set) var sources: [Source] = []
    private(set) var members: [Member] = []
    private(set) var devices: [Device] = []
    /// What last went wrong, shown modelessly (`ProblemBar`) until the
    /// next action of its kind succeeds or it's dismissed; never an alert.
    var problem: String?
    private enum Kind { case refresh, change, read, serve, download }
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
            problem = "Couldn't open Cinematheque's data (\(String(cString: cq_error())))."
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
        sources = decode([Source].self) { cq_repos($0) } ?? []
        members = decode([Member].self) { cq_members($0) } ?? []
        devices = decode([Device].self) { cq_devices($0) } ?? []
        #if os(macOS)
        reloadDownloads()
        #endif
        revision += 1
    }

    func detail(_ key: String) -> TitleDetail? {
        decode(TitleDetail.self) { cq_title($0, key) }
    }


    // Setting up.

    /// Why this device last left a library, for setup to say: removed, by a
    /// peer (as a sync was told, signed), from its library.
    private(set) var removedBy: String?

    /// Leaves the library, as a device removed from it must: forgets it and
    /// this device's identity, so setup can pair it again as a new device.
    func leave(removedBy peer: String) {
        guard let handle, cq_leave(handle.pointer) == 0 else {
            report(.refresh, "Couldn't leave the library: \(String(cString: cq_error())).")
            return
        }
        Platform.forget()
        removedBy = peer
        servingPort = nil
        refreshedAtLaunch = false
        problem = nil
        reload()
    }

    /// Creates a library, founded by this user; joining one is by pairing.
    func found() { check { cq_found($0) } }

    // Pairing a new device, by a code it shows, with a member's: to be
    // another of that user's devices, or a new member's.

    /// A new device's offer: the code to show, and whether it's paired (it
    /// has the library) or stopped, after too many wrong codes.
    struct Pairing: Codable, Equatable {
        let code: String?
        let paired: Bool
        let closed: Bool
    }

    /// On this device, before it has a library: offers to pair, to be
    /// another of a member's devices or (`join`) a new member's, with a new
    /// code.
    func offerPairing(join: Bool) -> Pairing? {
        // As setup leaves, once paired, its screen may ask once more.
        guard !hasLibrary else { return nil }
        return decode(Pairing.self) { cq_pair_offer($0, Platform.deviceName, join ? 1 : 0) }
    }

    /// The offer's state; once paired, this device has its user and library.
    func checkPairing() -> Pairing? {
        guard !hasLibrary else { return nil }
        let state = decode(Pairing.self) { cq_pair_check($0) }
        if state?.paired == true { reload() }
        return state
    }

    func stopPairing() {
        if let handle { cq_pair_stop(handle.pointer) }
    }

    /// Pairs the new device `peer`, given the code it shows: sends it the
    /// library, and to link it, this user's secret. Returns who it is
    /// (for `welcome`), or what went wrong, in words.
    func pair(_ peer: Peer, code: String) async -> (Paired?, String?) {
        guard let handle else { return (nil, "The library isn't open.") }
        let url = peer.url
        let join: Int32 = peer.joining ? 1 : 0
        let name = peer.deviceName ?? "The device"
        let (paired, failure): (Paired?, String?) = await Task.detached {
            guard let text = cq_pair(handle.pointer, url, join, code) else { return (nil, String(cString: cq_error())) }
            defer { cq_free(text) }
            return (try? JSONDecoder().decode(Paired.self, from: Data(bytes: text, count: strlen(text))), nil)
        }.value
        guard let failure else { return (paired, nil) }
        switch failure {
        case "WrongCode": return (nil, "That isn't the code \(name) shows. Check it, and try again.")
        case "Closed": return (nil, "\(name) stopped pairing after too many wrong codes. On it, show a new code.")
        default: return (nil, "Couldn't pair with \(name): \(failure).")
        }
    }

    /// Renames another of this user's devices (or this one), for every
    /// peer: as when its platform won't tell it its own name.
    func renameDevice(_ key: String, _ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let user = status?.user else { return }
        check { cq_name($0, key, user, trimmed) }
    }

    /// Copy racing (see the core's race.zig): `urls`, an item's copies, in
    /// the order to try them, those whose servers answer first; off the
    /// main thread, for up to 1.5 seconds.
    func race(_ urls: [URL]) async -> [URL] {
        guard urls.count > 1, let handle, let json = try? JSONEncoder().encode(urls.map(\.absoluteString)) else { return urls }
        let text = String(decoding: json, as: UTF8.self)
        let ordered: [String]? = await Task.detached {
            guard let out = cq_race(handle.pointer, text) else { return nil }
            defer { cq_free(out) }
            return try? JSONDecoder().decode([String].self, from: Data(bytes: out, count: strlen(out)))
        }.value
        return ordered?.compactMap(URL.init(string:)) ?? urls
    }

    /// Notes a copy that didn't load, so its server is raced last a while.
    func raceLost(_ url: URL) {
        guard let handle else { return }
        cq_race_lost(handle.pointer, url.absoluteString)
    }

    /// Forgets a source's absent directory, as if it were deleted: its
    /// copies go, for every device.
    func forgetAbsent(_ source: String, _ dir: String) { check { cq_forget_absent($0, source, dir) } }

    /// Removes another of this user's devices from the library: its later
    /// writes are refused, and it's served no more.
    func removeDevice(_ key: String) { check { cq_remove_device($0, key) } }

    /// Takes in a device just paired: names it as it advertised itself
    /// (until it names itself), so it's among its user's devices at once,
    /// and if it's joining, adds its user as a member.
    func welcome(_ paired: Paired, from peer: Peer) {
        if let name = peer.device, !name.isEmpty {
            check(reload: false) { cq_name($0, paired.device, paired.user, name) }
        }
        if peer.joining { check(reload: false) { cq_member($0, paired.user, 1) } }
        reload()
    }

    // Managing.

    func addSource(_ url: String, rendition: String?, skip: String?) {
        check { cq_repo_add($0, url, rendition, skip) }
    }

    func setSource(_ id: String, rendition: String?, skip: String?) {
        check { cq_repo_set($0, id, rendition, skip) }
    }

    func removeSource(_ id: String) { check { cq_repo_remove($0, id) } }

    func setMember(_ key: String, _ add: Bool) { check { cq_member($0, key, add ? 1 : 0) } }

    /// Once a launch, if there's a library: serves it, syncs, names this
    /// device and user if they have no names yet (e.g., the computer's name
    /// and the account's first name), then crawls (peers may bring its
    /// sources to a device that has none yet).
    func startAtLaunch(device: String, user: String? = nil) async {
        guard !refreshedAtLaunch, hasLibrary else { return }
        refreshedAtLaunch = true
        if sharing { serve() }
        // Syncing before writing anything: a device whose replica was lost
        // (as tvOS may purge one) learns its own writes back, and so where
        // its numbering left off, before it writes again.
        let synced = await long("Catching up", results: noteReceived) { cq_sync($0, nil) }
        var named = false
        if !devices.contains(where: \.you), !device.isEmpty { setName(.device, device); named = true }
        if let user, !user.isEmpty, members.first(where: \.you)?.name == nil { setName(.user, user); named = true }
        // Naming itself is a new device's first write, with its certificate:
        // its peers hear of it now, not a minute on.
        if named { changed() }
        let crawled = await long("Looking for new videos") { cq_crawl($0) }
        report(.refresh, synced ?? crawled)
        #if os(macOS)
        reconcileSoon()
        #endif
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

    /// The path a Mac's downloads are served at, beside its folders'.
    static let downloadsPrefix = "downloads"

    /// This device's folders served as sources, for this library.
    private(set) var folders: [Folder] = []
    /// Folders not there when last looked (on a drive unplugged, or a share
    /// unmounted), by prefix: served all the same, listed empty while gone,
    /// so crawls find them absent, their titles dimmed, not failed.
    private(set) var missingFolders: Set<String> = []

    /// Folders that aren't there now.
    private var absentFolders: Set<String> {
        Set(folders.filter { folder in
            var directory: ObjCBool = false
            return !FileManager.default.fileExists(atPath: folder.path, isDirectory: &directory) || !directory.boolValue
        }.map(\.prefix))
    }

    /// Notes folders that have come back, or gone, for Settings to show.
    private func checkFolders() {
        let now = absentFolders
        if now != missingFolders { missingFolders = now }
    }

    private var foldersKey: String { "folders-" + (status?.library ?? "") }

    private func loadFolders() {
        let data = UserDefaults.standard.data(forKey: foldersKey)
        folders = data.flatMap { try? JSONDecoder().decode([Folder].self, from: $0) } ?? []
    }

    private func saveFolders() {
        UserDefaults.standard.set(try? JSONEncoder().encode(folders), forKey: foldersKey)
    }

    /// The folder a source serves from this device, if it's one.
    func folder(of source: Source) -> Folder? {
        folders.first { $0.url == source.url }
    }

    /// Serves a folder of this device as a source at `http://HOST:PORT/
    /// NAME/` (`host` being this device's name on the network, e.g.,
    /// `firefly.local`), adds it, and crawls it.
    func addFolder(_ path: String, host: String) async {
        let base = URL(fileURLWithPath: path).lastPathComponent
            .lowercased().replacing(/[^a-z0-9]+/, with: "-").trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        var prefix = base.isEmpty ? "folder" : base
        var n = 2
        // Downloads have a prefix of their own.
        while folders.contains(where: { $0.prefix == prefix }) || prefix == Self.downloadsPrefix {
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
        addSource(folders[folders.count - 1].url, rendition: nil, skip: ",")
        await crawl()
    }

    /// Stops serving a folder, and removes its source.
    func removeFolder(_ folder: Folder) {
        if let source = sources.first(where: { $0.url == folder.url }) { removeSource(source.id) }
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
        missingFolders = absentFolders
        var mounts = folders.map { ["prefix": $0.prefix, "path": $0.path] }
        #if os(macOS)
        if downloads == nil { reloadDownloads() }
        try? FileManager.default.createDirectory(atPath: downloadsDir, withIntermediateDirectories: true)
        mounts.append(["prefix": Self.downloadsPrefix, "path": downloadsDir])
        #endif
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
            #if os(macOS)
            configureDownloads()
            #endif
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

    /// Moves this device's folders' sources to the port it got, if it
    /// had to take another (another program had the last one).
    private func repoint(_ port: Int) {
        for (i, folder) in folders.enumerated() {
            guard var parts = URLComponents(string: folder.url), parts.port != nil, parts.port != port else { continue }
            parts.port = port
            guard let moved = parts.string else { continue }
            let old = sources.first { $0.url == folder.url }
            addSource(moved, rendition: old?.rendition.isEmpty == false ? old?.rendition : nil, skip: old?.skip ?? ",")
            if let old { removeSource(old.id) }
            folders[i].url = moved
        }
        saveFolders()
    }

    /// Syncs with peers found or added, then crawls every source: what
    /// peers have crawled and described arrives first, so crawling then
    /// finds little to do.
    func refresh() async {
        let synced = await long("Catching up", results: noteReceived) { cq_sync($0, nil) }
        let crawled = await long("Looking for new videos") { cq_crawl($0) }
        report(.refresh, synced ?? crawled)
        #if os(macOS)
        reconcileSoon()
        #endif
    }

    func crawl() async { report(.refresh, await long("Looking for new videos") { cq_crawl($0) }) }

    func sync(_ url: String? = nil) async { report(.refresh, await long("Catching up", results: noteReceived) { cq_sync($0, url) }) }

    #if os(macOS)
    // Downloads, this Mac's (see the core's download.zig): kept in a folder
    // served as a source of its own, which no one crawls.

    struct Downloads: Decodable, Equatable {
        struct Held: Decodable, Equatable {
            let item: String
            let size: Int
        }

        struct Wanted: Decodable, Equatable {
            let key: String
            let rendition: String
        }

        struct Next: Decodable, Equatable {
            let title: String
            let episodes: Int
        }

        /// Watched since downloaded, and not pinned: `deletable` (waiting
        /// for its space to be needed) once another source holds it, else
        /// the only copy, for a person to delete or keep.
        struct Done: Decodable, Equatable {
            let item: String
            let deletable: Bool
        }

        let dir: String?
        let source: String?
        let drop_watched: Bool
        let held: [Held]
        let wanted: [Wanted]
        let next: [Next]
        let watched: [Done]
        let kept: [String]
        let free: Int?
        let floor: Int
        let running: Bool
        let done_mb: Int
        let total_mb: Int
    }

    private(set) var downloads: Downloads?
    private var reconciling: Task<Void, Never>?

    /// Where downloads go unless Settings says otherwise.
    static var defaultDownloads: String { URL.moviesDirectory.appending(path: "Cinematheque").path }

    var downloadsDir: String { downloads?.dir ?? Self.defaultDownloads }

    /// This Mac's name on the local network, e.g., `firefly.local`.
    static var localHost: String {
        let name = SCDynamicStoreCopyLocalHostName(nil) as String? ?? ProcessInfo.processInfo.hostName
        return name.hasSuffix(".local") ? name : name + ".local"
    }

    private func reloadDownloads() {
        let loaded = decode(Downloads.self) { cq_downloads($0) }
        guard loaded != downloads else { return }
        downloads = loaded
        downloadedTiles = Self.tiles(of: (loaded?.held ?? []).map(\.item))
        // A tile is waiting if all its watched downloads are; else it needs
        // a person.
        var watched: [String: Bool] = [:]
        for done in loaded?.watched ?? [] {
            for tile in Self.tiles(of: [done.item]) { watched[tile] = (watched[tile] ?? true) && done.deletable }
        }
        watchedTiles = watched
        if let d = downloads, let id = d.source, let dir = d.dir, let source = sources.first(where: { $0.id == id }) {
            Playback.downloads = .init(source: id, base: source.url, dir: dir)
        } else {
            Playback.downloads = nil
        }
    }

    /// Whether this Mac holds an item (its full key).
    func isDownloaded(_ item: String) -> Bool { downloads?.held.contains { $0.item == item } ?? false }

    /// Whether a title, season, or item is wanted, and being fetched if it
    /// isn't held.
    func isWanted(_ key: String) -> Bool {
        downloads?.wanted.contains { wanted in
            // The key, or a title or season holding it (`…/e/s01` holds
            // `…/e/s01e02`).
            guard key.hasPrefix(wanted.key) else { return false }
            let rest = key.dropFirst(wanted.key.count)
            return rest.isEmpty || rest.hasPrefix("/") || (wanted.key.contains("/e/s") && rest.hasPrefix("e"))
        } ?? false
    }

    /// How many of a series' next episodes this Mac keeps (0: none).
    func nextEpisodes(_ title: String) -> Int { downloads?.next.first { $0.title == title }?.episodes ?? 0 }

    /// The tiles (movies, and seasons) with something downloaded, as of the
    /// last reload.
    private(set) var downloadedTiles: Set<String> = []

    /// The tiles with downloads watched since, and whether each is only
    /// waiting (every one held elsewhere) or needs a person (the only copy).
    private(set) var watchedTiles: [String: Bool] = [:]

    /// A download watched since, if this item is.
    func done(_ item: String) -> Downloads.Done? { downloads?.watched.first { $0.item == item } }

    func isKept(_ item: String) -> Bool { downloads?.kept.contains(item) ?? false }

    /// Keeps a download however it's watched, or lets it go once watched.
    func keep(_ item: String, _ on: Bool) { check { cq_keep($0, item, on ? 1 : 0) } }

    private static func tiles(of items: [String]) -> Set<String> {
        Set(items.compactMap { item in
            let parts = item.split(separator: "/", maxSplits: 4, omittingEmptySubsequences: false)
            guard parts.count >= 4 else { return nil }
            let title = parts[0..<4].joined(separator: "/")
            guard parts.count == 5, parts[4].hasPrefix("e/s"), let season = Int(parts[4].dropFirst(3).prefix { $0.isNumber }) else { return title }
            return "\(title)#\(season)"
        })
    }

    /// Bytes this Mac's downloads hold.
    var downloadedBytes: Int { downloads?.held.reduce(0) { $0 + $1.size } ?? 0 }

    /// Downloads a title, season (`<title>/e/s01`), or item, in the
    /// rendition given (else the one most items have).
    func download(_ key: String, rendition: String?) {
        check { cq_download($0, key, rendition) }
        reconcileSoon()
    }

    /// Deletes a title's, season's, or item's downloads, and stops wanting
    /// them.
    func removeDownload(_ key: String) { check { cq_download_remove($0, key) } }

    /// Keeps a series' next `episodes` downloaded (0: stops).
    func downloadNext(_ title: String, episodes: Int) {
        check { cq_download_next($0, title, Int32(episodes)) }
        reconcileSoon()
    }

    /// Changes where downloads go, or whether a kept series' watched
    /// episodes go at once.
    func setDownloads(dir: String? = nil, dropWatched: Bool? = nil) {
        if let dir, dir != downloadsDir {
            configureDownloads(dir: dir, dropWatched: dropWatched)
            // Served from the new folder; what's wanted is fetched there.
            if servingPort != nil { serve() }
        } else {
            configureDownloads(dir: dir, dropWatched: dropWatched)
        }
        reconcileSoon()
    }

    /// Tells the core where downloads are kept and served (on the port this
    /// Mac serves on, or last did); a source served at another address
    /// before (another port) is removed, its copies recorded afresh as
    /// reconciling finds the files.
    private func configureDownloads(dir: String? = nil, dropWatched: Bool? = nil) {
        guard hasLibrary else { return }
        let port = servingPort ?? UserDefaults.standard.integer(forKey: "servingPort")
        guard port > 0 else { return }
        let path = dir ?? downloadsDir
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let url = "http://\(Self.localHost):\(port)/\(Self.downloadsPrefix)/"
        if let id = downloads?.source, let old = sources.first(where: { $0.id == id }), old.url != url {
            removeSource(old.id)
        }
        let drop = dropWatched ?? downloads?.drop_watched ?? false
        check { cq_downloads_configure($0, path, url, drop ? 1 : 0) }
    }

    /// Playback sessions streaming (not playing a file), during which no
    /// download begins, so as not to slow them.
    private var streams: Set<ObjectIdentifier> = []

    /// Notes a playback session streaming, or not; when none is, what
    /// waited is fetched.
    func streaming(_ session: AnyObject, _ on: Bool) {
        let id = ObjectIdentifier(session)
        let was = !streams.isEmpty
        if on { streams.insert(id) } else { streams.remove(id) }
        guard let handle, was != !streams.isEmpty else { return }
        cq_downloads_hold(handle.pointer, streams.isEmpty ? 0 : 1)
        if streams.isEmpty { reconcileSoon() }
    }

    /// Fetches and deletes downloads to match what's kept, off the main
    /// thread, showing how far it's come; if it's running, it runs again.
    func reconcileSoon() {
        guard let handle, hasLibrary, downloads?.dir != nil else { return }
        guard reconciling == nil else {
            Task.detached { if let text = cq_reconcile(handle.pointer) { cq_free(text) } }
            return
        }
        reconciling = Task {
            // Cancelled once reconciling ends, so it holds self no longer.
            let watcher = Task {
                var seen = cq_data_version(handle.pointer)
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    let now = cq_data_version(handle.pointer)
                    if now != seen {
                        seen = now
                        self.reload()
                    } else {
                        self.reloadDownloads()
                    }
                }
            }
            struct Result: Decodable {
                let failed: Int
                let no_room: Int
                let error: String?
            }
            let data: Data? = await Task.detached {
                guard let text = cq_reconcile(handle.pointer) else { return nil }
                defer { cq_free(text) }
                return Data(bytes: text, count: strlen(text))
            }.value
            watcher.cancel()
            reconciling = nil
            reload()
            let result = data.flatMap { try? JSONDecoder().decode(Result.self, from: $0) }
            if let result, result.no_room > 0 {
                let floor = (downloads?.floor ?? 0).formatted(.byteCount(style: .file))
                report(.download, "Not enough space to download \(result.no_room == 1 ? "one more file" : "\(result.no_room) more files"): Cinematheque keeps \(floor) free.")
            } else if let result, result.failed > 0, let error = result.error {
                report(.download, "Downloading failed: \(error.replacing(/([a-z])([A-Z])/) { "\($0.1) \($0.2)" }.lowercased()).")
            } else {
                report(.download, data == nil ? "Downloading failed: \(String(cString: cq_error()))." : nil)
            }
        }
    }
    #endif

    // Keeping in sync while running, and saying so.

    /// An exchange with peers: how many operations, with whom, and when.
    struct Exchange: Equatable {
        let count: Int
        let peer: String
        let at: Date
    }

    /// What last came in from peers, and what last went out to one.
    private(set) var received: Exchange?
    private(set) var sent: Exchange?
    private var syncingQuietly = false

    /// One line telling of the last exchange each way, for diagnosis:
    /// "Received 3 changes from firefly 1m ago · Sent 12 changes to Den
    /// just now", counting operations (a field's write each).
    var syncLine: String {
        let when = RelativeDateTimeFormatter()
        when.unitsStyle = .abbreviated
        func ago(_ date: Date) -> String { Date.now.timeIntervalSince(date) < 5 ? "just now" : when.localizedString(for: date, relativeTo: .now) }
        var parts: [String] = []
        func changes(_ n: Int) -> String { n == 1 ? "1 change" : "\(n.formatted()) changes" }
        if let r = received { parts.append((r.count == 0 ? "Nothing new from \(r.peer)" : "Received \(changes(r.count)) from \(r.peer)") + " " + ago(r.at)) }
        if let s = sent { parts.append((s.count == 0 ? "Nothing new to \(s.peer)" : "Sent \(changes(s.count)) to \(s.peer)") + " " + ago(s.at)) }
        return parts.joined(separator: " · ")
    }

    /// When this device last synced, from which the next quiet sync waits
    /// a minute.
    private var lastSync = Date.distantPast
    /// Syncing after a change, once changes stop for a moment.
    private var afterChange: Task<Void, Never>?

    /// While the app runs: syncs quietly a minute after it last synced (as
    /// when it comes to the front), so what other devices change
    /// (playheads, the watchlist) arrives without a refresh; reloads at
    /// once when a peer pushes its changes here; and notes each sync served
    /// to a peer.
    func keepInSync() async {
        var tick = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            tick += 1
            notePushed()
            if tick % 5 == 0 {
                noteServed()
                checkFolders()
            }
            if Date.now.timeIntervalSince(lastSync) >= 60 { await syncQuietly() }
        }
    }

    /// After a change of this user's (leaving playback, the watchlist, a
    /// watched mark), once changes stop for a second: syncs, which pushes
    /// it to every peer, rather than waiting a minute.
    func changed() {
        afterChange?.cancel()
        afterChange = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await syncQuietly()
        }
    }

    /// Syncs with every peer, without showing it as an activity, unless
    /// something else is running; returns whether it did.
    @discardableResult
    func syncQuietly() async -> Bool {
        guard let handle, hasLibrary, activity == nil, !syncingQuietly else { return false }
        syncingQuietly = true
        defer { syncingQuietly = false }
        lastSync = .now
        let data: Data? = await Task.detached {
            guard let text = cq_sync(handle.pointer, nil) else { return nil }
            defer { cq_free(text) }
            return Data(bytes: text, count: strlen(text))
        }.value
        if let data { noteReceived(data) }
        reload()
        // What's watched, here or elsewhere, moves kept series along.
        #if os(macOS)
        reconcileSoon()
        #endif
        return true
    }

    private func noteReceived(_ data: Data) {
        struct Result: Decodable {
            let url: String
            let name: String?
            let new: Int
            let sent: Int?
            let error: String?

            var peer: String {
                let host = URL(string: url)?.host().map { $0.hasSuffix(".local") ? String($0.dropLast(6)) : $0 }
                return name ?? host ?? url
            }
        }
        lastSync = .now
        guard let results = try? JSONDecoder().decode([Result].self, from: data) else { return }
        if let peer = results.first(where: { $0.error == "Removed" }) {
            leave(removedBy: peer.peer)
            return
        }
        let reached = results.filter { $0.error == nil }
        guard let most = reached.max(by: { $0.new < $1.new }) else { return }
        received = Exchange(count: reached.reduce(0) { $0 + $1.new }, peer: most.peer, at: .now)
        // What this device pushed, to the peer it sent most to.
        if let pushed = reached.max(by: { ($0.sent ?? 0) < ($1.sent ?? 0) }), let count = pushed.sent, count > 0 {
            sent = Exchange(count: reached.reduce(0) { $0 + ($1.sent ?? 0) }, peer: pushed.peer, at: .now)
        }
    }

    /// When a peer has pushed its changes here: reloads, and notes it.
    private func notePushed() {
        guard hasLibrary, let pushed = decode(Heard?.self, { cq_received($0) }) ?? nil else { return }
        let at = Date(timeIntervalSince1970: pushed.at / 1000)
        guard lastPush != at else { return }
        lastPush = at
        received = Exchange(count: pushed.operations, peer: pushed.name ?? String(pushed.device.prefix(8)), at: at)
        reload()
    }

    /// When a peer last pushed here, as `notePushed` last saw it.
    private var lastPush: Date?

    /// An exchange the server had with a peer (`cq_served`, `cq_received`).
    private struct Heard: Decodable {
        let device: String
        let name: String?
        let operations: Int
        let at: Double
    }

    private func noteServed() {
        guard hasLibrary, let served = decode(Heard?.self, { cq_served($0) }) ?? nil else { return }
        let at = Date(timeIntervalSince1970: served.at / 1000)
        guard sent?.at != at else { return }
        sent = Exchange(count: served.operations, peer: served.name ?? String(served.device.prefix(8)), at: at)
    }

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
    /// Forgets where this user stopped in an item (its watched mark stays),
    /// so it plays from the beginning: Resume becomes Play.
    func clearPosition(_ item: String) {
        // A position in the first 10 seconds isn't kept (the core's rule).
        setPlayhead(item, position: 0, duration: 1)
        reload()
        changed()
    }

    func setPlayhead(_ item: String, position: Double, duration: Double) {
        guard position.isFinite, duration.isFinite, duration > 0 else { return }
        check(reload: false) { cq_set_playhead($0, item, UInt64(max(0, position) * 1000), UInt64(duration * 1000)) }
        revision += 1
    }

    /// Removes a tile from Played: this user's playheads in its items (a
    /// movie's, a season's, or with `wholeTitle`, every season's), positions
    /// and watched marks alike.
    func removeFromPlayed(_ tile: Tile, wholeTitle: Bool = false) {
        guard let detail = detail(tile.key) else { return }
        let items = wholeTitle ? detail.items : Playback.items(detail, season: tile.season)
        for item in items { check(reload: false) { cq_remove_playhead($0, "\(detail.key)/\(item.key)") } }
        revision += 1
        reload()
        changed()
    }

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

    // Calling the core.

    /// A long operation's failures in a sentence: the first, by its
    /// server's name and the error in words, and how many more there were.
    /// "Looking for new videos failed for art › Movies › 2160p (and 2 more): the server
    /// has nothing at that address." Each source by its name, if known
    /// (as Settings shows it, or a peer as it advertised itself), else its
    /// server.
    nonisolated static func describe(_ failed: [(url: String, name: String?, error: String)], _ what: String) -> String? {
        guard let first = failed.first else { return nil }
        let host = URL(string: first.url)?.host()?.replacing(/\.local$/, with: "") ?? first.url
        let others = failed.count - 1
        let more = others == 0 ? "" : " (and \(others) more)"
        return "\(what) failed for \(first.name ?? host)\(more): \(reason(first.error))."
    }

    /// The core's error, as a person reads it.
    nonisolated static func reason(_ error: String) -> String {
        switch error {
        case "NotFound": "the server has nothing at that address"
        case "AccessDenied": "the server refused access"
        case "ServerError": "the server had a problem"
        case "BadStatus": "the server answered unexpectedly"
        case "ConnectionRefused": "nothing answered there (is the server running?)"
        case "ConnectionTimedOut", "Timeout": "it didn't answer in time"
        case "UnknownHostName", "NameServerFailure", "TemporaryNameServerFailure": "no server by that name was found"
        case "NetworkUnreachable", "HostUnreachable": "it can't be reached from this network"
        case "NotAMember": "that device isn't part of this library"
        default:
            // "ConnectionResetByPeer" to "connection reset by peer".
            error.replacing(/([a-z])([A-Z])/) { "\($0.1) \($0.2)" }.lowercased()
        }
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
    private func long(_ what: String, results: ((Data) -> Void)? = nil, _ body: @escaping @Sendable (OpaquePointer) -> UnsafeMutablePointer<CChar>?) async -> String? {
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
        // Sources by the names Settings gives them.
        let names = Dictionary(sources.map { ($0.url, folder(of: $0).map { "\($0.name) on this Mac" } ?? $0.displayName) }, uniquingKeysWith: { a, _ in a })
        let (failure, data): (String?, Data?) = await Task.detached {
            guard let text = body(handle.pointer) else { return (String(cString: cq_error()), nil) }
            defer { cq_free(text) }
            let data = Data(bytes: text, count: strlen(text))
            let results = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
            let failed = results.compactMap { r in
                (r["error"] as? String).map { (url: r["url"] as? String ?? "", name: r["name"] as? String ?? names[r["url"] as? String ?? ""], error: $0) }
            }
            return (Library.describe(failed, what), data)
        }.value
        if let data { results?(data) }
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
