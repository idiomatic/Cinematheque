import CCinematheque
import Foundation
import Observation
import os
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
    /// This person's: every item watched; how far along (0 to 1), by running
    /// time: how many milliseconds have `elapsed` (watched items whole,
    /// those partway to their positions) of the `runtime`; and whether any
    /// item has progress.
    let watched: Bool
    let progress: Double
    let elapsed: Int
    let runtime: Int
    let started: Bool
    /// How many items it holds: a season's episodes (an episode's versions
    /// and parts counting once), a movie's versions and parts.
    let items: Int
    /// Every copy it has is on a drive that isn't there (an unavailable
    /// directory of its source's): shown dimmed.
    var unavailable = false

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
        var unavailable = false
    }

    struct Quality: Codable, Hashable {
        let label: String
        let name: String
        let copies: [Copy]
    }

    struct Item: Codable, Hashable, Identifiable {
        let key: String
        /// An episode's `title`, `description`, and `duration`.
        let fields: [String: String]
        let qualities: [Quality]
        /// This person's progress, in milliseconds.
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
    struct Unavailable: Codable, Hashable {
        let dir: String
        let since: Double

        var name: String { dir.isEmpty ? "All of it" : dir }
        var date: Date { Date(timeIntervalSince1970: since / 1000) }
    }

    let id: String
    let url: String
    let quality: String
    let skip: String
    let copies: Int
    var unavailable: [Unavailable] = []
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

/// One of this person's devices that has a name.
struct Device: Codable, Identifiable, Hashable {
    let key: String
    let name: String
    let you: Bool
    var id: String { key }
}

/// A device found nearby, or added by address.
struct NearbyDevice: Codable, Identifiable, Hashable {
    let url: String
    let device: String?
    /// Its host, as DNS-SD resolved it (`Not-Your-AppleTV.local.`).
    let host: String?
    let person: String?
    /// Its person's key.
    let person_key: String?
    /// Of this library.
    let ours: Bool
    /// Its person is a member.
    let member: Bool
    let added: Bool
    /// For a new device offering to pair (`url` is where to pair it), what
    /// for: `pair`, to be another of this person's, or `join`, a new member's.
    let pairing: String?
    var id: String { url }
    var pairingAsYours: Bool { pairing == "pair" }
    var joining: Bool { pairing == "join" }
    /// Its device's and person's names, if they advertise any. tvOS tells
    /// apps only a generic name ("Apple TV") without an entitlement Apple
    /// grants, but its host is named for the Apple TV, so that stands in.
    var deviceName: String? {
        let advertised = device.flatMap { $0.isEmpty ? nil : $0 }
        guard advertised == nil || Self.generic.contains(advertised!), let named = hostName else { return advertised }
        return named
    }
    var personName: String? { person.flatMap { $0.isEmpty ? nil : $0 } }

    /// The names devices give apps in place of their own.
    private static let generic: Set<String> = ["Apple TV", "iPhone", "iPad"]

    /// Its host's name as a person wrote it, near enough
    /// (`Not-Your-AppleTV.local.` to "Not Your AppleTV"), unless that's
    /// generic too.
    private var hostName: String? {
        guard let host else { return nil }
        var label = host.hasSuffix(".") ? String(host.dropLast()) : host
        if label.hasSuffix(".local") { label = String(label.dropLast(6)) }
        let name = label.replacing("-", with: " ")
        return name.isEmpty || Self.generic.contains(name) ? nil : name
    }
}

/// A device just paired: its person's key and its own.
nonisolated struct Paired: Decodable {
    let person: String
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

struct Status: Codable, Equatable {
    let person: String
    /// Acting as the person of another of the person's devices.
    let paired: Bool
    let library: String?
    let founder: String?
    let members: Int
    /// How many other devices this person has, named or not.
    let others: Int
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
    /// How far it has come, in steps, from the core, while one runs.
    private(set) var steps: Steps?

    struct Steps: Codable, Equatable {
        /// `crawling`, `describing`, or `syncing`.
        let phase: String?
        let done: Int
        let total: Int
    }
    /// Counts changes, so views showing details can refresh.
    private(set) var revision = 0

    var hasLibrary: Bool { status?.library != nil }
    var paired: Bool { status?.paired ?? false }

    /// Opens this device's data directory: `dataDir`, else
    /// `CINEMATHEQUE_DATA`, else the platform's default (see the core's
    /// `defaultDataDir`).
    init(dataDir: String? = nil) {
        guard let pointer = cq_open(dataDir) else {
            problem = "Couldn't open Cinematheque's data (\(String(cString: cq_error())))."
            return
        }
        handle = Handle(pointer: pointer)
        reload()
    }

    /// Whether this connection changed the library since it was last read
    /// (`cq_data_version` tells only of other connections' commits).
    private var dirty = true
    /// The core's data version when the library was last read.
    private var loadedVersion: Int64 = -2
    /// The tiles as the core gave them, before sorting.
    private var unsortedTiles: [Tile] = []

    /// Reads the library again, unless nothing has changed since it was
    /// last read; assigns only what differs, so views showing the rest
    /// aren't redrawn. On the main thread, since the core's main connection
    /// belongs to it.
    func reload() {
        let had = hasLibrary
        let now = decode(Status.self) { cq_status($0) }
        if now != status { status = now }
        // Problems were the library's, or setup's: a library gained or left
        // starts afresh.
        if hasLibrary != had, status != nil {
            problem = nil
            problemKind = nil
            dirty = true
        }
        guard hasLibrary, let handle else { return }
        let version = cq_data_version(handle.pointer)
        guard dirty || version < 0 || version != loadedVersion else { return }
        let wrote = dirty
        // Another connection's commit (a crawl's describing, a sync) may
        // change a title's details without changing its tile.
        let committed = version != loadedVersion
        dirty = false
        loadedVersion = version
        let read = decode([Tile].self) { cq_tiles($0) } ?? []
        var changed = false
        if read != unsortedTiles {
            changed = true
            unsortedTiles = read
            tiles = read.sorted {
                ($0.name.localizedStandardCompare($1.name), $0.year ?? 0, $0.season ?? 0) < (.orderedSame, $1.year ?? 0, $1.season ?? 0)
            }
        }
        let list = Set(decode([String].self) { cq_watchlist($0) } ?? [])
        if list != watchlist { watchlist = list }
        let repos = decode([Source].self) { cq_repos($0) } ?? []
        if repos != sources { sources = repos }
        let people = decode([Member].self) { cq_members($0) } ?? []
        if people != members { members = people }
        let own = decode([Device].self) { cq_devices($0) } ?? []
        if own != devices { devices = own }
        #if os(macOS)
        reloadDownloads()
        #endif
        // Views of a title's details (which reread them with it) wait for a
        // change in the data, not each reload: a crawl or sync reloads at
        // most every second, and one that changed nothing doesn't.
        if changed || wrote || committed { revision += 1 }
    }

    func detail(_ key: String) -> TitleDetail? {
        decode(TitleDetail.self) { cq_title($0, key) }
    }


    // Setting up.

    /// Why this device last left a library, for setup to say: removed, by a
    /// device (as a sync was told, signed), from its library.
    private(set) var removedBy: String?

    /// Leaves the library, as a device removed from it must: forgets it and
    /// this device's identity, so setup can pair it again as a new device.
    func leave(removedBy device: String) {
        guard forget() else { return }
        removedBy = device
    }

    /// Leaves the library of this person's own accord (the Apple TV's
    /// Settings): removes this device from it, handing the library over to
    /// `successor` first if this is the founder's only device, then syncs so
    /// other devices hear of it, and forgets it all, for setup to pair it
    /// anew. Unless no one else is in the library, a device must hear of it
    /// before this one forgets, else they'd list it for good: so it syncs
    /// first, to know one can be reached, and if the sync after removing
    /// fails anyway, leaving again (the removal written once) tries again.
    /// Returns why it couldn't, if it couldn't.
    func leaveLibrary(successor: String?, alone: Bool) async -> String? {
        guard let handle else { return nil }
        afterChange?.cancel()
        // Once a refresh or quiet sync under way is done (it holds the
        // writer), starting none meanwhile.
        leavingLibrary = true
        defer { leavingLibrary = false }
        while activity != nil || syncingQuietly {
            try? await Task.sleep(for: .milliseconds(250))
        }
        if !alone {
            let unreachable = "None of the library's other devices could be reached, so they wouldn't hear this one left. Try again while one is on."
            guard await Self.reachesAny(handle) else { return unreachable }
            let removed: String? = await Task.detached {
                cq_remove_self(handle.pointer, successor) == 0 ? nil : String(cString: cq_error())
            }.value
            if let removed { return "Couldn't leave the library: \(Self.reason(removed))." }
            guard await Self.reachesAny(handle) else { return unreachable }
        }
        guard forget() else { return "Couldn't leave the library: \(Self.reason(String(cString: cq_error())))." }
        removedBy = nil
        return nil
    }

    /// Syncs with every device found or added, off the main thread; returns
    /// whether any was reached.
    private nonisolated static func reachesAny(_ handle: Handle) async -> Bool {
        await Task.detached {
            guard let text = cq_sync(handle.pointer, nil) else { return false }
            defer { cq_free(text) }
            struct Result: Decodable { let error: String? }
            let results = (try? JSONDecoder().decode([Result].self, from: Data(bytes: text, count: strlen(text)))) ?? []
            return results.contains { $0.error == nil }
        }.value
    }

    /// Forgets the library and this device's identity, and all that came of
    /// them; returns whether it could.
    private func forget() -> Bool {
        guard let handle, cq_leave(handle.pointer) == 0 else {
            report(.refresh, "Couldn't leave the library: \(Self.reason(String(cString: cq_error()))).")
            return false
        }
        Platform.forget()
        servingPort = nil
        refreshedAtLaunch = false
        problem = nil
        // Nothing of the old library stays: not what was read, served, or
        // downloaded, nor what's under way.
        afterChange?.cancel()
        afterChange = nil
        received = nil
        sent = nil
        lastPush = nil
        folders = []
        loadedFoldersKey = nil
        unavailableFolders = []
        tiles = []
        unsortedTiles = []
        watchlist = []
        sources = []
        members = []
        devices = []
        #if os(macOS)
        reconciling?.cancel()
        reconciling = nil
        streams = []
        downloads = nil
        downloadedTiles = []
        watchedTiles = [:]
        Playback.downloads = nil
        #endif
        dirty = true
        reload()
        return true
    }

    /// Creates a library, founded by this person; joining one is by pairing.
    func found() { check { cq_found($0) } }

    // Pairing a new device, by a code it shows, with a member's: to be
    // another of that person's devices, or a new member's.

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

    /// The offer's state; once paired, this device has its person and library.
    func checkPairing() -> Pairing? {
        guard !hasLibrary else { return nil }
        let state = decode(Pairing.self) { cq_pair_check($0) }
        if state?.paired == true {
            dirty = true
            reload()
        }
        return state
    }

    func stopPairing() {
        if let handle { cq_pair_stop(handle.pointer) }
    }

    /// Pairs the new device `device`, given the code it shows: sends it the
    /// library, and to pair it, this person's secret. Returns who it is
    /// (for `welcome`), or what went wrong, in words.
    func pair(_ device: NearbyDevice, code: String) async -> (Paired?, String?) {
        guard let handle else { return (nil, "The library isn't open.") }
        let url = device.url
        let join: Int32 = device.joining ? 1 : 0
        let name = device.deviceName ?? "The device"
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

    /// Renames another of this person's devices (or this one), for every
    /// device: as when its platform won't tell it its own name.
    func renameDevice(_ key: String, _ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let person = status?.person else { return }
        check { cq_name($0, key, person, trimmed) }
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

    /// Forgets a source's unavailable directory, as if it were deleted: its
    /// copies go, for every device.
    func removeUnavailable(_ source: String, _ dir: String) { check { cq_remove_unavailable($0, source, dir) } }

    /// Removes another of this person's devices from the library: its later
    /// writes are refused, and it's served no more.
    func removeDevice(_ key: String) { check { cq_remove_device($0, key) } }

    /// Takes in a device just paired: names it as it advertised itself, or
    /// as its host is named if that's generic (until it names itself), so
    /// it's among its person's devices at once, and if it's joining, adds
    /// its person as a member.
    func welcome(_ paired: Paired, from device: NearbyDevice) {
        if let name = device.deviceName {
            check(reload: false) { cq_name($0, paired.device, paired.person, name) }
        }
        if device.joining { check(reload: false) { cq_member($0, paired.person, 1) } }
        reload()
    }

    // Managing.

    func addSource(_ url: String, quality: String?, skip: String?) {
        check { cq_repo_add($0, url, quality, skip) }
    }

    func setSource(_ id: String, quality: String?, skip: String?) {
        check { cq_repo_set($0, id, quality, skip) }
    }

    func removeSource(_ id: String) { check { cq_repo_remove($0, id) } }

    func setMember(_ key: String, _ add: Bool) { check { cq_member($0, key, add ? 1 : 0) } }

    /// Once a launch, if there's a library: serves it, syncs, names this
    /// device and person if they have no names yet (e.g., the computer's name
    /// and the account's first name), then crawls (devices may bring its
    /// sources to a device that has none yet).
    func startAtLaunch(device: String, person: String? = nil) async {
        guard !refreshedAtLaunch, hasLibrary else { return }
        refreshedAtLaunch = true
        if sharing { serve() }
        // Syncing before writing anything: a device whose replica was lost
        // (as tvOS may purge one) learns its own writes back, and so where
        // its numbering left off, before it writes again.
        let synced = await long("Catching up", results: noteReceived) { cq_sync($0, nil) }
        // Told while catching up that it was removed, it left: nothing more
        // to refresh, and no library to look for videos for.
        guard hasLibrary else { return }
        var named = false
        if !devices.contains(where: \.you), !device.isEmpty { setName(.device, device); named = true }
        if let person, !person.isEmpty, members.first(where: \.you)?.name == nil { setName(.person, person); named = true }
        // Naming itself is a new device's first write, with its certificate:
        // its devices hear of it now, not a minute on.
        if named { changed() }
        let crawled = await crawlSources()
        report(.refresh, synced ?? crawled)
        // The sources' servers' names, looked up now, so the first play's
        // copy racing finds them answered.
        if let handle, let json = try? JSONEncoder().encode(sources.map(\.url)) {
            let text = String(decoding: json, as: UTF8.self)
            Task.detached { cq_race_warm(handle.pointer, text) }
        }
        #if os(macOS)
        reconcileSoon()
        #endif
    }

    // Names and devices.

    enum Named: String { case person, device }

    /// Names this person or this device, for every device to show in place of
    /// keys, and advertises the new name.
    func setName(_ which: Named, _ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        check { cq_set_name($0, which.rawValue, trimmed) }
        if servingPort != nil { serve() }
    }

    /// Devices found nearby (listening for 2 seconds) and added by address.
    func nearby() async -> [NearbyDevice] {
        guard let handle else { return [] }
        let data: Data? = await Task.detached {
            guard let text = cq_nearby(handle.pointer) else { return nil }
            defer { cq_free(text) }
            return Data(bytes: text, count: strlen(text))
        }.value
        return data.flatMap { try? JSONDecoder().decode([NearbyDevice].self, from: $0) } ?? []
    }

    /// Adds a device by address (e.g., one off the network), or removes one.
    func setDeviceAddress(_ url: String, _ add: Bool) { check(reload: false) { cq_device_address($0, url, add ? 1 : 0) } }

    // Folders on this device.

    /// The path a Mac's downloads are served at, beside its folders'.
    static let downloadsPrefix = "downloads"

    /// This device's folders served as sources, for this library.
    private(set) var folders: [Folder] = []
    /// Folders not there when last looked (on a drive unplugged, or a share
    /// unmounted), by prefix: served all the same, listed empty while gone,
    /// so crawls find them unavailable, their titles dimmed, not failed.
    private(set) var unavailableFolders: Set<String> = []

    /// Folders that aren't there now.
    private var foldersNotThere: Set<String> { Self.missing(folders) }

    nonisolated private static func missing(_ folders: [Folder]) -> Set<String> {
        Set(folders.filter { folder in
            var directory: ObjCBool = false
            return !FileManager.default.fileExists(atPath: folder.path, isDirectory: &directory) || !directory.boolValue
        }.map(\.prefix))
    }

    /// Notes folders that have come back, or gone, for Settings to show.
    private func checkFolders() {
        // Off the main actor: a share that's hung can hold a stat for its timeout.
        let folders = folders
        Task {
            let now = await Task.detached { Self.missing(folders) }.value
            if now != unavailableFolders { unavailableFolders = now }
        }
    }

    private var foldersKey: String { "folders-" + (status?.library ?? "") }

    /// The key the folders were loaded under: another library's are others.
    private var loadedFoldersKey: String?

    private func loadFolders() {
        guard loadedFoldersKey != foldersKey else { return }
        loadedFoldersKey = foldersKey
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
        loadFolders()
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
        addSource(folders[folders.count - 1].url, quality: nil, skip: ",")
        await crawl()
    }

    /// Stops serving a folder, and removes its source.
    func removeFolder(_ folder: Folder) {
        loadFolders()
        if let source = sources.first(where: { $0.url == folder.url }) { removeSource(source.id) }
        folders.removeAll { $0.prefix == folder.prefix }
        saveFolders()
        serve()
    }

    /// The port this device serves on, while it does.
    private(set) var servingPort: Int?

    /// Serves this library to devices (their syncs, so this device's changes,
    /// such as progress, reach them), and this device's folders, while the
    /// app runs, on the port it served on last, so folders' addresses stay
    /// put.
    func serve() {
        guard let handle, hasLibrary else { return }
        loadFolders()
        let defaults = UserDefaults.standard
        unavailableFolders = foldersNotThere
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
            report(.serve, "Couldn't share the library with your other devices: \(Self.reason(String(cString: cq_error()))).")
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
            addSource(moved, quality: old?.quality.isEmpty == false ? old?.quality : nil, skip: old?.skip ?? ",")
            if let old { removeSource(old.id) }
            folders[i].url = moved
        }
        saveFolders()
    }

    /// Syncs with devices found or added, then crawls every source: what
    /// devices have crawled and described arrives first, so crawling then
    /// finds little to do.
    func refresh() async {
        let synced = await long("Catching up", results: noteReceived) { cq_sync($0, nil) }
        let crawled = await crawlSources()
        report(.refresh, synced ?? crawled)
        #if os(macOS)
        reconcileSoon()
        #endif
    }

    func crawl() async { report(.refresh, await crawlSources()) }

    /// Crawls every source (`cq_crawl`), logging how long each took, and
    /// describing after, to tell where a slow crawl goes; returns why it
    /// failed, if it did.
    private func crawlSources() async -> String? {
        let clock = ContinuousClock()
        let start = clock.now
        return await long("Looking for new videos", results: { Self.logCrawl($0, took: clock.now - start) }) { cq_crawl($0) }
    }

    /// Crawling's steps and their times, in the system's log (Xcode's
    /// console, or `log stream`).
    static let crawlLog = Logger(subsystem: "com.rbrian.cinematheque", category: "crawl")

    private static func logCrawl(_ data: Data, took: Duration) {
        struct Crawled: Decodable {
            let url: String
            let files: Int
            let error: String?
            let crawl_ms: Int?
            let total_ms: Int?
            let requests: Int?
            let reused: Int?
            let changed: Int?
        }
        guard let sources = try? JSONDecoder().decode([Crawled].self, from: data) else { return }
        for s in sources {
            if let error = s.error {
                crawlLog.notice("Crawled \(s.url, privacy: .public): failed, \(error, privacy: .public)")
                continue
            }
            let total = Duration.milliseconds(s.total_ms ?? 0), listing = Duration.milliseconds(s.crawl_ms ?? 0)
            crawlLog.notice("Crawled \(s.url, privacy: .public) in \(total.logged, privacy: .public): listing \(listing.logged, privacy: .public) (\(s.requests ?? 0) read, \(s.reused ?? 0) reused), recording \((total - listing).logged, privacy: .public); \(s.files) files, \(s.changed ?? 0) copies changed")
        }
        let crawling = Duration.milliseconds(sources.reduce(0) { $0 + ($1.total_ms ?? 0) })
        crawlLog.notice("Looked for new videos in \(took.logged, privacy: .public): \(sources.count) sources in \(crawling.logged, privacy: .public), then describing (and the rest) \((took - crawling).logged, privacy: .public)")
    }

    func sync(_ url: String? = nil) async { report(.refresh, await long("Catching up", results: noteReceived) { cq_sync($0, url) }) }

    #if os(macOS)
    // Downloads, this Mac's (see the core's download.zig): kept in a folder
    // served as a source of its own, which no one crawls.

    struct Downloads: Decodable, Equatable {
        struct Held: Decodable, Equatable {
            let item: String
            let size: Int
            /// No other source holds it alike.
            let only: Bool
        }

        struct Wanted: Decodable, Equatable {
            let key: String
            let quality: String
        }

        /// A series' choice of episodes to download as it's watched, as
        /// `cq_download_next` takes it: a count, `unwatched`, a season's
        /// (`s02`), or `all`.
        struct Next: Decodable, Equatable {
            let title: String
            let choice: String
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
        /// The episodes (full item keys) the series' choices come to now.
        let ahead: [String]
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
        downloads?.wanted.contains { Self.holds(wanted: $0.key, key) } ?? false
    }

    /// Whether an item is asked for: wanted, itself or by its season or
    /// title, or one of the episodes its series' choice comes to.
    func isRequested(_ item: String) -> Bool {
        isWanted(item) || (downloads?.ahead.contains(item) ?? false)
    }

    /// Whether a key is an item's, or a title's or season's holding it
    /// (`…/e/s01` holds `…/e/s01e02`).
    private static func holds(wanted: String, _ key: String) -> Bool {
        guard key.hasPrefix(wanted) else { return false }
        let rest = key.dropFirst(wanted.count)
        return rest.isEmpty || rest.hasPrefix("/") || (wanted.contains("/e/s") && rest.hasPrefix("e"))
    }

    /// How many of a title's, season's, or item's downloads are the only
    /// copies.
    func onlyCopies(_ key: String) -> Int {
        downloads?.held.filter { $0.only && Self.holds(wanted: key, $0.item) }.count ?? 0
    }

    /// Downloads to delete once confirmed, since they hold only copies.
    var deleting: String?

    /// Deletes downloads, asking first (`deleting`) if any is the only
    /// copy: once deleted, it's gone from the library for everyone. If its
    /// series' choice asks for any of them, the choice becomes Nothing, so
    /// they aren't fetched again.
    func deleteDownload(_ key: String) {
        if onlyCopies(key) > 0 { deleting = key } else { removeDownload(key) }
    }

    /// Which of a series' episodes this Mac downloads as it's watched (see
    /// `Downloads.Next`); empty, none.
    func downloadChoice(_ title: String) -> String { downloads?.next.first { $0.title == title }?.choice ?? "" }

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
    /// quality given (else the one most items have).
    func download(_ key: String, quality: String?) {
        check { cq_download($0, key, quality) }
        reconcileSoon()
    }

    /// Deletes a title's, season's, or item's downloads, and stops wanting
    /// them.
    func removeDownload(_ key: String) {
        // The series' choice, if it asks for any of them, stopped first.
        let title = key.split(separator: "/", maxSplits: 4, omittingEmptySubsequences: false).prefix(4).joined(separator: "/")
        if !downloadChoice(title).isEmpty, downloads?.ahead.contains(where: { Self.holds(wanted: key, $0) }) ?? false {
            check { cq_download_next($0, title, "") }
        }
        check { cq_download_remove($0, key) }
    }

    /// What downloading would come to: all its files' `size`, and what of
    /// it isn't here yet (`needed`), in bytes.
    struct DownloadSize: Decodable, Equatable {
        let choice: String
        let size: Int
        let needed: Int
    }

    /// Per choice (a series' choice of episodes, `key` its title's, or
    /// empty for `key`'s own files in `quality`), what downloading would
    /// come to (`cq_download_sizes`).
    func downloadSizes(_ key: String, choices: [String], quality: String? = nil) -> [String: DownloadSize] {
        guard let json = try? JSONEncoder().encode(choices) else { return [:] }
        let text = String(decoding: json, as: UTF8.self)
        let sizes = decode([DownloadSize].self) { cq_download_sizes($0, key, text, quality) } ?? []
        return Dictionary(sizes.map { ($0.choice, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// The space downloads may take: what's free, less what they keep free.
    var spaceForDownloads: Int? {
        guard let d = downloads, let free = d.free else { return nil }
        return max(0, free - d.floor)
    }

    /// Chooses which of a series' episodes download as it's watched (see
    /// `Downloads.Next`); empty, none.
    func chooseDownloads(_ title: String, _ choice: String) {
        check { cq_download_next($0, title, choice) }
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
            // The core's error is the thread's own: read where it failed.
            let (data, failure): (Data?, String?) = await Task.detached {
                guard let text = cq_reconcile(handle.pointer) else { return (nil, String(cString: cq_error())) }
                defer { cq_free(text) }
                return (Data(bytes: text, count: strlen(text)), nil)
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
                report(.download, failure.map { "Downloading failed: \(Self.reason($0))." })
            }
        }
    }
    #endif

    // Keeping in sync while running, and saying so.

    /// An exchange with devices: how many operations, with whom, and when.
    struct Exchange: Equatable {
        let count: Int
        let device: String
        let at: Date
    }

    /// What last came in from devices, and what last went out to one.
    private(set) var received: Exchange?
    private(set) var sent: Exchange?
    private var syncingQuietly = false

    /// One line telling of the last exchange each way that changed
    /// something, for diagnosis: "Received 3 changes from firefly 1m ago ·
    /// Sent 12 changes to Den just now", counting operations (a field's
    /// write each). Exchanges with nothing new aren't told of.
    var syncLine: String {
        let when = RelativeDateTimeFormatter()
        when.unitsStyle = .abbreviated
        func ago(_ date: Date) -> String { Date.now.timeIntervalSince(date) < 5 ? "just now" : when.localizedString(for: date, relativeTo: .now) }
        var parts: [String] = []
        func changes(_ n: Int) -> String { n == 1 ? "1 change" : "\(n.formatted()) changes" }
        if let r = received { parts.append("Received \(changes(r.count)) from \(r.device) \(ago(r.at))") }
        if let s = sent { parts.append("Sent \(changes(s.count)) to \(s.device) \(ago(s.at))") }
        return parts.joined(separator: " · ")
    }

    /// Whether the app is at the front (its scene active); not observed, so
    /// setting it redraws nothing.
    @ObservationIgnored var active = true

    /// When this device last synced, from which the next quiet sync waits
    /// a minute.
    private var lastSync = Date.distantPast
    /// Syncing after a change, once changes stop for a moment.
    private var afterChange: Task<Void, Never>?
    /// Leaving the library, so no quiet sync starts.
    private var leavingLibrary = false

    /// While the app runs: syncs quietly a minute after it last synced (as
    /// when it comes to the front), so what other devices change
    /// (progress, the watchlist) arrives without a refresh; reloads at
    /// once when a device pushes its changes here; and notes each sync served
    /// to a device.
    func keepInSync() async {
        var tick = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            // Nothing redrawn while the app goes to the background, as the
            // system snapshots it; at the front again, it syncs at once.
            guard active else { continue }
            tick += 1
            notePushed()
            if tick % 5 == 0 {
                noteServed()
                checkFolders()
            }
            if Date.now.timeIntervalSince(lastSync) >= 60 { await syncQuietly() }
        }
    }

    /// After a change of this person's (leaving playback, the watchlist, a
    /// watched mark), once changes stop for a second: syncs, which pushes
    /// it to every device, rather than waiting a minute. If a sync or
    /// another long operation is running, it syncs once that's done, not
    /// never: a sync under way may have begun before the change.
    func changed() {
        afterChange?.cancel()
        afterChange = Task {
            try? await Task.sleep(for: .seconds(1))
            while !Task.isCancelled {
                // With the devices the last sync found, without looking
                // for two seconds again.
                if await syncQuietly(known: true) { return }
                guard handle != nil, hasLibrary else { return }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// Syncs with every device, without showing it as an activity, unless
    /// something else is running; returns whether it did. `known`, with
    /// those the last sync found (`cq_sync_known`), not looking again.
    @discardableResult
    func syncQuietly(known: Bool = false) async -> Bool {
        guard let handle, hasLibrary, activity == nil, !syncingQuietly, !leavingLibrary else { return false }
        syncingQuietly = true
        defer { syncingQuietly = false }
        lastSync = .now
        let data: Data? = await Task.detached {
            guard let text = known ? cq_sync_known(handle.pointer) : cq_sync(handle.pointer, nil) else { return nil }
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

            var device: String {
                let host = URL(string: url)?.host().map { $0.hasSuffix(".local") ? String($0.dropLast(6)) : $0 }
                return name ?? host ?? url
            }
        }
        lastSync = .now
        guard let results = try? JSONDecoder().decode([Result].self, from: data) else { return }
        if let device = results.first(where: { $0.error == "Removed" }) {
            leave(removedBy: device.device)
            return
        }
        let reached = results.filter { $0.error == nil }
        // Only exchanges that changed something are told of.
        if let most = reached.max(by: { $0.new < $1.new }), most.new > 0 {
            received = Exchange(count: reached.reduce(0) { $0 + $1.new }, device: most.device, at: .now)
        }
        // What this device pushed, to the other device it sent most to.
        if let pushed = reached.max(by: { ($0.sent ?? 0) < ($1.sent ?? 0) }), let count = pushed.sent, count > 0 {
            sent = Exchange(count: reached.reduce(0) { $0 + ($1.sent ?? 0) }, device: pushed.device, at: .now)
        }
    }

    /// When a device has pushed its changes here: reloads, and notes it.
    private func notePushed() {
        guard hasLibrary, let pushed = decode(Heard?.self, { cq_received($0) }) ?? nil else { return }
        let at = Date(timeIntervalSince1970: pushed.at / 1000)
        guard lastPush != at else { return }
        lastPush = at
        if pushed.operations > 0 {
            received = Exchange(count: pushed.operations, device: pushed.name ?? String(pushed.device.prefix(8)), at: at)
        }
        reload()
    }

    /// When a device last pushed here, as `notePushed` last saw it.
    private var lastPush: Date?

    /// An exchange the server had with a device (`cq_served`, `cq_received`).
    private struct Heard: Decodable {
        let device: String
        let name: String?
        let operations: Int
        let at: Double
    }

    private func noteServed() {
        guard hasLibrary, let served = decode(Heard?.self, { cq_served($0) }) ?? nil else { return }
        let at = Date(timeIntervalSince1970: served.at / 1000)
        guard sent?.at != at, served.operations > 0 else { return }
        sent = Exchange(count: served.operations, device: served.name ?? String(served.device.prefix(8)), at: at)
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

    // This person's.

    /// Records this person's progress in an item (a title's key and an
    /// item's, e.g., "t/m/alien/1979/v/-").
    /// Forgets where this person stopped in an item (its watched mark stays),
    /// so it plays from the beginning: Resume becomes Play.
    func clearPosition(_ item: String) {
        // A position in the first 10 seconds isn't kept (the core's rule).
        setProgress(item, position: 0, duration: 1)
        reload()
        changed()
    }

    func setProgress(_ item: String, position: Double, duration: Double) {
        guard position.isFinite, duration.isFinite, duration > 0 else { return }
        // Clamped (a position to a day, a duration to ten): a huge finite
        // value would trap in the conversion.
        let day = 86_400.0
        check(reload: false) { cq_set_progress($0, item, UInt64(min(max(0, position), day) * 1000), UInt64(min(duration, day * 10) * 1000)) }
        revision += 1
    }

    /// Removes a tile from Played: this person's progress in its items (a
    /// movie's, a season's, or with `wholeTitle`, every season's), positions
    /// and watched marks alike.
    func removeFromPlayed(_ tile: Tile, wholeTitle: Bool = false) {
        guard let detail = detail(tile.key) else { return }
        let items = wholeTitle ? detail.items : Playback.items(detail, season: tile.season)
        for item in items { check(reload: false) { cq_remove_progress($0, "\(detail.key)/\(item.key)") } }
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
    /// (as Settings shows it, or a device as it advertised itself), else its
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
        case "NoLibrary": "this device has no library yet"
        case "ProcessFdQuotaExceeded", "SystemFdQuotaExceeded": "too many files are open"
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
                let steps = self.decode(Steps.self) { cq_steps($0) }
                if steps != self.steps { self.steps = steps }
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
            steps = nil
        }
        // Sources by the names Settings gives them.
        let names = Dictionary(sources.map { ($0.url, folder(of: $0).map { "\($0.name) on this Mac" } ?? $0.displayName) }, uniquingKeysWith: { a, _ in a })
        let (failure, data): (String?, Data?) = await Task.detached {
            guard let text = body(handle.pointer) else { return ("\(what) failed: \(Library.reason(String(cString: cq_error()))).", nil) }
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
        dirty = true
        if body(handle.pointer) != 0 {
            let reason = String(cString: cq_error())
            report(.change, reason == "Busy" ? "Couldn't change the library while \(activity?.lowercased() ?? "it's busy"); try again when it's done." : "Couldn't change the library: \(Self.reason(reason)).")
        } else {
            report(.change, nil)
        }
        if again { reload() }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ body: (OpaquePointer) -> UnsafeMutablePointer<CChar>?) -> T? {
        guard let handle else { return nil }
        guard let text = body(handle.pointer) else {
            report(.read, "Couldn't read the library: \(Self.reason(String(cString: cq_error()))).")
            return nil
        }
        defer { cq_free(text) }
        // A read that works clears one that didn't.
        report(.read, nil)
        return try? JSONDecoder().decode(T.self, from: Data(bytes: text, count: strlen(text)))
    }

    isolated deinit {
        if let handle { cq_close(handle.pointer) }
    }
}

extension ComparisonResult: @retroactive Comparable {
    public static func < (a: ComparisonResult, b: ComparisonResult) -> Bool { a.rawValue < b.rawValue }
}
