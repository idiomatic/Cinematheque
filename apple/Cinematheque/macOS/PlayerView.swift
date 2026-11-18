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
    @State private var lastMove = Date.distantPast

    var body: some View {
        Player(request: request, library: library, title: $title, finished: close) {
            lastMove = .now
            showsBack = true
        }
            .ignoresSafeArea()
            .task(id: lastMove) {
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled, !onBack { showsBack = false }
            }
            .overlay(alignment: .topLeading) {
                // On a material, to show over any picture; still there,
                // unseen, for Escape.
                Button(action: close) {
                    Label("Back", systemImage: "chevron.backward")
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Back to the library (Escape)")
                .onHover { onBack = $0 }
                .padding(16)
                .opacity(showsBack ? 1 : 0)
                .allowsHitTesting(showsBack)
                .animation(.easeInOut(duration: 0.25), value: showsBack)
            }
            .background(HidesToolbar())
            .navigationTitle(title.isEmpty ? request.title : title)
            .background(.black)
    }
}

/// Hides its window's toolbar, and its title bar's title and background,
/// while it's there, keeping the window's buttons over the picture (which
/// SwiftUI's hiding a toolbar takes with it).
private struct HidesToolbar: NSViewRepresentable {
    final class Coordinator {
        weak var window: NSWindow?
        /// The title bar as it was, to put back.
        var transparent = false
        var title = NSWindow.TitleVisibility.visible
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window, context.coordinator.window == nil else { return }
            context.coordinator.window = window
            context.coordinator.transparent = window.titlebarAppearsTransparent
            context.coordinator.title = window.titleVisibility
            window.toolbar?.isVisible = false
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        guard let window = coordinator.window else { return }
        window.toolbar?.isVisible = true
        window.titlebarAppearsTransparent = coordinator.transparent
        window.titleVisibility = coordinator.title
    }
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

/// AppKit's player view, taking the keyboard as it appears: Space plays or
/// pauses, F toggles full screen, M mutes, and the left and right arrows
/// skip back and forward 10 seconds. It tells of the pointer's
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
        default: return false
        }
        return true
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
