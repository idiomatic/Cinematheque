#if os(macOS)
import AVKit
import SwiftUI

/// Where Play plays: in the library's window, filling it, or with ⌘ held,
/// in a window of its own.
struct PlayAction {
    let inWindow: (PlayRequest) -> Void
    let newWindow: (PlayRequest) -> Void

    @MainActor func callAsFunction(_ request: PlayRequest) {
        if NSEvent.modifierFlags.contains(.command) { newWindow(request) } else { inWindow(request) }
    }
}

extension EnvironmentValues {
    @Entry var play = PlayAction(inWindow: { _ in }, newWindow: { _ in })
}

/// Playing in the library's window, filling it, over the browser (which
/// keeps its place): Back, or Escape, or the queue's end, returns to it.
struct WindowPlayer: View {
    let request: PlayRequest
    let close: () -> Void
    @Environment(Library.self) private var library
    @State private var title = ""
    /// Back shows, as the player's own controls do, while the pointer moves
    /// over the picture, and for 3 seconds after, or while it rests on Back.
    @State private var showsBack = false
    @State private var onBack = false
    /// How far below the window's top its buttons' centers are, which the
    /// row's text centers on.
    @State private var buttonsMid: CGFloat = 14
    @State private var lastMove = Date.distantPast
    @State private var curtain = Curtain()

    var body: some View {
        FadingIn(curtain: curtain) {
            Player(request: request, library: library, title: $title, finished: leave, curtain: curtain) {
                lastMove = .now
                showsBack = true
            }
        }
            .ignoresSafeArea()
            .task(id: lastMove) {
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled, !onBack { showsBack = false }
            }
            .overlay(alignment: .top) {
                // The title bar's row, as QuickTime Player's: the window's
                // buttons (faded with it, by HidesToolbar), Back, and what's
                // playing after it, where macOS puts a window's title, over a
                // gradient to read over any picture; still there, unseen, for
                // Escape.
                ZStack(alignment: .top) {
                    LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 72)
                        .allowsHitTesting(false)
                    ZStack {
                        HStack(spacing: 6) {
                            Button(action: leave) {
                                Label("Back", systemImage: "chevron.backward")
                                    // The size of a window's title.
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .keyboardShortcut(.cancelAction)
                            .help("Back to the library (Escape)")
                            .onHover { onBack = $0 }
                            NowPlaying(title: title.isEmpty ? request.title : title)
                            Spacer(minLength: 16)
                        }
                        // Past the window's buttons.
                        .padding(.leading, 76)
                    }
                    .frame(height: buttonsMid * 2)
                }
                // In the title bar's row, not beneath it.
                .ignoresSafeArea()
                .opacity(showsBack ? 1 : 0)
                .allowsHitTesting(showsBack)
                .animation(.easeInOut(duration: 0.25), value: showsBack)
            }
            .background(HidesToolbar(showsButtons: showsBack, buttonsMid: $buttonsMid))
            .navigationTitle(title.isEmpty ? request.title : title)
    }

    /// Leaves playback, its picture fading to black as its sound falls,
    /// then for the library.
    private func leave() {
        curtain.lower(then: close)
    }
}

/// What's playing, as a window's title says it, in its place after Back:
/// a movie's name, or a series' with the episode (its code and name) after
/// it, as `Playback.name` joins them, in one weight.
private struct NowPlaying: View {
    let title: String

    var body: some View {
        Text(title)
            // A window's title's size and weight.
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .truncationMode(.tail)
            .shadow(color: .black.opacity(0.4), radius: 2)
            .allowsHitTesting(false)
    }
}

/// Hides its window's toolbar, and its title bar's title and background,
/// while it's there, keeping the window's buttons over the picture (which
/// SwiftUI's hiding a toolbar takes with it). SwiftUI may show the toolbar
/// or title again as it updates the window (its title showing over the
/// picture), so it watches them, and hides them again at once.
private struct HidesToolbar: NSViewRepresentable {
    /// Whether the window's buttons show, fading as playback's controls do.
    let showsButtons: Bool
    /// How far below the window's top its buttons' centers are, as the
    /// window lays them out (not a guess at the title bar's height).
    @Binding var buttonsMid: CGFloat

    private static let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

    @MainActor
    final class Coordinator {
        weak var window: NSWindow?
        /// The title bar as it was, to put back.
        var transparent = false
        var title = NSWindow.TitleVisibility.visible
        var watching: [NSKeyValueObservation] = []

        func hide() {
            guard let window, !watching.isEmpty else { return }
            if window.toolbar?.isVisible == true { window.toolbar?.isVisible = false }
            if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
            if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            if coordinator.window == nil {
                coordinator.window = window
                coordinator.transparent = window.titlebarAppearsTransparent
                coordinator.title = window.titleVisibility
                // Ended (breaking the cycle) when playback is.
                let again: @Sendable () -> Void = { Task { @MainActor in coordinator.hide() } }
                coordinator.watching = [
                    window.observe(\.titleVisibility) { _, _ in again() },
                    window.observe(\.titlebarAppearsTransparent) { _, _ in again() },
                    window.observe(\.toolbar) { _, _ in again() },
                ]
                if let toolbar = window.toolbar {
                    coordinator.watching.append(toolbar.observe(\.isVisible) { _, _ in again() })
                }
            }
            coordinator.hide()
            if let close = window.standardWindowButton(.closeButton), close.window != nil {
                let center = close.convert(NSPoint(x: close.bounds.midX, y: close.bounds.midY), to: nil)
                let mid = (window.frame.height - center.y).rounded()
                if abs(mid - buttonsMid) >= 0.5 { buttonsMid = mid }
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                for type in Self.buttons { window.standardWindowButton(type)?.animator().alphaValue = showsButtons ? 1 : 0 }
            }
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.watching = []
        guard let window = coordinator.window else { return }
        for type in buttons { window.standardWindowButton(type)?.alphaValue = 1 }
        window.toolbar?.isVisible = true
        window.titlebarAppearsTransparent = coordinator.transparent
        window.titleVisibility = coordinator.title
    }
}

/// Plays copies straight from their sources, in AppKit's player view,
/// one after another, keeping each item's progress.
struct PlayerView: View {
    let request: PlayRequest
    @Environment(Library.self) private var library
    @State private var title = ""
    @State private var curtain = Curtain()

    var body: some View {
        FadingIn(fadesToBlack: false, curtain: curtain) {
            Player(request: request, library: library, title: $title, curtain: curtain)
        }
            .frame(minWidth: 640, minHeight: 360)
            .navigationTitle(title.isEmpty ? (request.url.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? "Player") : title)
            .onAppear { title = request.title }
    }
}

/// AppKit's player view, taking the keyboard as it appears: Space plays or
/// pauses, F toggles full screen, M mutes, C toggles captions, and the left
/// and right arrows skip back and forward 10 seconds. It tells of the pointer's
/// moving over it itself, since SwiftUI's hover tracking over it keeps its
/// own controls from showing.
private final class KeyedPlayerView: AVPlayerView {
    var moved: (() -> Void)?
    private var tracking: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        moved?()
    }

    /// Its window's keys, taken before its views do: AppKit's player view
    /// handles some (the arrows, a frame at a time) in a view of its own.
    private var keys: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keys { NSEvent.removeMonitor(keys) }
        keys = nil
        guard window != nil else { return }
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, self.handle(event) else { return event }
            return nil
        }
        // After SwiftUI settles its own focus (e.g., the grid's).
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    /// Handles a key the player takes, returning whether it did.
    private func handle(_ event: NSEvent) -> Bool {
        guard let player, event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch event.specialKey {
        case .leftArrow?:
            skip(player, by: -10)
            return true
        case .rightArrow?:
            skip(player, by: 10)
            return true
        default: break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case " ": if player.rate == 0 { player.play() } else { player.pause() }
        case "f": window?.toggleFullScreen(nil)
        case "m": player.isMuted.toggle()
        case "c": toggleCaptions(player)
        default: return false
        }
        return true
    }

    /// Turns captions on, in the languages preferred (the rest of the queue
    /// too), or off; beeps if the item has none.
    private func toggleCaptions(_ player: AVPlayer) {
        guard let item = player.currentItem else { return }
        Task { @MainActor in
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible), !group.options.isEmpty else {
                NSSound.beep()
                return
            }
            let on = item.currentMediaSelection.selectedMediaOption(in: group) == nil
            if on {
                let preferred = AVMediaSelectionGroup.mediaSelectionOptions(from: group.options, filteredAndSortedAccordingToPreferredLanguages: Locale.preferredLanguages)
                item.select(preferred.first ?? group.options.first, in: group)
                player.setMediaSelectionCriteria(AVPlayerMediaSelectionCriteria(preferredLanguages: Locale.preferredLanguages, preferredMediaCharacteristics: [.legible]), forMediaCharacteristic: .legible)
            } else {
                item.select(nil, in: group)
                player.setMediaSelectionCriteria(nil, forMediaCharacteristic: .legible)
            }
        }
    }

    /// Skips `seconds` back or forward, within the item.
    private func skip(_ player: AVPlayer, by seconds: Double) {
        let now = player.currentTime().seconds
        let duration = player.currentItem?.duration.seconds ?? .infinity
        let to = min(max(0, now + seconds), duration.isFinite ? duration : .infinity)
        player.seek(to: CMTime(seconds: to, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

private struct Player: NSViewRepresentable {
    let request: PlayRequest
    let library: Library
    @Binding var title: String
    var finished: (() -> Void)? = nil
    /// Raised once it plays, warmed up.
    let curtain: Curtain
    var moved: (() -> Void)? = nil

    @MainActor
    final class Coordinator {
        var session: PlaybackSession?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = KeyedPlayerView()
        view.moved = moved
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        let session = PlaybackSession(request: request, library: library)
        let title = $title
        session.onItem = { title.wrappedValue = $0.title }
        session.onFinished = finished
        view.player = session.player
        curtain.session = session
        let curtain = curtain
        // Raised even if it couldn't load, so AVKit says why, not a black window.
        Task { _ = await session.begin(); curtain.raise() }
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
