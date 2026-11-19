import AVFoundation
import os

/// Plays a request's queue straight from sources, one item after
/// another, keeping each item's progress: every 10 seconds of playing (but
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
    /// The item reconciling downloads last began for (macOS).
    private var reconciled: String?
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

    /// Counts sessions, to tell them apart in the log.
    private static var made = 0
    private let number: Int = {
        made += 1
        return made
    }()

    /// Readies the first item, paused, at the request's start (resuming,
    /// `Platform.replay` before it): loaded, sought, and buffered
    /// (prerolled), so it plays at once.
    func prepare() async {
        let clock = ContinuousClock()
        var mark = clock.now
        /// How long since the last step, for the log.
        func lap() -> String {
            let now = clock.now
            defer { mark = now }
            return (now - mark).formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow))
        }
        guard let current = player.currentItem else { return }
        let preferred = await prefer(current)
        Self.log.notice("Starting #\(self.number): raced copies in \(lap(), privacy: .public), chose \(self.entries[ObjectIdentifier(preferred)]?.url.host() ?? "?", privacy: .public)")
        guard let first = await loaded(preferred) else { return }
        Self.log.notice("Starting #\(self.number): loaded in \(lap(), privacy: .public)")
        guard first.status == .readyToPlay, !closed else { return }
        if start > 0 {
            await player.seek(to: CMTime(seconds: max(0, start - Platform.replay), preferredTimescale: 600))
            Self.log.notice("Starting #\(self.number): sought in \(lap(), privacy: .public)")
        }
        guard !closed else { return }
        _ = await player.preroll(atRate: 1)
        Self.log.notice("Starting #\(self.number): prerolled in \(lap(), privacy: .public)")
    }

    /// Playback's steps and their times, in the system's log (Xcode's
    /// console), to tell where a slow start goes.
    static let log = Logger(subsystem: "com.rbrian.cinematheque", category: "playback")

    /// Puts the copy of `playerItem`'s item whose server answers first
    /// (copy racing, `Library.race`) in its place, if that's another copy; returns
    /// the one to play.
    private func prefer(_ playerItem: AVPlayerItem) async -> AVPlayerItem {
        // A download plays from its file, with nothing to race.
        guard var entry = entries[ObjectIdentifier(playerItem)], !entry.alternates.isEmpty, !entry.url.isFileURL else { return playerItem }
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

    /// Waits for `playerItem` to load. If it fails (its source asleep,
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

    /// Plays, from where it's readied (`prepare`), keeping progress.
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
                self.noteStreaming()
                // A queued item that doesn't load gives way to another copy.
                if let playing = player.currentItem, playing.status != .readyToPlay {
                    Task { await self.loaded(playing) }
                }
            }
        }
        periodic = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 1), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.player.rate != 0, time.seconds >= 10, let duration = self.player.currentItem?.duration.seconds else { return }
                self.library.setProgress(self.item, position: time.seconds, duration: duration)
                #if os(macOS)
                // In progress now: a kept series' next episode downloads
                // (once no stream plays).
                if self.reconciled != self.item {
                    self.reconciled = self.item
                    self.library.reconcileSoon()
                }
                #endif
            }
        }
        status = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            MainActor.assumeIsolated {
                guard let self else { return }
                if status == .playing { self.started = true }
                if status == .paused { self.stopped() }
                self.noteStreaming()
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

    /// Tells the library whether this streams now (playing, not from a
    /// file), so downloads wait rather than slow it.
    private func noteStreaming() {
        #if os(macOS)
        let file = player.currentItem.flatMap { ($0.asset as? AVURLAsset)?.url.isFileURL } ?? false
        library.streaming(self, !closed && player.timeControlStatus == .playing && !file)
        #endif
    }

    /// Stops where it is, as when its window closes.
    func close() {
        closed = true
        defer { noteStreaming() }
        if let periodic { player.removeTimeObserver(periodic) }
        if let ended { NotificationCenter.default.removeObserver(ended) }
        current?.invalidate()
        status?.invalidate()
        if player.rate != 0 { stopped() }
        player.pause()
    }

    /// Saves the progress where the player stopped.
    private func stopped() {
        guard started, let playing = player.currentItem else { return }
        library.setProgress(item, position: player.currentTime().seconds, duration: playing.duration.seconds)
        // Tiles' progress bars and watched marks.
        library.reload()
        // Pausing or leaving: other devices hear of it now.
        library.changed()
    }
}
