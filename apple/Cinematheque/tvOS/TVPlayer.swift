#if os(tvOS)
import AVKit
import SwiftUI
import UIKit

extension PlayRequest: Identifiable {
    var id: Self { self }
}

/// How the Apple TV plays: the page fades to black (`Platform.fade`) while
/// the session warms up, paused; then the system's player is presented over
/// it, unanimated (black over black, were it animated), still paused,
/// while the display switches to the video's mode (Match Content), which
/// blanks the screen; then it plays, its picture fading in as its sound
/// rises (replaying `Platform.replay` before where it was left). Leaving it
/// (Menu, or Back) fades it to black as its sound falls, then the page
/// fades back in; each fade over `Platform.fade`.
struct PlaysFullScreen: ViewModifier {
    @Binding var request: PlayRequest?
    @Environment(Library.self) private var library
    @State private var black = false
    @State private var ready: Ready?

    /// A session warmed up, to present, and its curtain.
    struct Ready: Identifiable {
        let session: PlaybackSession
        let curtain: Curtain
        var id: ObjectIdentifier { ObjectIdentifier(session) }
    }

    func body(content: Content) -> some View {
        content
            // Past the page's edges, over the backdrop it draws beyond them.
            .overlay { Color.black.opacity(black ? 1 : 0).padding(-400).ignoresSafeArea().allowsHitTesting(false) }
            // The tab bar, above the page, goes as it fades.
            .toolbar(black ? .hidden : .automatic, for: .tabBar)
            .task(id: request) {
                guard let request else { return }
                let session = TVPlayer.session(request, library)
                withAnimation(.easeInOut(duration: Platform.fade)) { black = true }
                let faded = ContinuousClock.now + .seconds(Platform.fade)
                await session.prepare()
                try? await Task.sleep(until: faded, clock: .continuous)
                guard !Task.isCancelled else { return session.close() }
                var unanimated = Transaction()
                unanimated.disablesAnimations = true
                let curtain = Curtain()
                curtain.session = session
                withTransaction(unanimated) { ready = Ready(session: session, curtain: curtain) }
            }
            .fullScreenCover(item: $ready, onDismiss: {
                request = nil
                // Gone some other way than `leave`, which fades the page in.
                if black { reveal() }
            }) { shown in
                FadingIn(fadesToBlack: false, curtain: shown.curtain) {
                    TVPlayer(session: shown.session, curtain: shown.curtain) { leave(shown) }
                }
                .ignoresSafeArea()
                // Menu (Back) leaves through the curtain, not at once.
                .interactiveDismissDisabled()
                .onExitCommand { leave(shown) }
            }
    }

    /// Leaves playback: its picture fades to black as its sound falls,
    /// then the player goes, over the black page, which fades back in.
    private func leave(_ shown: Ready) {
        shown.curtain.lower {
            var unanimated = Transaction()
            unanimated.disablesAnimations = true
            withTransaction(unanimated) { ready = nil }
            reveal()
        }
    }

    /// Fades the page back in from black, once the player
    /// has gone from over it.
    private func reveal() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            withAnimation(.easeOut(duration: Platform.fade)) { black = false }
        }
    }
}

/// The system's player, full screen, over a session warmed up, its info
/// panel showing each item's title and description; leaving it stops the
/// session where it is.
struct TVPlayer: UIViewControllerRepresentable {
    let session: PlaybackSession
    /// Raised once it plays.
    let curtain: Curtain
    /// Leaves it, as Menu (Back) does.
    let leave: () -> Void

    @MainActor
    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        var session: PlaybackSession?
        var leave: () -> Void = {}
        /// The window whose display mode it asked for, to give back.
        weak var window: UIWindow?

        // Menu (Back) leaves through the curtain, not at once.
        func playerViewControllerShouldDismiss(_ controller: AVPlayerViewController) -> Bool {
            leave()
            return false
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = session.player
        controller.delegate = context.coordinator
        // The display's mode is matched to the video here, while it's paused
        // and black, rather than by the player once it plays, which would
        // lose the seconds the switch blanks the screen.
        controller.appliesPreferredDisplayCriteriaAutomatically = false
        session.player.volume = 0
        context.coordinator.session = session
        context.coordinator.leave = leave
        let curtain = curtain
        let coordinator = context.coordinator
        Task { @MainActor in
            await Self.matchDisplay(controller, session, coordinator)
            session.play()
            curtain.raise()
        }
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}

    // Leaving it stops it where it is, keeping the progress, and gives
    // the display back its own mode.
    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.session?.close()
        coordinator.window?.avDisplayManager.preferredDisplayCriteria = nil
    }

    /// Asks the display for the video's frame rate and dynamic range (as
    /// Match Content does, if it's on), and waits for it to switch, if it
    /// does: up to half a second for the switch to start, and five for it
    /// to end.
    private static func matchDisplay(_ controller: AVPlayerViewController, _ session: PlaybackSession, _ coordinator: Coordinator) async {
        let clock = ContinuousClock()
        let start = clock.now
        while controller.view.window == nil, clock.now - start < .seconds(1) { try? await Task.sleep(for: .milliseconds(20)) }
        guard let window = controller.view.window, let asset = session.player.currentItem?.asset else { return }
        let manager = window.avDisplayManager
        guard manager.isDisplayCriteriaMatchingEnabled, let criteria = try? await asset.load(.preferredDisplayCriteria) else { return }
        coordinator.window = window
        manager.preferredDisplayCriteria = criteria
        let asked = clock.now
        while !manager.isDisplayModeSwitchInProgress, clock.now - asked < .milliseconds(500) { try? await Task.sleep(for: .milliseconds(50)) }
        while manager.isDisplayModeSwitchInProgress, clock.now - asked < .seconds(5) { try? await Task.sleep(for: .milliseconds(50)) }
    }

    /// A session for `request`, its items described for the info panel.
    @MainActor static func session(_ request: PlayRequest, _ library: Library) -> PlaybackSession {
        let descriptions = descriptions(request, library)
        return PlaybackSession(request: request, library: library) { playerItem, entry in
            playerItem.externalMetadata = metadata(title: entry.title, description: descriptions[entry.item])
        }
    }

    /// Each queued item's description (an episode's, else its title's).
    private static func descriptions(_ request: PlayRequest, _ library: Library) -> [String: String] {
        let first = request.first
        var out: [String: String] = [:]
        var details: [String: TitleDetail] = [:]
        for entry in [first] + request.queue {
            // An item key is its title's key, then `/v/` or `/e/`.
            guard let cut = entry.item.range(of: "/v/") ?? entry.item.range(of: "/e/") else { continue }
            let titleKey = String(entry.item[..<cut.lowerBound])
            let itemKey = String(entry.item[entry.item.index(after: cut.lowerBound)...])
            if details[titleKey] == nil { details[titleKey] = library.detail(titleKey) }
            let detail = details[titleKey]
            out[entry.item] = detail?.items.first { $0.key == itemKey }?.fields["description"] ?? detail?.fields["description"]
        }
        return out
    }

    private static func metadata(title: String, description: String?) -> [AVMetadataItem] {
        func item(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            item.extendedLanguageTag = "und"
            return item.copy() as! AVMetadataItem
        }
        return [item(.commonIdentifierTitle, title)] + (description.map { [item(.commonIdentifierDescription, $0)] } ?? [])
    }
}
#endif
