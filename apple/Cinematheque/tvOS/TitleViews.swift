#if os(tvOS)
import SwiftUI

/// A season's neighbors in its page's top corner, by name with a chevron;
/// at the series' end, the chevron alone, dimmed, focus moving to the
/// other, as a dimmed button kept it.
struct Neighbors: View {
    let back: Tile?
    let forward: Tile?
    let go: (Int?) -> Void
    @FocusState private var focus: Direction?

    var body: some View {
        Neighbor(season: back, direction: .back, go: go)
            .focused($focus, equals: .back)
        Neighbor(season: forward, direction: .forward, go: go)
            .focused($focus, equals: .forward)
            .onChange(of: [back, forward]) {
                if focus == .forward, forward == nil { focus = .back }
                if focus == .back, back == nil { focus = .forward }
            }
    }
}

private enum Direction: Hashable { case back, forward }

/// The season before or after, by name, with a chevron, or the chevron
/// alone, dimmed.
private struct Neighbor: View {
    let season: Tile?
    let direction: Direction
    let go: (Int?) -> Void

    var body: some View {
        Button { go(season?.season) } label: {
            switch (direction, season?.seasonName) {
            case (.back, let name?): HStack(spacing: 12) { Image(systemName: "chevron.backward"); Text(name) }
            case (.forward, let name?): HStack(spacing: 12) { Text(name); Image(systemName: "chevron.forward") }
            case (.back, nil): Image(systemName: "chevron.backward").accessibilityLabel("Previous Season")
            case (.forward, nil): Image(systemName: "chevron.forward").accessibilityLabel("Next Season")
            }
        }
        .disabled(season == nil)
    }
}

/// A title's cover, blurred, behind its page.
struct Backdrop: View {
    let tile: Tile

    var body: some View {
        CoverImage(cover: tile.cover, aspect: tile.aspect, title: "", size: .large)
            .blur(radius: 60)
            .opacity(0.35)
            .ignoresSafeArea()
    }
}

/// A placeholder's page: a title not in the library yet, on a list by
/// name, as the Mac's inspector shows one (the command-line app adds and
/// removes them).
struct WantedPage: View {
    let key: String
    @Environment(Library.self) private var library

    var body: some View {
        let fields = library.wanted(key).map(Wanting.init) ?? .init()
        SettingsPage(title: fields.name, explanation: "Not in the library yet. It takes this place on its list as it comes, if its file is named as this is.") {
            Form {
                Section {
                    ValueLabel(title: "Kind", value: fields.kind == .series ? "Series" : "Movie")
                    if let year = fields.year { ValueLabel(title: "Year", value: String(year)) }
                    if fields.kind == .series { ValueLabel(title: "Season", value: String(fields.season ?? 1)) }
                    if !fields.note.isEmpty { ValueLabel(title: "Note", value: fields.note) }
                }
                .listRowInsets(SettingsView.rowInsets)
            }
            .scrollClipDisabled()
        }
    }
}

#endif
