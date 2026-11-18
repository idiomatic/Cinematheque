import AVKit
import SwiftUI

/// What to play: a copy's URL, the item it's a copy of (for its playhead),
/// where to start, and what to play after it (e.g., the rest of a season).
struct PlayRequest: Codable, Hashable {
    struct Entry: Codable, Hashable {
        let url: URL
        let item: String
        let title: String
    }

    let url: URL
    let item: String
    let start: Double
    var title: String = ""
    var queue: [Entry] = []
}

/// Plays copies straight from their repositories, in AppKit's player view,
/// one after another, keeping each item's playhead.
struct PlayerView: View {
    let request: PlayRequest
    @Environment(Library.self) private var library
    @State private var title = ""

    var body: some View {
        Player(request: request, library: library, title: $title)
            .frame(minWidth: 640, minHeight: 360)
            .navigationTitle(title.isEmpty ? (request.url.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? "Player") : title)
            .onAppear { title = request.title }
    }
}

private struct Player: NSViewRepresentable {
    let request: PlayRequest
    let library: Library
    @Binding var title: String

    @MainActor
    final class Coordinator {
        let library: Library
        var observer: Any?
        var ended: NSObjectProtocol?
        var current: NSKeyValueObservation?
        var status: NSKeyValueObservation?
        /// Each queued player item's item key and title.
        var entries: [ObjectIdentifier: PlayRequest.Entry] = [:]
        /// The item playing.
        var item = ""
        /// Whether playing has begun, before which a pause isn't a stop.
        var started = false

        init(library: Library) { self.library = library }

        /// Saves the playhead where the player stopped; the core deletes it
        /// if that's within the first 10 seconds, so rewinding to the start
        /// sticks.
        func stopped(_ player: AVPlayer) {
            guard started, let current = player.currentItem else { return }
            library.setPlayhead(item, position: player.currentTime().seconds, duration: current.duration.seconds)
            // The grid's progress bars and watched marks.
            library.reload()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(library: library) }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.allowsPictureInPicturePlayback = true
        // The whole queue up front: the queue player goes on to the next
        // item at each one's end by itself.
        let coordinator = context.coordinator
        let all = [PlayRequest.Entry(url: request.url, item: request.item, title: request.title)] + request.queue
        let items = all.map { entry in
            let item = AVPlayerItem(url: entry.url)
            coordinator.entries[ObjectIdentifier(item)] = entry
            return item
        }
        let player = AVQueuePlayer(items: items)
        view.player = player
        coordinator.item = request.item
        if request.start > 0 {
            player.seek(to: CMTime(seconds: request.start, preferredTimescale: 600))
        }
        player.play()
        let library = library
        let title = $title
        // Follow the item playing, for its playhead and the window's title.
        coordinator.current = player.observe(\.currentItem, options: [.new]) { player, _ in
            let id = player.currentItem.map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let id, let entry = coordinator.entries[id] else { return }
                coordinator.item = entry.item
                title.wrappedValue = entry.title
            }
        }
        // Save the playhead every 10 seconds of playing, but not within the
        // first 10 seconds, which (before a resume's seek lands) would
        // delete it; only stopping there does.
        coordinator.observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 1), queue: .main) { [weak player] time in
            MainActor.assumeIsolated {
                guard let player, player.rate != 0, time.seconds >= 10, let duration = player.currentItem?.duration.seconds else { return }
                library.setPlayhead(coordinator.item, position: time.seconds, duration: duration)
            }
        }
        // And where it's paused.
        coordinator.status = player.observe(\.timeControlStatus, options: [.new]) { player, _ in
            let status = player.timeControlStatus
            MainActor.assumeIsolated {
                if status == .playing { coordinator.started = true }
                if status == .paused { coordinator.stopped(player) }
            }
        }
        // Mark each item watched at its end.
        coordinator.ended = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { note in
            let ended = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let ended, let entry = coordinator.entries[ended] else { return }
                library.setWatched(entry.item, true)
                library.reload()
            }
        }
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        guard let player = view.player else { return }
        if let observer = coordinator.observer { player.removeTimeObserver(observer) }
        if let ended = coordinator.ended { NotificationCenter.default.removeObserver(ended) }
        coordinator.current?.invalidate()
        coordinator.status?.invalidate()
        // Closing the window stops it where it is.
        if player.rate != 0 { coordinator.stopped(player) }
        player.pause()
    }
}
