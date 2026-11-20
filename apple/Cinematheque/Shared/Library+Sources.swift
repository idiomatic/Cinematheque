import CCinematheque
import Foundation
import os

extension Library {
    // Managing.

    func addSource(_ url: String, quality: String?, skip: String?) {
        check { cq_repo_add($0, url, quality, skip) }
    }

    func setSource(_ id: String, quality: String?, skip: String?) {
        check { cq_repo_set($0, id, quality, skip) }
    }

    /// Whether a source's files take their quality from the first folder
    /// within it, by ID or URL; copies move at its next crawl.
    func setQualityByFolder(_ source: String, _ on: Bool) { check { cq_repo_quality_by_folder($0, source, on ? 1 : 0) } }

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
        // Not asked for: sources another device crawled lately, whose
        // copies syncing brought, aren't crawled again.
        let crawled = await crawlSources(due: true)
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

    /// Notes folders that have come back, or gone, for Settings to show.
    func checkFolders() {
        // Off the main actor: a share that's hung can hold a stat for its timeout.
        let folders = folders
        Task {
            let now = await Task.detached { Self.missing(folders) }.value
            if now != unavailableFolders { unavailableFolders = now }
        }
    }

    private var foldersKey: String { "folders-" + (status?.library ?? "") }


    private func loadFolders() {
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
            guard let folder = folders.first(where: { !$0.url.isEmpty && copy.url.hasPrefix($0.url) && !unavailableFolders.contains($0.prefix) }),
                  let path = String(copy.url.dropFirst(folder.url.count)).removingPercentEncoding else { continue }
            return URL(fileURLWithPath: folder.path).appending(path: path)
        }
        return nil
    }

    /// An item's file on this device: downloaded (the one that plays, as a
    /// download plays first), else in one of its folders.
    func fileHere(_ item: TitleDetail.Item) -> URL? {
        item.qualities.flatMap(\.copies).lazy.compactMap(Playback.downloaded).first.flatMap { URL(string: $0.url) } ?? folderFile(item)
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
    /// finds little to do. Shown as looking for new videos throughout, as
    /// catching up goes on by itself anyway.
    func refresh() async {
        let synced = await long("Looking for new videos", results: noteReceived) { cq_sync($0, nil) }
        let crawled = await crawlSources()
        report(.refresh, synced ?? crawled)
        #if os(macOS)
        reconcileSoon()
        #endif
    }

    func crawl() async { report(.refresh, await crawlSources()) }

    /// How often refreshes not asked for (at launch) look for new videos,
    /// for every device: hours, or 0 for only on Refresh Library.
    var crawlEvery: Int { status?.crawl_every ?? 24 }

    func setCrawlEvery(_ hours: Int) {
        check { cq_crawl_every($0, Int32(hours)) }
    }

    /// The choices of how often to look, and their names.
    static let crawlChoices: [(hours: Int, name: String)] = [
        (0, "Manually"),
        (1, "Every Hour"),
        (3, "Every 3 Hours"),
        (24, "Every Day"),
        (168, "Every Week"),
    ]

    /// Crawls every source (`cq_crawl`), or if `due`, those no device
    /// crawled lately (`cq_crawl_due`), logging how long each took, and
    /// describing after, to tell where a slow crawl goes; returns why it
    /// failed, if it did.
    private func crawlSources(due: Bool = false) async -> String? {
        let clock = ContinuousClock()
        let start = clock.now
        return await long("Looking for new videos", results: { Self.logCrawl($0, took: clock.now - start) }) { due ? cq_crawl_due($0) : cq_crawl($0) }
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
            let lately: Bool?
            let manual: Bool?
        }
        guard let sources = try? JSONDecoder().decode([Crawled].self, from: data) else { return }
        for s in sources {
            if s.manual == true {
                crawlLog.notice("Skipped \(s.url, privacy: .public): looked in only on Refresh Library")
                continue
            }
            if s.lately == true {
                crawlLog.notice("Skipped \(s.url, privacy: .public): a device crawled it in the last day")
                continue
            }
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

}
