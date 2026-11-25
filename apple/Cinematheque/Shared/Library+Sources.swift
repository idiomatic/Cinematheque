import CCinematheque
import Foundation
import os
#if os(macOS)
import AppKit
#endif

extension Library {
    // Managing.

    func addSource(_ url: String, skip: String?) {
        checkAndReload { cq_repo_add($0, url, skip) }
    }

    /// Sets the prefix of names a source skips, by ID or URL, none if
    /// empty; applied at its next crawl.
    func setSkip(_ source: String, _ skip: String) {
        checkAndReload { cq_repo_skip($0, source, skip) }
    }

    /// Sets where a source's files' quality comes from, by ID or URL;
    /// copies move at its next crawl. A newer device's setting is left as
    /// it is.
    func setQuality(_ source: String, _ quality: Source.Quality) {
        switch quality {
        case .path: checkAndReload { cq_repo_quality_from_path($0, source) }
        case .named(let name): checkAndReload { cq_repo_quality_named($0, source, name) }
        case .unknown: break
        }
    }

    private func removeSource(_ id: String) { checkAndReload { cq_repo_remove($0, id) } }

    /// Removes a member, for good: they come back only as someone new.
    func removeMember(_ key: String) { checkAndReload { cq_member_remove($0, key) } }

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
        let synced = await long("Catching up", results: noteReceived, unreported: Self.unreachable) { cq_sync($0) }
        // Told while catching up that it was removed, it left: nothing more
        // to refresh, and no library to look for videos for.
        guard hasLibrary else { return }
        var named = false
        // Never a generic name ("iPhone", as iOS tells apps), which would
        // outrank the host's that pairing named it by.
        if !devices.contains(where: \.you), let own = shownName(device) { setDeviceName(own); named = true }
        // Its model, for its person's other devices to show it by (the core
        // writes it only if it's changed).
        if devices.first(where: \.you)?.model == nil { named = true }
        check { cq_set_device_model($0, Platform.model) }
        if let person, !person.isEmpty, members.first(where: \.you)?.name == nil { setPersonName(person); named = true }
        // Naming itself is a new device's first write, with its certificate:
        // its devices hear of it now, not a minute on.
        if named { changed() }
        // Not asked for: sources another device crawled lately, whose
        // copies syncing brought, aren't crawled again.
        let crawled = await crawlSources { cq_crawl_due($0) }
        report(.refresh, synced ?? crawled)
        // The sources' servers' names, looked up now, so the first play's
        // copy racing finds them answered.
        let urls = sources.compactMap(\.address)
        Task { _ = await apart { handle in withCStrings(urls) { cq_race_warm(handle, $0, $1) } } }
        #if os(macOS)
        reconcileSoon()
        #endif
    }

    // Folders on this device.

    /// The path a Mac's downloads are served at, beside its folders'.
    static let downloadsPrefix = "downloads"


    /// Folders that aren't there now.
    private var foldersNotThere: Set<String> { Self.missing(folders) }

    nonisolated private static func missing(_ folders: [Folder]) -> Set<String> {
        Set(folders.filter { folder in
            var directory: ObjCBool = false
            return !FileManager.default.fileExists(atPath: folder.path, isDirectory: &directory) || !directory.boolValue
        }.map(\.prefix))
    }

    /// Notes folders that have come back, or gone, for Settings to show,
    /// and crawls each one's source at once: gone (a drive unplugged), its
    /// copies are marked unavailable (one field) for every device, so Play
    /// passes over them; back, the mark goes, and downloads waiting on it
    /// come.
    /// One look at a time: asked while looking, it looks again after.
    func checkFolders() {
        guard !checkingFolders else {
            checkFoldersAgain = true
            return
        }
        checkingFolders = true
        Task {
            defer { checkingFolders = false }
            repeat {
                checkFoldersAgain = false
                // Off the main actor: a share that's hung can hold a stat
                // for its timeout.
                let folders = folders
                let now = await Task.detached { Self.missing(folders) }.value
                guard now != unavailableFolders else { continue }
                let changed = now.symmetricDifference(unavailableFolders)
                unavailableFolders = now
                for folder in folders where changed.contains(folder.prefix) {
                    if let source = sources.first(where: { $0.url == folder.url }) { await crawlQuietly(source.id) }
                }
            } while checkFoldersAgain
        }
    }

    #if os(macOS)
    /// While the app runs, front or not: looks at its folders as a volume
    /// mounts or unmounts (a drive plugged in or out), as macOS says, and
    /// once a minute besides, for a share gone without unmounting (its
    /// server asleep).
    func watchFolders() async {
        let center = NSWorkspace.shared.notificationCenter
        let observers = [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkFolders() }
            }
        }
        defer { for o in observers { center.removeObserver(o) } }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            checkFolders()
        }
    }
    #endif

    /// Crawls one source, unshown (it's this Mac's own folder, come or
    /// gone), then reads back, and fetches what waited on it.
    private func crawlQuietly(_ source: String) async {
        guard hasLibrary else { return }
        await apart { if let text = cq_crawl_source($0, source) { cq_free(text) } }
        reloadSoon()
        #if os(macOS)
        reconcileSoon()
        #endif
    }

    private var foldersKey: String { "folders-" + (status?.library ?? "") }


    func loadFolders() {
        guard loadedFoldersKey != foldersKey else { return }
        loadedFoldersKey = foldersKey
        let data = UserDefaults.standard.data(forKey: foldersKey)
        folders = data.flatMap { try? JSONDecoder().decode([Folder].self, from: $0) } ?? []
    }

    private func saveFolders() {
        UserDefaults.standard.set(try? JSONEncoder().encode(folders), forKey: foldersKey)
    }

    /// An item's file in one of this device's folders (of any quality), as
    /// the last crawl found it. Whether it's worth downloading all the same
    /// (a share mounted from a NAS, or from this Mac) is a person's call.
    func folderFile(_ item: TitleDetail.Item) -> URL? {
        for copy in item.qualities.flatMap(\.copies) where !copy.unavailable {
            // A folder not there now (a share unmounted), though no crawl has
            // noticed yet, holds nothing to show.
            guard let source = sources.first(where: { $0.id == copy.source }), let folder = folder(of: source),
                  !unavailableFolders.contains(folder.prefix), let file = Self.file(of: copy, in: folder, at: source) else { continue }
            return file
        }
        return nil
    }

    /// A copy's file in this device's folder, as its source is reached (the
    /// copy's URL as served now).
    static func file(of copy: TitleDetail.Copy, in folder: Folder, at source: Source) -> URL? {
        guard let base = source.address, copy.url.hasPrefix(base),
              let path = String(copy.url.dropFirst(base.count)).removingPercentEncoding else { return nil }
        return URL(fileURLWithPath: folder.path).within(path)
    }

    /// This device's own folder's address, served at `path` (`/TV%20Shows/`),
    /// port-free: by this device's key, reached where it says it serves, so
    /// a new port is one field, not every copy written again.
    func ownAddress(_ path: String) -> String? {
        status.map { "cqdevice://\($0.device)\(path)" }
    }

    /// An item's file on this device: downloaded (the one that plays, as a
    /// download plays first), else in one of its folders.
    func fileHere(_ item: TitleDetail.Item) -> URL? {
        item.qualities.flatMap(\.copies).lazy.compactMap(Playback.downloaded).first.flatMap { URL(string: $0.url) } ?? folderFile(item)
    }

    /// A source's name as a person knows it: a folder of this Mac's by its
    /// own name, else its server and folders ("sulaco › Video › TV Shows").
    func sourceName(_ id: String) -> String {
        guard let source = sources.first(where: { $0.id == id }) else { return "its source" }
        return folder(of: source)?.name ?? source.displayName
    }

    /// The folder a source serves from this device, if it's one.
    func folder(of source: Source) -> Folder? {
        folders.first { $0.url == source.url }
    }

    /// Serves a folder of this device as a source at `/NAME/`, by its
    /// port-free address (`ownAddress`), adds it, and crawls it.
    func addFolder(_ path: String) async {
        loadFolders()
        #if os(macOS)
        if let why = overlapsDownloads(path) { return report(.change, why) }
        #endif
        // The folder's own name, whole, as its address's path (encoded), so
        // nothing's lost that would be read back: not a slug ("TV Shows",
        // not tv-shows). Nothing hidden, as the server serves nothing
        // starting with a dot.
        let base = URL(fileURLWithPath: path).lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        var prefix = base.isEmpty ? "Folder" : base
        var n = 2
        // Downloads have a prefix of their own.
        while folders.contains(where: { $0.prefix == prefix }) || prefix == Self.downloadsPrefix {
            prefix = "\(base.isEmpty ? "Folder" : base) \(n)"
            n += 1
        }
        folders.append(Folder(prefix: prefix, path: path, url: ""))
        serve()
        // URLs' unreserved characters, ASCII's alone; the rest encoded.
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard servingPort != nil, let encoded = prefix.addingPercentEncoding(withAllowedCharacters: unreserved),
              let url = ownAddress("/\(encoded)/") else {
            folders.removeLast()
            return
        }
        folders[folders.count - 1].url = url
        saveFolders()
        addSource(folders[folders.count - 1].url, skip: nil)
        await crawl()
    }

    /// Serves a folder's source from another folder of this device (a drive
    /// replaced, a folder moved), at the same address, so it stays the same
    /// source: its next crawl keeps the copies that are there alike.
    func changeFolder(_ folder: Folder, to path: String) async {
        loadFolders()
        #if os(macOS)
        if let why = overlapsDownloads(path) { return report(.change, why) }
        #endif
        guard let i = folders.firstIndex(where: { $0.prefix == folder.prefix }) else { return }
        folders[i] = Folder(prefix: folder.prefix, path: path, url: folder.url)
        saveFolders()
        serve()
        await crawl()
    }

    /// Removes a source, and if it's one of this device's folders, stops
    /// serving it.
    func remove(_ source: Source) {
        if let folder = folder(of: source) { removeFolder(folder) } else { removeSource(source.id) }
    }

    /// Stops serving a folder, and removes its source.
    private func removeFolder(_ folder: Folder) {
        loadFolders()
        if let source = sources.first(where: { $0.url == folder.url }) { removeSource(source.id) }
        folders.removeAll { $0.prefix == folder.prefix }
        saveFolders()
        serve()
    }


    /// Serves this library to devices (their syncs, so this device's changes,
    /// such as progress, reach them), and this device's folders, while the
    /// app runs, on the port it served on last (so devices that knew it
    /// find it there); where it got another, it says so (`cq_set_served`),
    /// its folders' addresses, port-free, unchanged.
    func serve() {
        guard let handle, hasLibrary else { return }
        loadFolders()
        let defaults = UserDefaults.standard
        unavailableFolders = foldersNotThere
        var mounts = folders.map { ($0.prefix, $0.path) }
        #if os(macOS)
        if downloads == nil { reloadDownloads() }
        try? FileManager.default.createDirectory(atPath: downloadsDir, withIntermediateDirectories: true)
        mounts.append((Self.downloadsPrefix, downloadsDir))
        #endif
        let port = withCStrings(mounts.flatMap { [$0.0, $0.1] }) { strings, _ in
            let cFolders = mounts.indices.map { cq_folder(prefix: strings![2 * $0], path: strings![2 * $0 + 1]) }
            return cq_serve(handle.pointer, Int32(defaults.integer(forKey: "servingPort")), cFolders, cFolders.count)
        }
        if port < 0 {
            servingPort = nil
            report(.serve, "Couldn't share the library with your other devices: \(Self.reason(String(cString: cq_error()))).")
        } else {
            servingPort = Int(port)
            defaults.set(Int(port), forKey: "servingPort")
            report(.serve, nil)
            #if os(macOS)
            // Where its own folders and downloads are reached (the core
            // writes it only if it's changed).
            check { cq_set_served($0, "http://\(Self.localHost):\(port)/") }
            #endif
            nameFolders()
            #if os(macOS)
            Task { await configureDownloads() }
            #endif
        }
    }

    /// Names this device's folders' sources by the folders' own names
    /// ("Archive1841", "TV Shows"), as their addresses can't put them, so
    /// every device shows them so (the core writes only what's changed).
    private func nameFolders() {
        for folder in folders where !folder.url.isEmpty {
            guard let source = sources.first(where: { $0.url == folder.url }), source.path.last != folder.name else { continue }
            check { cq_repo_name($0, source.id, folder.name) }
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

    /// Syncs with devices found or added, then crawls every source: what
    /// devices have crawled and described arrives first, so crawling then
    /// finds little to do. Shown as looking for new videos throughout, as
    /// catching up goes on by itself anyway.
    func refresh() async { await refresh { cq_crawl($0) } }

    /// As `refresh`, listing every folder afresh, as a folder's time doesn't
    /// change as a file in it is rewritten in place (retagged).
    func refreshFully() async { await refresh { cq_crawl_full($0) } }

    private func refresh(crawling crawl: @escaping @Sendable (OpaquePointer) -> UnsafeMutablePointer<CChar>?) async {
        let synced = await long("Looking for new videos", results: noteReceived, unreported: Self.unreachable) { cq_sync($0) }
        let crawled = await crawlSources(crawl)
        report(.refresh, synced ?? crawled)
        #if os(macOS)
        reconcileSoon()
        #endif
    }

    func crawl() async { report(.refresh, await crawlSources { cq_crawl($0) }) }

    /// How often refreshes not asked for (at launch) look for new videos,
    /// for every device: hours, or 0 for only on Refresh Library.
    var crawlEvery: Int { status?.crawl_every ?? 24 }

    func setCrawlEvery(_ hours: Int) {
        checkAndReload { cq_crawl_every($0, Int32(hours)) }
    }

    /// The choices of how often to look, and their names.
    static let crawlChoices: [(hours: Int, name: String)] = [
        (0, "Manually"),
        (1, "Every Hour"),
        (3, "Every 3 Hours"),
        (24, "Every Day"),
        (168, "Every Week"),
    ]

    /// Crawls by `crawl` (`cq_crawl`, `cq_crawl_due`, or `cq_crawl_full`),
    /// logging how long each source took, and describing after, to tell
    /// where a slow crawl goes; returns why it failed, if it did.
    private func crawlSources(_ crawl: @escaping @Sendable (OpaquePointer) -> UnsafeMutablePointer<CChar>?) async -> String? {
        let clock = ContinuousClock()
        let start = clock.now
        return await long("Looking for new videos", results: { Self.logCrawl($0, took: clock.now - start) }, crawl)
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
            let skipped: Skipped?
        }
        enum Skipped: String, Decodable { case lately, manual, downloads, away }
        guard let sources = try? JSONDecoder().decode([Crawled].self, from: data) else { return }
        // Those skipped (crawled lately, only on Refresh Library, a
        // device's downloads, or a device's folder whose device hasn't said
        // where it serves) aren't worth a line each.
        for s in sources where s.skipped == nil {
            if let error = s.error {
                crawlLog.notice("Crawled \(Self.logged(s.url), privacy: .public): failed, \(error, privacy: .public)")
                continue
            }
            let total = Duration.milliseconds(s.total_ms ?? 0), listing = Duration.milliseconds(s.crawl_ms ?? 0)
            crawlLog.notice("Crawled \(Self.logged(s.url), privacy: .public) in \(total.logged, privacy: .public): listing \(listing.logged, privacy: .public) (\(s.requests ?? 0) read, \(s.reused ?? 0) reused), recording \((total - listing).logged, privacy: .public); \(s.files) files, \(s.changed ?? 0) copies changed")
        }
        let crawling = Duration.milliseconds(sources.reduce(0) { $0 + ($1.total_ms ?? 0) })
        crawlLog.notice("Looked for new videos in \(took.logged, privacy: .public): \(sources.count) sources in \(crawling.logged, privacy: .public), then describing (and the rest) \((took - crawling).logged, privacy: .public)")
    }


}

extension Library {
    /// A source's address for the log, without any password in it.
    nonisolated static func logged(_ address: String) -> String {
        guard var parts = URLComponents(string: address) else { return "?" }
        parts.user = nil
        parts.password = nil
        return parts.string ?? "?"
    }
}
