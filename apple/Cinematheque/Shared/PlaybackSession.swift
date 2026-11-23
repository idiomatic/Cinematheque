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
    /// Once closed, it doesn't start.
    private var closed = false
    /// The sound's ramp under way.
    private var ramping: Task<Void, Never>?
    #if os(macOS)
    /// The item reconciling downloads last began for.
    private var reconciled: String?
    /// Held while it plays: the display doesn't dim or sleep.
    private var awake: NSObjectProtocol?
    #endif

    /// Each start's steps and their times, in the system's log (Xcode's
    /// console), in a line, to tell where a slow start goes.
    static let log = Logger(subsystem: "com.rbrian.cinematheque", category: "playback")

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

    /// Readies the first item, paused, at the request's start (resuming,
    /// `Platform.replay` before it): loaded, sought, and buffered
    /// (prerolled), so it plays at once.
    func prepare() async {
        let clock = ContinuousClock()
        let began = clock.now
        var mark = began
        var steps: [String] = []
        /// Notes a step, and how long since the last.
        func lap(_ step: String) {
            let now = clock.now
            steps.append("\(step) \((now - mark).logged)")
            mark = now
        }
        guard let current = player.currentItem else { return }
        let preferred = await prefer(current)
        lap("raced")
        let host = entries[ObjectIdentifier(preferred)]?.url.host() ?? "a file"
        guard let first = await loaded(preferred) else { return }
        lap("loaded")
        guard first.status == .readyToPlay, !closed else { return }
        if start > 0 {
            // Exactly, as the Mac's player seeks: by default, a seek may
            // land on the keyframe before, a GOP early (in a file with
            // sparse keyframes, minutes).
            await player.seek(to: CMTime(seconds: max(0, start - Platform.replay), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            lap("sought")
        }
        guard !closed else { return }
        _ = await player.preroll(atRate: 1)
        lap("prerolled")
        Self.log.notice("Playing \(self.item, privacy: .public) from \(host, privacy: .public): ready in \((clock.now - began).logged, privacy: .public) (\(steps.joined(separator: ", "), privacy: .public))")
    }

    /// Puts the copy of `playerItem`'s item whose server answers first
    /// (copy racing, `Library.race`) in its place, if that's another copy; returns
    /// the one to play.
    private func prefer(_ playerItem: AVPlayerItem) async -> AVPlayerItem {
        // A download plays from its file, with nothing to race.
        guard var entry = entries[ObjectIdentifier(playerItem)], entry.contenders > 1, !entry.url.isFileURL else { return playerItem }
        // Only the chosen quality's copies race; the rest follow, in order.
        let all = [entry.url] + entry.alternates
        let ordered = await library.race(Array(all.prefix(entry.contenders))) + all.dropFirst(entry.contenders)
        // The race took a while: the item may have played or been dropped.
        guard !closed, let first = ordered.first, entries[ObjectIdentifier(playerItem)] != nil, player.items().contains(playerItem) else { return playerItem }
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
    /// picture; false if there's nothing to play (it didn't load, or it's
    /// closed).
    func begin(fade: Duration = .seconds(Platform.fade)) async -> Bool {
        let clock = ContinuousClock()
        let faded = clock.now + fade
        await prepare()
        try? await Task.sleep(until: faded, clock: clock)
        guard !closed, player.currentItem?.status == .readyToPlay else { return false }
        // Silent until its curtain rises.
        player.volume = 0
        play()
        return true
    }

    /// Plays, from where it's readied (`prepare`), keeping progress.
    func play() {
        player.play()
        // The rest of the queue, each from the copy whose server answers
        // first, before it comes up.
        Task {
            for queued in player.items().dropFirst() where !closed { _ = await prefer(queued) }
        }
        // The observers hop to the main actor by a task, in order, rather
        // than assuming it: AVFoundation may call from another thread.
        current = player.observe(\.currentItem, options: [.new]) { [weak self] player, _ in
            let id = player.currentItem.map(ObjectIdentifier.init)
            Task { @MainActor in
                guard let self, !self.closed, let id, let entry = self.entries[id] else { return }
                self.item = entry.item
                self.onItem?(entry)
                self.noteStreaming()
                // A queued item that doesn't load gives way to another copy.
                if let playing = self.player.currentItem, playing.status != .readyToPlay {
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
            Task { @MainActor in
                guard let self, !self.closed else { return }
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
                self.library.reloadSoon()
                if id == self.last { self.onFinished?() }
            }
        }
    }

    /// Takes the sound from where it is to `volume` (1, full; 0, silent)
    /// over `duration`, as the picture fades in or out.
    func ramp(to volume: Float, over duration: Duration) {
        // One at a time: a new ramp replaces the one under way.
        ramping?.cancel()
        let from = player.volume
        ramping = Task { [player] in
            let steps = 24
            for step in 1...steps {
                try? await Task.sleep(for: duration / steps)
                guard !Task.isCancelled else { return }
                player.volume = from + (volume - from) * Float(step) / Float(steps)
            }
        }
    }

    /// Tells the library whether this streams now (playing, not from a
    /// file), so downloads wait rather than slow it; and while it plays,
    /// keeps the display awake.
    private func noteStreaming() {
        #if os(macOS)
        let playing = !closed && player.timeControlStatus == .playing
        let file = player.currentItem.flatMap { ($0.asset as? AVURLAsset)?.url.isFileURL } ?? false
        library.streaming(self, playing && !file)
        // AVPlayer's own (preventsDisplaySleepDuringVideoPlayback) didn't
        // hold: the display dimmed and slept mid-movie on battery.
        if playing, awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Playing a video")
        } else if !playing, let activity = awake {
            ProcessInfo.processInfo.endActivity(activity)
            awake = nil
        }
        #endif
    }

    /// Stops where it is, as when its window closes.
    func close() {
        closed = true
        ramping?.cancel()
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
        library.reloadSoon()
        // Pausing or leaving: other devices hear of it now.
        library.changed()
    }
}

extension Duration {
    /// As the log tells it, e.g., "3s 117ms".
    var logged: String { formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)) }
}
