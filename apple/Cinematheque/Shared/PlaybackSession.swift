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
    /// Called once the queue's last item has played to its end.
    var onFinished: (() -> Void)?
    /// The queue's last player item.
    private var last: ObjectIdentifier?
    private let library: Library
    /// Describes each player item, as `init` was given.
    private let describe: (AVPlayerItem, PlayRequest.Entry) -> Void
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
    init(request: PlayRequest, library: Library, prepare: @escaping (AVPlayerItem, PlayRequest.Entry) -> Void = { _, _ in }) {
        self.library = library
        describe = prepare
        start = request.start
        item = request.item
        var entries: [ObjectIdentifier: PlayRequest.Entry] = [:]
        let all = [request.first] + request.queue
        let items = all.map { entry in
            let playerItem = AVPlayerItem(url: entry.url)
            prepare(playerItem, entry)
            entries[ObjectIdentifier(playerItem)] = entry
            return playerItem
        }
        self.entries = entries
        last = items.last.map(ObjectIdentifier.init)
        player = AVQueuePlayer(items: items)
    }

    /// Once closed, it doesn't start.
    private var closed = false

    /// Readies the first item, paused, at the request's start (resuming,
    /// `Platform.replay` before it): loaded, sought, and buffered
    /// (prerolled), so it plays at once.
    func prepare() async {
        guard let current = player.currentItem, let first = await loaded(await prefer(current)) else { return }
        guard first.status == .readyToPlay, !closed else { return }
        if start > 0 { await player.seek(to: CMTime(seconds: max(0, start - Platform.replay), preferredTimescale: 600)) }
        guard !closed else { return }
        _ = await player.preroll(atRate: 1)
    }

    /// Puts the copy of `playerItem`'s item whose server answers first
    /// (copy racing, `Library.race`) in its place, if that's another copy; returns
    /// the one to play.
    private func prefer(_ playerItem: AVPlayerItem) async -> AVPlayerItem {
        guard var entry = entries[ObjectIdentifier(playerItem)], !entry.alternates.isEmpty else { return playerItem }
        let ordered = await library.race([entry.url] + entry.alternates)
        guard !closed, let first = ordered.first, entries[ObjectIdentifier(playerItem)] != nil else { return playerItem }
        entry.alternates = Array(ordered.dropFirst())
        guard first != entry.url else {
            entries[ObjectIdentifier(playerItem)] = entry
            return playerItem
        }
        entry.url = first
        return replace(playerItem, with: entry)
    }

    /// Waits for `playerItem` to load. If it fails (its repository asleep,
    /// say, or its drive unplugged), puts the item's next copy in its place,
    /// until one loads or none is left; returns the one that loaded, if any.
    private func loaded(_ playerItem: AVPlayerItem) async -> AVPlayerItem? {
        var trying = playerItem
        while true {
            while trying.status == .unknown, !closed { try? await Task.sleep(for: .milliseconds(20)) }
            if closed { return nil }
            if trying.status == .readyToPlay { return trying }
            guard var entry = entries[ObjectIdentifier(trying)] else { return nil }
            library.raceLost(entry.url)
            guard !entry.alternates.isEmpty else { return nil }
            entry.url = entry.alternates.removeFirst()
            trying = replace(trying, with: entry)
        }
    }

    /// Puts a player item for `entry` (another copy of `old`'s item) where
    /// `old` is in the queue; returns it.
    private func replace(_ old: AVPlayerItem, with entry: PlayRequest.Entry) -> AVPlayerItem {
        let replacement = AVPlayerItem(url: entry.url)
        describe(replacement, entry)
        let id = ObjectIdentifier(old)
        entries[id] = nil
        entries[ObjectIdentifier(replacement)] = entry
        if last == id { last = ObjectIdentifier(replacement) }
        if player.items().contains(old) {
            player.insert(replacement, after: old)
            player.remove(old)
        } else {
            // The player dropped it already, as it does a failed item: the
            // replacement goes first.
            let rest = player.items()
            player.removeAllItems()
            for queued in [replacement] + rest { player.insert(queued, after: nil) }
        }
        return replacement
    }

    /// Starts as the players do: warming up, paused (`prepare`), for at
    /// least `fade` (as the screen fades to black), then playing, its sound
    /// rising as the picture fades in. Returns once playing, to fade to the
    /// picture.
    func begin(fade: Duration = .seconds(Platform.fade)) async {
        let clock = ContinuousClock()
        let faded = clock.now + fade
        await prepare()
        try? await Task.sleep(until: faded, clock: clock)
        guard !closed else { return }
        // Silent until its curtain rises.
        player.volume = 0
        play()
    }

    /// Plays, from where it's readied (`prepare`), keeping playheads.
    func play() {
        player.play()
        // The rest of the queue, each from the copy whose server answers
        // first, before it comes up.
        Task {
            for queued in player.items().dropFirst() where !closed { _ = await prefer(queued) }
        }
        current = player.observe(\.currentItem, options: [.new]) { [weak self] player, _ in
            let id = player.currentItem.map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let id, let entry = self.entries[id] else { return }
                self.item = entry.item
                self.onItem?(entry)
                // A queued item that doesn't load gives way to another copy.
                if let playing = player.currentItem, playing.status != .readyToPlay {
                    Task { await self.loaded(playing) }
                }
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
                if id == self.last { self.onFinished?() }
            }
        }
    }

    /// Takes the sound from where it is to `volume` (1, full; 0, silent)
    /// over `duration`, as the picture fades in or out.
    func ramp(to volume: Float, over duration: Duration) {
        let from = player.volume
        Task { [player] in
            let steps = 24
            for step in 1...steps {
                try? await Task.sleep(for: duration / steps)
                player.volume = from + (volume - from) * Float(step) / Float(steps)
            }
        }
    }

    /// Stops where it is, as when its window closes.
    func close() {
        closed = true
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
        // Pausing or leaving: other devices hear of it now.
        library.changed()
    }
}
