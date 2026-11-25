#if os(iOS)
import AVKit
import SwiftUI

/// Plays a request full screen, in a cover of its own (`PhonePlayer`), as
/// the Apple TV's `PlaysFullScreen` does; a copy Apple's player can't play
/// goes to VLC, if it's installed, and no cover shows.
struct PlaysFullScreen: ViewModifier {
    @Binding var request: PlayRequest?

    func body(content: Content) -> some View {
        content
            .fullScreenCover(item: Binding(get: { request.flatMap { VLC.takes($0) ? nil : $0 } }, set: { request = $0 })) { PhonePlayer(request: $0) }
            .onChange(of: request) { if let asked = request, VLC.handOff(asked) { request = nil } }
    }
}

/// Playing, full screen, in the system's player: black while the stream
/// warms up, paused, then its picture fading in as its sound rises; its
/// close button lowers the curtain, then closes.
private struct PhonePlayer: View {
    let request: PlayRequest
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var curtain = Curtain()
    @State private var session: PlaybackSession?

    var body: some View {
        FadingIn(fadesToBlack: false, curtain: curtain) {
            if let session { PlayerController(player: session.player) }
        }
        .ignoresSafeArea()
        // The inline player has no Done of its own.
        .overlay(alignment: .topLeading) {
            Button("Close", systemImage: "xmark", action: leave)
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .tint(.white)
                .padding()
        }
        .statusBarHidden()
        .task {
            let session = PlaybackSession(request: request, library: library)
            self.session = session
            curtain.session = session
            if await session.begin() {
                curtain.raise()
            } else {
                leave()
            }
        }
    }

    private func leave() {
        curtain.lower {
            session?.close()
            dismiss()
        }
    }
}

/// AVKit's player view controller, inline, as a full screen cover holds it.
private struct PlayerController: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}
}
#endif
