import CCinematheque
import Foundation
import Observation
import os
#if os(macOS)
import SystemConfiguration
#endif

@MainActor @Observable
final class Library {
    var handle: Handle?
    private(set) var status: Status?
    private(set) var tiles: [Tile] = []
    /// This person's lists, by name (`cq_lists`), then other members'
    /// shared ones; every title on any of this person's, which a tile's
    /// star marks; and every title on any list shown.
    var lists: [UserList] = []
    var listed: Set<String> = []
    var onAnyList: Set<String> = []
    /// This person's own lists, which they change.
    var myLists: [UserList] { lists.filter(\.isMine) }
    /// A list's name asked for (a new one's, or another for one), and a
    /// list to delete once confirmed, wherever it was asked from (a
    /// context menu's gone by the time it's answered).
    var listPrompt: ListPrompt?
    var deletingList: UserList?
    /// A list to share once confirmed, as other members' devices keep what
    /// they receive.
    var sharingList: UserList?
    private(set) var sources: [Source] = []
    private(set) var members: [Member] = []
    private(set) var devices: [Device] = []
    /// What last went wrong, shown modelessly (`ProblemBar`) until the
    /// next action of its kind succeeds or it's dismissed; never an alert.
    var problem: String?
    enum Kind { case refresh, change, read, serve, download }
    private var problemKind: Kind?
    var refreshedAtLaunch = false
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
    var revision = 0

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
    var dirty = true
    /// The core's data version when the library was last read.
    private var loadedVersion: Int64 = -2
    /// The tiles as the core gave them, before sorting.
    private var unsortedTiles: [Tile] = []
    /// Counts reloads, so one read off the main thread (`reloadApart`)
    /// that another overtook is dropped.
    private var reloads = 0
    /// Reads under way off the main thread, each holding a connection,
    /// which leaving waits out (the core refuses to leave while one's open).
    private var readingApart = 0

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
        // Another connection's commit (a crawl's describing, a sync) may
        // change a title's details without changing its tile.
        let changed = dirty || version != loadedVersion
        dirty = false
        loadedVersion = version
        reloads += 1
        let read = decode([Tile].self) { cq_tiles($0) } ?? []
        apply(read, sorted: read == unsortedTiles ? nil : Self.sorted(read), sources: decode([Source].self) { cq_repos($0) } ?? [], changed: changed)
    }

    /// Reloads as `reload` does, but reads the tiles and sources, and
    /// decodes and sorts them, off the main thread, as a long operation's
    /// watcher does each second it commits: they're the whole catalog, so
    /// on the main thread a crawl would stall the Apple TV's focus. A
    /// reload that overtakes it (as a change of this person's makes) wins.
    func reloadApart() async {
        guard hasLibrary, let handle else { return }
        let version = cq_data_version(handle.pointer)
        guard dirty || version < 0 || version != loadedVersion else { return }
        let pass = reloads
        readingApart += 1
        defer { readingApart -= 1 }
        let read: (tiles: [Tile], sorted: [Tile], sources: [Source])? = await Task.detached {
            guard let tiles = Self.read([Tile].self, handle, { cq_tiles($0) }),
                  let sources = Self.read([Source].self, handle, { cq_repos($0) })
            else { return nil }
            return (tiles, Self.sorted(tiles), sources)
        }.value
        // A failed read is left to the reload that ends the operation.
        guard let read, pass == reloads, hasLibrary else { return }
        dirty = false
        loadedVersion = version
        reloads += 1
        apply(read.tiles, sorted: read.tiles == unsortedTiles ? nil : read.sorted, sources: read.sources, changed: true)
    }

    /// The tiles by title, as the core orders them, then season.
    private nonisolated static func sorted(_ tiles: [Tile]) -> [Tile] {
        tiles.sorted { ($0.order.title, $0.season ?? 0) < ($1.order.title, $1.season ?? 0) }
    }

    /// A result of the core's, decoded, on any thread.
    private nonisolated static func read<T: Decodable>(_ type: T.Type, _ handle: Handle, _ body: (OpaquePointer) -> UnsafeMutablePointer<CChar>?) -> T? {
        guard let text = body(handle.pointer) else { return nil }
        defer { cq_free(text) }
        return try? JSONDecoder().decode(T.self, from: Data(bytes: text, count: strlen(text)))
    }

    /// Takes what a reload read, assigning only what differs, and reads the
    /// rest (small) here: `sorted` is nil if the tiles are as they were.
    private func apply(_ read: [Tile], sorted: [Tile]?, sources repos: [Source], changed: Bool) {
        var changed = changed
        if let sorted {
            changed = true
            unsortedTiles = read
            tiles = sorted
        }
        readLists()
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
        if changed { revision += 1 }
    }

    func detail(_ key: String) -> TitleDetail? {
        decode(TitleDetail.self) { cq_title($0, key) }
    }



    // Stored for Library+Sources.swift (folders on this device), as an
    // extension can't store any.
    /// This device's folders served as sources, for this library.
    var folders: [Folder] = []
    /// Folders not there when last looked (on a drive unplugged, or a share
    /// unmounted), by prefix: served all the same, listed empty while gone,
    /// so crawls find them unavailable, their titles dimmed, not failed.
    var unavailableFolders: Set<String> = []
    /// The key the folders were loaded under: another library's are others.
    var loadedFoldersKey: String?
    /// The port this device serves on, while it does.
    var servingPort: Int?

    // Stored for Library+Downloads.swift.
    #if os(macOS)
    var downloads: Downloads?
    var reconciling: Task<Void, Never>?
    /// Downloads to delete once confirmed, since they hold only copies.
    var deleting: String?
    /// The tiles (movies, and seasons) with something downloaded, as of the
    /// last reload.
    var downloadedTiles: Set<String> = []
    /// Playback sessions streaming (not playing a file), during which no
    /// download begins, so as not to slow them.
    var streams: Set<ObjectIdentifier> = []
    #endif

    // Stored for Library+Sync.swift.
    /// What last came in from devices, and what last went out to one.
    var received: Exchange?
    var sent: Exchange?
    var syncingQuietly = false
    /// Whether the app is at the front (its scene active); not observed, so
    /// setting it redraws nothing.
    @ObservationIgnored var active = true
    /// When this device last synced, from which the next quiet sync waits
    /// a minute.
    var lastSync = Date.distantPast
    /// Syncing after a change, once changes stop for a moment.
    var afterChange: Task<Void, Never>?
    /// Leaving the library, so no quiet sync starts.
    var leavingLibrary = false
    /// When a device last pushed here, as `notePushed` last saw it.
    var lastPush: Date?

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
        // writer), and reads off the main thread, starting none meanwhile.
        leavingLibrary = true
        defer { leavingLibrary = false }
        while activity != nil || syncingQuietly || readingApart > 0 {
            try? await Task.sleep(for: .milliseconds(250))
        }
        if !alone {
            let unreachable = "None of the library's other devices could be reached, so they wouldn't hear this one left. Try again while one is on."
            guard await Self.reachesAny(handle) else { return unreachable }
            // On the main thread, as it writes on the main connection
            // (which the core gives one thread), and it's quick.
            let removed: String? = cq_remove_self(handle.pointer, successor) == 0 ? nil : String(cString: cq_error())
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
        lists = []
        listed = []
        sources = []
        members = []
        devices = []
        #if os(macOS)
        reconciling?.cancel()
        reconciling = nil
        streams = []
        downloads = nil
        downloadedTiles = []
        Playback.downloads = nil
        #endif
        dirty = true
        reload()
        return true
    }

    /// Creates a library, founded by this person; joining one is by pairing.
    func found() { check { cq_found($0) } }

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
        case "Busy": "something else is using the library: try again in a moment"
        case "FoundersDevice": "only the founder can remove the founder's devices"
        case "Stale": "its clock and this one's are more than ten minutes apart"
        case "WrongRecipient": "another device answered at its address"
        case "Refused": "that device refused (is it up to date? Devices sync only with others as new)"
        case "PathTaken": "another file is already where it would go"
        case "BadAddress": "that isn't a web address (http or https)"
        case "TooMany": "the server lists far more than any library holds"
        case "TooDeep": "the server's folders nest too deeply"
        case "NotAMember": "that device isn't part of this library"
        case "NoLibrary": "this device has no library yet"
        case "ProcessFdQuotaExceeded", "SystemFdQuotaExceeded": "too many files are open"
        default:
            // "ConnectionResetByPeer" to "connection reset by peer".
            error.replacing(/([a-z])([A-Z])/) { "\($0.1) \($0.2)" }.lowercased()
        }
    }

    /// Shows a problem, or with none, clears one of the same kind.
    func report(_ kind: Kind, _ failure: String?) {
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
    func long(_ what: String, results: ((Data) -> Void)? = nil, _ body: @escaping @Sendable (OpaquePointer) -> UnsafeMutablePointer<CChar>?) async -> String? {
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
                    await self.reloadApart()
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

    func check(reload again: Bool = true, _ body: (OpaquePointer) -> Int32) {
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

    func decode<T: Decodable>(_ type: T.Type, _ body: (OpaquePointer) -> UnsafeMutablePointer<CChar>?) -> T? {
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
