#if os(macOS)
import AVKit
import SwiftUI

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
        var session: PlaybackSession?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.allowsPictureInPicturePlayback = true
        let session = PlaybackSession(request: request, library: library)
        let title = $title
        session.onItem = { title.wrappedValue = $0.title }
        view.player = session.player
        session.play()
        context.coordinator.session = session
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}

    // Closing the window stops it where it is.
    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        coordinator.session?.close()
    }
}
#endif
