import SwiftUI

/// Playback's curtain, over its picture and its sound: down (black, and
/// silent) while the stream warms up; raised once it plays, the picture
/// fading in as the sound rises; and lowered as playback is left, before
/// what follows; each over `Platform.fade`.
@MainActor @Observable
final class Curtain {
    private(set) var raised = false
    /// The sound to raise and lower with the picture.
    @ObservationIgnored weak var session: PlaybackSession?

    func raise() {
        session?.ramp(to: 1, over: .seconds(Platform.fade))
        withAnimation(.easeIn(duration: Platform.fade)) { raised = true }
    }

    func lower(then next: @escaping () -> Void) {
        guard raised else { return next() }
        session?.ramp(to: 0, over: .seconds(Platform.fade))
        withAnimation(.easeOut(duration: Platform.fade)) { raised = false } completion: { next() }
    }
}

/// How playback starts, on every platform: the screen fades to black
/// (`Platform.fade`) while the stream warms up, paused, its curtain down; `player`
/// makes the player, which raises the curtain once it plays.
struct FadingIn<Player: View>: View {
    /// Whether to fade to black, over what's behind; a new window starts
    /// black instead.
    var fadesToBlack = true
    let curtain: Curtain
    @ViewBuilder let player: () -> Player
    @State private var black = false

    var body: some View {
        ZStack {
            Color.black.opacity(black || !fadesToBlack ? 1 : 0)
            player().opacity(curtain.raised ? 1 : 0)
        }
        .onAppear { withAnimation(.easeInOut(duration: Platform.fade)) { black = true } }
    }
}
