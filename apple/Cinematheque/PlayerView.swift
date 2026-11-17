import AVKit
import SwiftUI

/// What to play: a copy's URL, the item it's a copy of (for its playhead),
/// and where to start.
struct PlayRequest: Codable, Hashable {
    let url: URL
    let item: String
    let start: Double
}

/// Plays one copy, straight from its repository, in AppKit's player view
/// (SwiftUI's `VideoPlayer` fails to load outside an app bundle), and keeps
/// the item's playhead.
struct PlayerView: View {
    let request: PlayRequest
    @Environment(Library.self) private var library

    var body: some View {
        Player(request: request, library: library)
            .frame(minWidth: 640, minHeight: 360)
            .navigationTitle(request.url.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? "Player")
    }
}

private struct Player: NSViewRepresentable {
    let request: PlayRequest
    let library: Library

    final class Coordinator {
        var observer: Any?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.allowsPictureInPicturePlayback = true
        let player = AVPlayer(url: request.url)
        view.player = player
        if request.start > 0 {
            player.seek(to: CMTime(seconds: request.start, preferredTimescale: 600))
        }
        player.play()
        // Save the playhead every 10 seconds of playing.
        let item = request.item
        let library = library
        context.coordinator.observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 1), queue: .main) { [weak player] time in
            guard let player, player.rate != 0, let duration = player.currentItem?.duration.seconds else { return }
            MainActor.assumeIsolated { library.setPlayhead(item, position: time.seconds, duration: duration) }
        }
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        guard let player = view.player else { return }
        if let observer = coordinator.observer { player.removeTimeObserver(observer) }
        player.pause()
    }
}
