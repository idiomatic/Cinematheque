import CCinematheque
import Foundation

extension Library {
    // Keeping in sync while running, and saying so.

    /// An exchange with devices: how many operations, with whom, and when.
    struct Exchange: Equatable {
        let count: Int
        let device: String
        let at: Date
    }


    /// The setting that shows sync activity (`syncLine`, or the Apple TV's
    /// corner), for diagnosis; off, as most people needn't see it.
    static let showsSyncActivity = "showSyncActivity"

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
        reload()
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
        if ok { described += 1 }
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
