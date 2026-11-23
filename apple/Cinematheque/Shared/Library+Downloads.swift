import CCinematheque
import Foundation
#if os(macOS)
import SystemConfiguration
#endif

#if os(macOS)
extension Library {
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
        /// `cq_download_next` takes it: a count, or `all`.
        struct Next: Decodable, Equatable {
            let title: String
            let choice: String
        }

        let dir: String?
        let source: String?
        let held: [Held]
        let wanted: [Wanted]
        let next: [Next]
        /// The episodes (full item keys) the series' choices come to now.
        let ahead: [String]
        let free: Int?
        let floor: Int
        let running: Bool
        let done_mb: Int
        let total_mb: Int
        /// The file being fetched: its item's full key, size, and bytes here.
        struct Fetching: Decodable, Equatable {
            let item: String
            let size: Int
            let done: Int
        }
        let fetching: Fetching?
    }


    /// Where downloads go unless Settings says otherwise.
    static var defaultDownloads: String { URL.moviesDirectory.appending(path: "Cinematheque").path }

    var downloadsDir: String { downloads?.dir ?? Self.defaultDownloads }

    /// This Mac's name on the local network, e.g., `firefly.local`.
    static var localHost: String {
        let name = SCDynamicStoreCopyLocalHostName(nil) as String? ?? ProcessInfo.processInfo.hostName
        return name.hasSuffix(".local") ? name : name + ".local"
    }

    /// Changes what this Mac keeps (its own, never synced), reading back
    /// its downloads alone: the whole catalog read again, on the main
    /// thread, held a pop-up's choice for a second on a large library.
    private func changeKept(_ body: (OpaquePointer) -> Int32) {
        guard let handle else { return }
        reportChange(body(handle.pointer) != 0 ? String(cString: cq_error()) : nil)
        reloadDownloads()
    }

    func reloadDownloads() {
        let loaded = decode(Downloads.self) { cq_downloads($0) }
        guard loaded != downloads else { return }
        downloads = loaded
        // Assigned only if it differs: every tile reads it, for its mark,
        // and any assignment redraws them all (half a second, on a large
        // library), as a series' choice or a download's progress changes
        // what's kept without changing what's held.
        let held = Self.tiles(of: (loaded?.held ?? []).map(\.item))
        if held != downloadedTiles { downloadedTiles = held }
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
        changeKept { cq_download($0, key, quality) }
        reconcileSoon()
    }

    /// Deletes a title's, season's, or item's downloads, and stops wanting
    /// them.
    func removeDownload(_ key: String) {
        // The series' choice, if it asks for any of them, is stopped first
        // (by the core). Off the main thread, as it waits its turn to
        // write, which a refresh may hold a while.
        Task { await changeApart { cq_download_remove($0, key) } }
    }

    /// How far an item, or a movie's or season's items, have come (`of`,
    /// what they come to all told): what's here, and the bytes of the file
    /// under way, if it's theirs; 0 to 1.
    func downloadProgress(_ keys: [String], of size: DownloadSize?) -> Double {
        guard let size, size.size > 0 else { return 0 }
        var here = size.size - size.needed
        if let f = downloads?.fetching, keys.contains(where: { f.item == $0 || f.item.hasPrefix($0 + "/") }) { here += f.done }
        return min(1, Double(here) / Double(size.size))
    }

    /// How far an item being fetched has come, 0 to 1; 0 while it waits.
    func downloadProgress(_ item: String) -> Double {
        guard let f = downloads?.fetching, f.item == item, f.size > 0 else { return 0 }
        return min(1, Double(f.done) / Double(f.size))
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
        let cChoices = choices.map(Self.downloadChoice)
        let sizes = decode([DownloadSize].self) { cq_download_sizes($0, key, cChoices, cChoices.count, quality) } ?? []
        return Dictionary(sizes.map { ($0.choice, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// A choice as `cq_download_sizes` takes it: empty for the key's own
    /// files, `all`, or a count, the next N (any other, as none, fails).
    private static func downloadChoice(_ choice: String) -> cq_download_choice {
        switch choice {
        case "": cq_download_choice(kind: CQ_DOWNLOAD_OWN, count: 0)
        case "all": cq_download_choice(kind: CQ_DOWNLOAD_ALL, count: 0)
        default: cq_download_choice(kind: CQ_DOWNLOAD_NEXT, count: UInt32(choice) ?? 0)
        }
    }

    /// The space available for downloads: what's free, less what they keep
    /// free. Free is the disk's; available, what Cinematheque recommends.
    var availableForDownloads: Int? {
        guard let d = downloads, let free = d.free else { return nil }
        return max(0, free - d.floor)
    }

    /// Chooses which of a series' episodes download as it's watched (see
    /// `Downloads.Next`); empty, none.
    func chooseDownloads(_ title: String, _ choice: String) {
        changeKept { cq_download_next($0, title, choice) }
        reconcileSoon()
    }

    /// Changes where downloads go.
    func setDownloads(dir: String? = nil) {
        Task {
            await configureDownloads(dir: dir)
            // Served from the new folder; what's wanted is fetched there.
            if let dir, dir != downloadsDir, servingPort != nil { serve() }
            reconcileSoon()
        }
    }

    /// Tells the core where downloads are kept and served (on the port this
    /// Mac serves on, or last did); a source served at another address
    /// before (another port) is removed, its copies recorded afresh as
    /// reconciling finds the files.
    func configureDownloads(dir: String? = nil) async {
        guard hasLibrary else { return }
        let port = servingPort ?? UserDefaults.standard.integer(forKey: "servingPort")
        guard port > 0 else { return }
        let path = dir ?? downloadsDir
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let url = "http://\(Self.localHost):\(port)/\(Self.downloadsPrefix)/"
        if let id = downloads?.source, let old = sources.first(where: { $0.id == id }), old.url != url {
            removeSource(old.id)
        }
        // Off the main thread, as it waits its turn to write.
        await changeApart { cq_downloads_configure($0, path, url) }
    }


    /// Notes a playback session streaming, or not; when none is, what
    /// waited is fetched.
    func streaming(_ session: AnyObject, _ on: Bool) {
        let id = ObjectIdentifier(session)
        let was = !streams.isEmpty
        if on { streams.insert(id) } else { streams.remove(id) }
        guard let handle, was != !streams.isEmpty else { return }
        if streams.isEmpty { cq_downloads_resume(handle.pointer) } else { cq_downloads_hold(handle.pointer) }
        if streams.isEmpty { reconcileSoon() }
    }

    /// Fetches and deletes downloads to match what's kept, off the main
    /// thread, showing how far it's come; if it's running, it runs again.
    func reconcileSoon() {
        guard let handle, hasLibrary, downloads?.dir != nil, !leavingLibrary else { return }
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
                        await self.reloadApart()
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
            reloadSoon()
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

}
#endif
