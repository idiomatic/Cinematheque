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
        var observer: Any?
        var ended: NSObjectProtocol?
        /// The item playing, and those after it.
        var item = ""
        var queue: [PlayRequest.Entry] = []
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.allowsPictureInPicturePlayback = true
        let player = AVQueuePlayer(url: request.url)
        view.player = player
        let coordinator = context.coordinator
        coordinator.item = request.item
        coordinator.queue = request.queue
        if request.start > 0 {
            player.seek(to: CMTime(seconds: request.start, preferredTimescale: 600))
        }
        player.play()
        // Save the playhead every 10 seconds of playing.
        let library = library
        coordinator.observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 1), queue: .main) { [weak player] time in
            MainActor.assumeIsolated {
                guard let player, player.rate != 0, let duration = player.currentItem?.duration.seconds else { return }
                library.setPlayhead(coordinator.item, position: time.seconds, duration: duration)
            }
        }
        // At the end, mark it watched and play the next.
        let title = $title
        coordinator.ended = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak player] note in
            let ended = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let player, let current = player.currentItem, ObjectIdentifier(current) == ended else { return }
                library.setWatched(coordinator.item, true)
                guard !coordinator.queue.isEmpty else { return }
                let next = coordinator.queue.removeFirst()
                coordinator.item = next.item
                title.wrappedValue = next.title
                player.replaceCurrentItem(with: AVPlayerItem(url: next.url))
                player.play()
            }
        }
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        guard let player = view.player else { return }
        if let observer = coordinator.observer { player.removeTimeObserver(observer) }
        if let ended = coordinator.ended { NotificationCenter.default.removeObserver(ended) }
        player.pause()
    }
}
