import CCinematheque
import Foundation
import OSLog

extension Library {
    // Keeping in sync while running, and saying so.

    /// Each exchange that changed something, in the system's log, for
    /// diagnosis (as `crawl` and `playback` log theirs).
    static let syncLog = Logger(subsystem: "com.rbrian.cinematheque", category: "sync")

    /// While the app runs: syncs quietly a minute after it last synced (as
    /// when it comes to the front), so what other devices change
    /// (progress, the watchlist) arrives without a refresh; and reloads
    /// once a device has pushed its changes here, as the server's
    /// connection commits them (`cq_data_version`).
    func keepInSync() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            // Nothing redrawn while the app goes to the background, as the
            // system snapshots it; at the front again, it syncs at once.
            guard active else { continue }
            reloadSoon()
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
                if await syncKnownQuietly() { return }
                guard handle != nil, hasLibrary else { return }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// Syncs with every device, without showing it as an activity, unless
    /// something else is running; returns whether it did.
    @discardableResult
    func syncQuietly() async -> Bool { await syncQuietly { cq_sync($0) } }

    /// As `syncQuietly`, with the devices the last sync found
    /// (`cq_sync_known`), not looking again.
    @discardableResult
    func syncKnownQuietly() async -> Bool { await syncQuietly { cq_sync_known($0) } }

    private func syncQuietly(_ sync: @escaping @Sendable (OpaquePointer) -> UnsafeMutablePointer<CChar>?) async -> Bool {
        guard let handle, hasLibrary, activity == nil, !syncingQuietly, !leavingLibrary else { return false }
        syncingQuietly = true
        defer { syncingQuietly = false }
        lastSync = .now
        let data: Data? = await Task.detached {
            guard let text = sync(handle.pointer) else { return nil }
            defer { cq_free(text) }
            return Data(bytes: text, count: strlen(text))
        }.value
        if let data { noteReceived(data) }
        reloadSoon()
        // What's watched, here or elsewhere, moves kept series along.
        #if os(macOS)
        reconcileSoon()
        #endif
        return true
    }

    func noteReceived(_ data: Data) {
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
        for r in results where r.error == nil && (r.new > 0 || (r.sent ?? 0) > 0) {
            Self.syncLog.info("\(r.device, privacy: .public): received \(r.new), sent \(r.sent ?? 0)")
        }
    }

    /// Reads an item's metadata from its file, in the background.
    func describe(_ itemKey: String) async {
        if await apart({ cq_describe($0, itemKey) == 0 }) == true { described += 1 }
    }

    /// Reads a season's episodes' metadata (titles, descriptions,
    /// durations), or a movie's versions' (durations), one at a time, where
    /// not read from their files as they are now (a crawl reads only a
    /// season's first episode, and a movie's first version; a file
    /// retagged since reads again).
    func describeItems(of key: String, season: Int?) async {
        guard let detail = detail(key) else { return }
        for item in Playback.items(detail, season: season) where item.described != true {
            if Task.isCancelled { return }
            await describe("\(detail.key)/\(item.key)")
        }
    }

}
