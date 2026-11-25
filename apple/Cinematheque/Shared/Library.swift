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
        let phase: Phase?
        let done: Int
        let total: Int
    }

    /// The phase of a long operation, as the core names it.
    enum Phase: String, Codable { case crawling, describing, syncing }
    /// Counts changes, so views showing details can refresh.
    var revision = 0
    /// Counts items described from their files (an episode's title, say),
    /// apart from `revision`, so describing a season's episodes one at a
    /// time refreshes only views of details, not what follows progress and
    /// copies (a season's download sizes, worked out on the main thread).
    var described = 0
    /// What views of a title's details follow: changes and descriptions.
    var detailsRevision: [Int] { [revision, described] }

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
    /// Calls under way off the main thread, each on a connection of the
    /// core's own (`apart`), which leaving waits out (the core refuses to
    /// leave while one's open).
    private var callsApart = 0
    /// Changes the writer refused as busy (a sync's exchange or a crawl's
    /// source under way), in the order made, to make once it's free, as a
    /// change waits out what holds it rather than being lost.
    @ObservationIgnored private var waiting: [(OpaquePointer) -> Int32] = []

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

    /// Shows a movie's or season's (or with no season, a whole series')
    /// tiles marked as `watched` at once, as reading them back (off the main
    /// thread) takes a moment on a large library: every item watched, or
    /// none, and no position kept.
    func showWatched(_ key: String, season: Int?, _ watched: Bool) {
        for i in tiles.indices where tiles[i].key == key && (season == nil || tiles[i].season == season) {
            tiles[i].watched = watched
            tiles[i].progress = watched ? 1 : 0
            tiles[i].elapsed = watched ? tiles[i].runtime : 0
            tiles[i].started = false
        }
    }

    /// Reloads off the main thread (`reloadApart`), after a change of this
    /// person's or one a sync brought: the whole catalog read on the main
    /// thread held the window a second on a large library.
    func reloadSoon() {
        Task { await reloadApart() }
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
        // The latest read started wins; a change from here on marks the
        // library again, for a read after this one.
        reloads += 1
        let pass = reloads
        dirty = false
        callsApart += 1
        defer { callsApart -= 1 }
        let read: (tiles: [Tile], sorted: [Tile], sources: [Source])? = await Task.detached {
            guard let tiles = Self.read([Tile].self, handle, { cq_tiles($0) }),
                  let sources = Self.read([Source].self, handle, { cq_repos($0) })
            else { return nil }
            return (tiles, Self.sorted(tiles), sources)
        }.value
        // A failed read is left to the next reload.
        guard let read else {
            dirty = true
            return
        }
        guard pass == reloads, hasLibrary else { return }
        loadedVersion = version
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
    /// Whether folders are being looked at (`checkFolders`), and whether
    /// to look again once done, as a mount came meanwhile.
    var checkingFolders = false
    var checkFoldersAgain = false
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

    // Setting up.

    /// Why this device last left a library, for setup to say: removed, by a
    /// device (as a sync was told, signed), from its library.
    private(set) var removedBy: String?

    /// Leaves the library, as a device removed from it must: forgets it and
    /// this device's identity, so setup can pair it again as a new device.
    func leave(removedBy device: String) {
        // At once, so nothing more starts (the rest of a refresh), then
        // once what's under way is done.
        leavingLibrary = true
        Task {
            _ = await quietly {
                guard forget() else { return nil }
                removedBy = device
                return nil
            }
        }
    }

    /// Leaves the library of this person's own accord (Settings): removes
    /// this device from it, then syncs so other devices hear
    /// of it, and forgets it all, for setup to pair it anew. A device must
    /// hear of it before this one forgets, else they'd list it for good: so it syncs
    /// first, to know one can be reached, and if the sync after removing
    /// fails anyway, leaving again (the removal written once) tries again.
    /// Returns why it couldn't, if it couldn't.
    func leaveLibrary() async -> String? {
        guard let handle else { return nil }
        return await quietly {
            let unreachable = "None of the library's other devices could be reached, so they wouldn't hear this one left. Try again while one is on."
            guard await Self.reachesAny(handle) else { return unreachable }
            // On the main thread, as it writes on the main connection
            // (which the core gives one thread), and it's quick.
            let removed: String? = cq_remove_self(handle.pointer) == 0 ? nil : String(cString: cq_error())
            if let removed { return "Couldn't leave the library: \(Self.reason(removed))." }
            guard await Self.reachesAny(handle) else { return unreachable }
            return forgetLibrary()
        }
    }

    /// Leaves a library no one else is in, ending it: there's no one to
    /// tell, so this device only forgets it.
    func endLibrary() async -> String? {
        guard handle != nil else { return nil }
        return await quietly { forgetLibrary() }
    }

    /// Runs `body` once a refresh or quiet sync under way is done (it holds
    /// the writer), and every call off the main thread, starting none
    /// meanwhile; reconciling downloads is stopped, its file under way kept
    /// to resume.
    private func quietly(_ body: () async -> String?) async -> String? {
        afterChange?.cancel()
        leavingLibrary = true
        defer { leavingLibrary = false }
        if let handle { cq_reconcile_stop(handle.pointer) }
        while activity != nil || syncingQuietly || callsApart > 0 || reconcilingNow {
            try? await Task.sleep(for: .milliseconds(250))
        }
        return await body()
    }

    /// Whether downloads are reconciling (on the Mac, the only one that
    /// downloads).
    private var reconcilingNow: Bool {
        #if os(macOS)
        reconciling != nil
        #else
        false
        #endif
    }

    /// Runs `body` off the main thread, as the core's long operations must
    /// run, counted so leaving waits it out; none starts while leaving.
    /// Its error, if any, must be read within it (`cq_error` is the
    /// thread's own).
    func apart<T: Sendable>(_ body: @escaping @Sendable (OpaquePointer) -> T) async -> T? {
        guard let handle, !leavingLibrary else { return nil }
        callsApart += 1
        defer { callsApart -= 1 }
        return await Task.detached { body(handle.pointer) }.value
    }

    /// Changes the library by a long operation `body`, off the main thread,
    /// reporting why it couldn't, if it couldn't, then reloads.
    func changeApart(_ body: @escaping @Sendable (OpaquePointer) -> Int32) async {
        dirty = true
        guard let failure = await apart({ body($0) == 0 ? nil : String(cString: cq_error()) }) else { return }
        reportChange(failure)
        reloadSoon()
    }

    /// Forgets the library and this device's identity; why it couldn't, if
    /// it couldn't.
    private func forgetLibrary() -> String? {
        guard forget() else { return "Couldn't leave the library: \(Self.reason(String(cString: cq_error())))." }
        removedBy = nil
        return nil
    }

    /// Syncs with every device found or added, off the main thread; returns
    /// whether any was reached. Not `apart`, which refuses while leaving:
    /// it's leaving's own, which awaits it.
    private nonisolated static func reachesAny(_ handle: Handle) async -> Bool {
        await Task.detached {
            guard let text = cq_sync(handle.pointer) else { return false }
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
    func found() { checkAndReload { cq_found($0) } }

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

    /// Errors that say only that a device couldn't be reached: a phone
    /// whose app is suspended or closed, a computer asleep. Syncing leaves
    /// them unsaid, as a device away is no problem; it's synced with when
    /// it's back.
    static let unreachable: Set<String> = ["ConnectionRefused", "ConnectionTimedOut", "Timeout", "HostUnreachable", "NetworkUnreachable", "UnknownHostName", "ConnectionResetByPeer"]

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
    func long(_ what: String, results: ((Data) -> Void)? = nil, unreported: Set<String> = [], _ body: @escaping @Sendable (OpaquePointer) -> UnsafeMutablePointer<CChar>?) async -> String? {
        guard let handle, activity == nil, !leavingLibrary else { return nil }
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
            }.filter { !unreported.contains($0.error) }
            return (Library.describe(failed, what), data)
        }.value
        if let data { results?(data) }
        activity = nil
        reload()
        return failure
    }

    /// Changes the library by `body`, reporting why it couldn't, if it
    /// couldn't; or, if a long operation holds the writer, once it lets
    /// go, after any change already waiting.
    func check(_ body: @escaping (OpaquePointer) -> Int32) {
        guard let handle else { return }
        dirty = true
        guard waiting.isEmpty else { return waiting.append(body) }
        let failure = body(handle.pointer) == 0 ? nil : String(cString: cq_error())
        guard failure != "Busy" else {
            waiting.append(body)
            Task { await makeWaiting() }
            return
        }
        reportChange(failure)
    }

    /// Makes the changes waiting, in order, as the writer frees, then reads
    /// the library back; drops them if the library's left meanwhile.
    private func makeWaiting() async {
        while !waiting.isEmpty {
            try? await Task.sleep(for: .milliseconds(200))
            guard let handle, !leavingLibrary else { return waiting.removeAll() }
            while let body = waiting.first {
                let failure = body(handle.pointer) == 0 ? nil : String(cString: cq_error())
                if failure == "Busy" { break }
                waiting.removeFirst()
                dirty = true
                reportChange(failure)
            }
        }
        reloadSoon()
        #if os(macOS)
        reloadDownloads()
        #endif
    }

    /// Reports why a change failed (the core's error), or with none,
    /// clears a change's problem.
    func reportChange(_ reason: String?) {
        guard let reason else { return report(.change, nil) }
        report(.change, reason == "Busy" ? "Couldn't change the library while \(activity?.lowercased() ?? "it's busy"); try again when it's done." : "Couldn't change the library: \(Self.reason(reason)).")
    }

    /// As `check`, then reloads what changed, off the main thread.
    func checkAndReload(_ body: @escaping (OpaquePointer) -> Int32) {
        check(body)
        reloadSoon()
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

/// Calls `body` with `strings` as a C array of C strings and its count,
/// each copied for the call and freed after it.
nonisolated func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>?, Int) -> R) -> R {
    let copies = strings.map { UnsafePointer(strdup($0)) }
    defer { for c in copies { free(UnsafeMutablePointer(mutating: c)) } }
    return copies.withUnsafeBufferPointer { body($0.baseAddress, $0.count) }
}
