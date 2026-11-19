#if os(tvOS)
import AVKit
import os
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

    func body(content: Content) -> some View {
        content
            // Past the page's edges, over the backdrop it draws beyond them.
            .overlay { Color.black.opacity(black ? 1 : 0).padding(-400).ignoresSafeArea().allowsHitTesting(false) }
            // The tab bar, above the page, goes as it fades.
            .toolbar(black ? .hidden : .automatic, for: .tabBar)
            // Started on a change of the request, in a task of its own, not
            // the view's: fading the page hides the tab bar, which re-hosts
            // the page, and SwiftUI restarts a view's task when it does,
            // which started every request twice.
            // Not `initial`: that fires again as the page reappears (the
            // player dismissed), which, its request not yet cleared, started
            // it over.
            .onChange(of: request) { _, asked in
                PlaybackSession.log.notice("Asked to play \(asked?.item ?? "nothing", privacy: .public)\(warming ? ", while starting" : "", privacy: .public)")
                // Pressing Play again over the black (focus stays on the
                // page's Play beneath it) doesn't start it over.
                guard asked == nil || !warming else { return }
                starting?.cancel()
                starting = asked.map { request in Task { await start(request) } }
            }
    }

    @State private var starting: Task<Void, Never>?
    /// From Play until the player's on screen.
    @State private var warming = false

    private func start(_ request: PlayRequest) async {
        PlaybackSession.log.notice("Playing \(request.item, privacy: .public)")
        warming = true
        defer { warming = false }
        withAnimation(.easeInOut(duration: Platform.fade)) { black = true }
        // The fade first, with the main thread free to draw it: making the
        // session (the series' details, a player item an episode), done
        // during it, held the fade, which ended in black at once.
        try? await Task.sleep(for: .seconds(Platform.fade))
        guard !Task.isCancelled else { return }
        let clock = ContinuousClock()
        let making = clock.now
        let artwork = await TVPlayer.artwork(request, library)
        let session = TVPlayer.session(request, library, artwork: artwork)
        PlaybackSession.log.notice("Playing: made the session in \((clock.now - making).formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)), privacy: .public)")
        // Superseded, it stops loading at once.
        await withTaskCancellationHandler {
            await session.prepare()
        } onCancel: {
            Task { @MainActor in session.close() }
        }
        guard !Task.isCancelled else { return session.close() }
        TVPlayer.present(session, dismissed: { self.request = nil }) {
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
/// session where it is. Presented by UIKit, not SwiftUI: AVKit adds views
/// of its own (snapshots, as its controls animate) beside the player's,
/// which SwiftUI's hosting view doesn't take. Its curtain is a black view
/// in the player's content overlay, over the picture and under the
/// controls.
@MainActor
final class TVPlayer: NSObject, AVPlayerViewControllerDelegate {
    private let session: PlaybackSession
    private let controller = AVPlayerViewController()
    private let curtain = UIView()
    /// Once it's gone, and the page can come back.
    private let dismissed: () -> Void
    private let gone: () -> Void
    /// The window whose display mode it asked for, to give back.
    private weak var window: UIWindow?
    private var leaving = false
    /// The one shown, kept while it is.
    private static var shown: TVPlayer?

    private init(session: PlaybackSession, dismissed: @escaping () -> Void, gone: @escaping () -> Void) {
        self.session = session
        self.dismissed = dismissed
        self.gone = gone
        super.init()
        controller.delegate = self
        // The display's mode is matched to the video here, while it's paused
        // and black, rather than by the player once it plays, which would
        // lose the seconds the switch blanks the screen.
        controller.appliesPreferredDisplayCriteriaAutomatically = false
        session.player.volume = 0
    }

    /// Once it's on screen (its views made in its window, not before, which
    /// UIKit would build without a scene): its curtain, down, then the video.
    /// Black until then, over a page already black.
    private func attach() {
        if let overlay = controller.contentOverlayView {
            curtain.backgroundColor = .black
            curtain.frame = overlay.bounds
            curtain.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            overlay.addSubview(curtain)
        }
        controller.player = session.player
    }

    /// Presents a player over whatever's frontmost, unanimated; `gone` once
    /// it's left.
    /// `dismissed` once it's off screen (the page beneath still black);
    /// `gone` once the display has its own mode back, to fade the page in.
    static func present(_ session: PlaybackSession, dismissed: @escaping () -> Void, gone: @escaping () -> Void) {
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        guard var top = window?.rootViewController else {
            session.close()
            dismissed()
            return gone()
        }
        while let presented = top.presentedViewController { top = presented }
        let player = TVPlayer(session: session, dismissed: dismissed, gone: gone)
        shown = player
        // The display switches to the video's mode first, over the black
        // page (the window's to ask, not the player's): presented only then,
        // ready, the player has nothing to show its spinner for.
        Task {
            if let window { await player.matchDisplay(window) }
            top.present(player.controller, animated: false) {
                player.attach()
                Task { await player.start() }
            }
        }
    }

    private func start() async {
        session.play()
        // The picture and its sound come up once it plays, not when it's
        // asked to: a stall in between would have the sound ramp up in
        // silence, then arrive at once.
        let clock = ContinuousClock()
        let asked = clock.now
        while session.player.timeControlStatus != .playing, clock.now - asked < .seconds(5), !leaving {
            try? await Task.sleep(for: .milliseconds(20))
        }
        session.ramp(to: 1, over: .seconds(Platform.fade))
        UIView.animate(withDuration: Platform.fade, delay: 0, options: .curveEaseIn) { self.curtain.alpha = 0 }
    }

    /// Loads AVFoundation and AVKit, as the shelves first show, rather
    /// than as the first play's page fades, which stuttered.
    static func warmUp() {
        _ = AVPlayerViewController()
        _ = AVQueuePlayer()
    }

    /// Leaves it: the picture fades to black as the sound falls, then it
    /// goes, stopped where it is, and the display gets its own mode back.
    private func leave() {
        guard !leaving else { return }
        leaving = true
        session.ramp(to: 0, over: .seconds(Platform.fade))
        UIView.animate(withDuration: Platform.fade, delay: 0, options: .curveEaseOut) {
            self.curtain.alpha = 1
        } completion: { _ in
            // Stopped while it's black, its controls hidden first, so the
            // player has nothing to show: detached, it showed its spinner
            // and controls for a moment.
            self.controller.showsPlaybackControls = false
            // The display's own mode asked for first, while it's black, so
            // its switch (some 3 seconds) covers stopping (saving where it
            // stopped, half a second) and going.
            let switching = self.restoreDisplay()
            self.session.close()
            PlaybackSession.log.notice("Leaving: faded and stopped")
            self.controller.dismiss(animated: false) {
                self.dismissed()
                Task { @MainActor in
                    // The switch (which blanks the screen) done before the
                    // page fades in, rather than under it, which left the
                    // page simply there.
                    await switching?()
                    PlaybackSession.log.notice("Left")
                    Self.shown = nil
                    self.gone()
                }
            }
        }
    }

    /// Gives the display back its own mode, if it was switched, at once;
    /// returns a wait for the switch to end (up to half a second to start,
    /// five to end), if there's one.
    private func restoreDisplay() -> (() async -> Void)? {
        guard let window else { return nil }
        let manager = window.avDisplayManager
        guard manager.preferredDisplayCriteria != nil else { return nil }
        let clock = ContinuousClock()
        let asked = clock.now
        manager.preferredDisplayCriteria = nil
        return {
            while !manager.isDisplayModeSwitchInProgress, clock.now - asked < .milliseconds(500) { try? await Task.sleep(for: .milliseconds(50)) }
            while manager.isDisplayModeSwitchInProgress, clock.now - asked < .seconds(5) { try? await Task.sleep(for: .milliseconds(50)) }
            PlaybackSession.log.notice("Leaving: gave the display back its mode in \((clock.now - asked).formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)), privacy: .public)")
        }
    }

    // Menu (Back) leaves through the curtain, not at once.
    nonisolated func playerViewControllerShouldDismiss(_ controller: AVPlayerViewController) -> Bool {
        MainActor.assumeIsolated { leave() }
        return false
    }

    /// Asks the display for the video's frame rate and dynamic range (as
    /// Match Content does, if it's on), and waits for it to switch, if it
    /// does: up to half a second for the switch to start, and five for it
    /// to end.
    private func matchDisplay(_ window: UIWindow) async {
        let clock = ContinuousClock()
        let start = clock.now
        defer { PlaybackSession.log.notice("Starting: matched the display in \((clock.now - start).formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)), privacy: .public)") }
        guard let asset = session.player.currentItem?.asset else { return }
        let manager = window.avDisplayManager
        guard manager.isDisplayCriteriaMatchingEnabled, let criteria = try? await asset.load(.preferredDisplayCriteria) else { return }
        self.window = window
        manager.preferredDisplayCriteria = criteria
        let asked = clock.now
        while !manager.isDisplayModeSwitchInProgress, clock.now - asked < .milliseconds(500) { try? await Task.sleep(for: .milliseconds(50)) }
        while manager.isDisplayModeSwitchInProgress, clock.now - asked < .seconds(5) { try? await Task.sleep(for: .milliseconds(50)) }
    }

    /// A session for `request`, its items described for the info panel.
    @MainActor static func session(_ request: PlayRequest, _ library: Library, artwork: Data?) -> PlaybackSession {
        let descriptions = descriptions(request, library)
        return PlaybackSession(request: request, library: library) { playerItem, entry in
            playerItem.externalMetadata = metadata(title: entry.title, description: descriptions[entry.item], artwork: artwork)
        }
    }

    /// The cover of what's playing (a movie's, or the season's), as JPEG,
    /// for the info panel and Now Playing, which asks for it; none if it
    /// takes longer than the page's fade to come (from the cover cache, it
    /// doesn't).
    @MainActor static func artwork(_ request: PlayRequest, _ library: Library) async -> Data? {
        guard let cut = request.item.range(of: "/v/") ?? request.item.range(of: "/e/") else { return nil }
        let key = String(request.item[..<cut.lowerBound])
        let season = request.item[cut.upperBound...].hasPrefix("s") ? Int(request.item[cut.upperBound...].dropFirst().prefix(2)) : nil
        let id = season.map { "\(key)#\($0)" } ?? key
        guard let cover = (library.tiles.first { $0.id == id } ?? library.tiles.first { $0.key == key })?.cover else { return nil }
        return await withTaskGroup(of: Data?.self) { group in
            group.addTask { await ArtCache.shared.image(cover, .large).flatMap { UIImage(cgImage: $0).jpegData(compressionQuality: 0.8) } }
            group.addTask { try? await Task.sleep(for: .seconds(Platform.fade)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
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

    private static func metadata(title: String, description: String?, artwork: Data?) -> [AVMetadataItem] {
        func item(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            item.extendedLanguageTag = "und"
            return item.copy() as! AVMetadataItem
        }
        var items = [item(.commonIdentifierTitle, title)] + (description.map { [item(.commonIdentifierDescription, $0)] } ?? [])
        if let artwork {
            let art = AVMutableMetadataItem()
            art.identifier = .commonIdentifierArtwork
            art.value = artwork as NSData
            art.dataType = kCMMetadataBaseDataType_JPEG as String
            art.extendedLanguageTag = "und"
            items.append(art.copy() as! AVMetadataItem)
        }
        return items
    }
}
#endif
