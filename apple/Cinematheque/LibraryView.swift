import SwiftUI

/// Titles by kind, searchable, beside the one selected.
struct LibraryView: View {
    enum Kind: String, CaseIterable, Identifiable {
        case all = "All", movies = "Movies", series = "Series"
        var id: Self { self }
    }

    @Environment(Library.self) private var library
    @State private var kind = Kind.all
    @State private var search = ""
    @State private var selection: Title.ID?
    @Environment(\.openWindow) private var openWindow

    private var shown: [Title] {
        library.titles.filter { title in
            (kind == .all || (kind == .series) == title.isSeries)
                && (search.isEmpty || title.name.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        if let error = library.error, library.titles.isEmpty {
            ContentUnavailableView("No Library", systemImage: "film.stack", description: Text(error))
        } else {
            NavigationSplitView {
                List(shown, selection: $selection) { title in
                    VStack(alignment: .leading) {
                        Text(title.name)
                        Text([title.year.map(String.init), title.isSeries ? "\(title.items) episodes" : nil]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                // In the sidebar, not its toolbar: under macOS 26's look, the
                // sidebar's toolbar has room only for its toggle, and pushes
                // anything else into an overflow menu.
                .searchable(text: $search, placement: .sidebar)
                .safeAreaInset(edge: .top) {
                    Picker("Kind", selection: $kind) {
                        ForEach(Kind.allCases) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .navigationSplitViewColumnWidth(min: 260, ideal: 320)
                .navigationTitle("\(shown.count) Titles")
                #if DEBUG
                .onAppear {
                    if let key = Launch.selection { selection = key }
                    if let url = Launch.play { openWindow(value: PlayRequest(url: url, item: Launch.item ?? "", start: 0)) }
                }
                #endif
            } detail: {
                if let selection {
                    TitleView(key: selection)
                        .id(selection)
                } else {
                    ContentUnavailableView("Choose a Title", systemImage: "film")
                }
            }
        }
    }
}
