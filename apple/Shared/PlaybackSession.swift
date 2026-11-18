import AVFoundation

/// Plays a request's queue straight from repositories, one item after
/// another, keeping each item's playhead: every 10 seconds of playing (but
/// not within the first 10, where a resume's seek may not have landed),
/// where it's paused, and where it's closed, so stopping within the first
/// 10 seconds deletes it (the core's rule); and marking each item watched
/// at its end. The players wrap it in their platforms' views.
@MainActor
final class PlaybackSession {
    /// The whole queue up front: it goes on to the next item at each one's
    /// end by itself.
    let player: AVQueuePlayer
    /// Called as each item starts, e.g., for a window's title.
    var onItem: ((PlayRequest.Entry) -> Void)?
    private let library: Library
    private let start: Double
    /// Each queued player item's item key and title.
    private var entries: [ObjectIdentifier: PlayRequest.Entry] = [:]
    /// The item playing.
    private var item: String
    /// Whether playing has begun, before which a pause isn't a stop.
    private var started = false
    private var periodic: Any?
    private var ended: NSObjectProtocol?
    private var current: NSKeyValueObservation?
    private var status: NSKeyValueObservation?

    /// `prepare` may describe each player item, e.g., with metadata for a
    /// system player's info panel.
    init(request: PlayRequest, library: Library, prepare: (AVPlayerItem, PlayRequest.Entry) -> Void = { _, _ in }) {
        self.library = library
        start = request.start
        item = request.item
        var entries: [ObjectIdentifier: PlayRequest.Entry] = [:]
        let all = [PlayRequest.Entry(url: request.url, item: request.item, title: request.title)] + request.queue
        let items = all.map { entry in
            let playerItem = AVPlayerItem(url: entry.url)
            prepare(playerItem, entry)
            entries[ObjectIdentifier(playerItem)] = entry
            return playerItem
        }
        self.entries = entries
        player = AVQueuePlayer(items: items)
    }

    /// Starts playing, at the request's start, and keeping playheads.
    func play() {
        if start > 0 { player.seek(to: CMTime(seconds: start, preferredTimescale: 600)) }
        player.play()
        current = player.observe(\.currentItem, options: [.new]) { [weak self] player, _ in
            let id = player.currentItem.map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let id, let entry = self.entries[id] else { return }
                self.item = entry.item
                self.onItem?(entry)
            }
        }
        periodic = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 1), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.player.rate != 0, time.seconds >= 10, let duration = self.player.currentItem?.duration.seconds else { return }
                self.library.setPlayhead(self.item, position: time.seconds, duration: duration)
            }
        }
        status = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            MainActor.assumeIsolated {
                guard let self else { return }
                if status == .playing { self.started = true }
                if status == .paused { self.stopped() }
            }
        }
        ended = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            let id = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let id, let entry = self.entries[id] else { return }
                self.library.setWatched(entry.item, true)
                self.library.reload()
            }
        }
    }

    /// Stops where it is, as when its window closes.
    func close() {
        if let periodic { player.removeTimeObserver(periodic) }
        if let ended { NotificationCenter.default.removeObserver(ended) }
        current?.invalidate()
        status?.invalidate()
        if player.rate != 0 { stopped() }
        player.pause()
    }

    /// Saves the playhead where the player stopped.
    private func stopped() {
        guard started, let playing = player.currentItem else { return }
        library.setPlayhead(item, position: player.currentTime().seconds, duration: playing.duration.seconds)
        // Tiles' progress bars and watched marks.
        library.reload()
    }
}
