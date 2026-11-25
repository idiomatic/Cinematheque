#if os(iOS)
import AVKit
import SwiftUI

/// A movie's page, or a season's: its cover, Play or Resume (Start Over
/// before it, partway), the quality, the Lists menu and watched mark, and a
/// movie's versions or a season's episodes, each playable; a season's
/// neighbors (‹ ›) in the navigation bar.
struct TitlePage: View {
    let tile: Tile
    @Environment(Library.self) private var library
    @State private var detail: TitleDetail?
    /// The season shown, moved to its neighbors in place.
    @State private var season: Int?
    @State private var quality: String?
    @State private var playing: PlayRequest?

    var body: some View {
        let seasons = tile.isSeries ? Library.seasons(of: tile.key, in: library.tiles) : []
        let index = seasons.firstIndex { $0.season == (season ?? tile.season) }
        let shown = index.map { seasons[$0] } ?? tile
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                CoverImage(cover: shown.cover, aspect: shown.aspect, title: shown.name, size: .large, shaped: true)
                    .clipShape(.rect(cornerRadius: 12))
                    .frame(maxHeight: 280)
                    .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 4) {
                    Text(shown.name).font(.title2.bold())
                    if let name = shown.seasonName { Text(name).font(.headline).foregroundStyle(.secondary) }
                }
                if let detail {
                    let items = Playback.items(detail, season: shown.season)
                    let next = Playback.nextItem(detail, season: shown.season)
                    Text(detail.facts(season: shown.season)).font(.subheadline).foregroundStyle(.secondary)
                    HStack {
                        Button {
                            playing = Playback.next(in: detail, season: shown.season, quality: quality)
                        } label: {
                            Label(Playback.playLabel(next, in: detail, quality: quality), systemImage: "play.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        if next?.inProgress == true {
                            Button("Start Over", systemImage: Playback.startOverSymbol) {
                                playing = Playback.next(in: detail, season: shown.season, quality: quality)?.fromBeginning
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.bordered)
                        }
                    }
                    .controlSize(.large)
                    HStack(spacing: 20) {
                        QualityPicker(detail: detail, items: items, chosen: $quality)
                        Spacer()
                        Marks(detail: detail, items: items, season: shown.season).labelStyle(.iconOnly)
                    }
                    if let description = shown.isSeries ? detail.fields["description"] : detail.summary {
                        Text(description).font(.callout)
                    }
                    if !shown.isSeries && items.count <= 1 {
                        EmptyView()
                    } else {
                        Text(shown.isSeries ? "Episodes" : "Versions").font(.headline)
                        VStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                Button {
                                    playing = Playback.request(detail, items: shown.isSeries ? items : [item], from: shown.isSeries ? index : 0, quality: detail.quality(for: items, chosen: quality))
                                } label: {
                                    ItemLine(item: item, widest: items.widestRuntime)
                                        .padding(.vertical, 10)
                                        .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                                Divider()
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if seasons.count > 1, let index {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Previous Season", systemImage: "chevron.backward") { season = seasons[index - 1].season }
                        .disabled(index == 0)
                    Button("Next Season", systemImage: "chevron.forward") { season = seasons[index + 1].season }
                        .disabled(index + 1 == seasons.count)
                }
            }
        }
        .task(id: library.detailsRevision) {
            detail = library.detail(tile.key)
        }
        .task(id: shown.season) { if shown.isSeries { await library.describeItems(of: tile.key, season: shown.season) } }
        // A copy Apple's player can't play goes to VLC, if it's installed,
        // and no cover shows.
        .fullScreenCover(item: Binding(get: { playing.flatMap { VLC.takes($0) ? nil : $0 } }, set: { playing = $0 })) { PhonePlayer(request: $0) }
        .onChange(of: playing) { if let request = playing, VLC.handOff(request) { playing = nil } }
    }
}

extension PlayRequest: Identifiable {
    var id: Self { self }
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
