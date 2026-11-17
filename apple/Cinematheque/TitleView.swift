import SwiftUI

/// A title's episodes or versions, each rendition, and its copies to play.
struct TitleView: View {
    let key: String
    @Environment(Library.self) private var library
    @Environment(\.openWindow) private var openWindow
    @State private var detail: TitleDetail?
    @State private var loaded = false

    var body: some View {
        Group {
            if let detail {
                List {
                    ForEach(detail.items) { item in
                        Section {
                            ForEach(item.renditions, id: \.label) { rendition in
                                ForEach(rendition.copies, id: \.url) { copy in
                                    row(item, rendition.name, copy)
                                }
                            }
                        } header: {
                            header(item)
                        }
                    }
                }
                .navigationTitle(detail.name)
                .navigationSubtitle(detail.year.map(String.init) ?? "")
            } else if loaded {
                ContentUnavailableView("No Such Title", systemImage: "questionmark", description: Text(key))
            } else {
                ProgressView()
            }
        }
        .task(id: library.revision) {
            detail = library.detail(key)
            loaded = true
        }
    }

    private func header(_ item: TitleDetail.Item) -> some View {
        HStack {
            Text(itemName(item.key))
            Spacer()
            if item.watched {
                Label("Watched", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
            } else if item.position > 0, item.duration > 0 {
                ProgressView(value: Double(item.position), total: Double(item.duration))
                    .frame(width: 120)
                Text(Duration.milliseconds(item.duration - item.position).formatted(.units(allowed: [.hours, .minutes], width: .narrow)) + " left")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .contextMenu {
            Button(item.watched ? "Mark as Unwatched" : "Mark as Watched") {
                library.setWatched(fullKey(item), !item.watched)
            }
        }
    }

    private func fullKey(_ item: TitleDetail.Item) -> String { "\(key)/\(item.key)" }

    private func row(_ item: TitleDetail.Item, _ label: String, _ copy: TitleDetail.Copy) -> some View {
        // Resume where this user left off, unless finished.
        let start = item.watched ? 0 : Double(item.position) / 1000
        return HStack {
            Button {
                if let url = URL(string: copy.url) { openWindow(value: PlayRequest(url: url, item: fullKey(item), start: start)) }
            } label: {
                Label(start > 0 ? "Resume" : "Play", systemImage: "play.fill")
            }
            VStack(alignment: .leading) {
                Text(label)
                Text(copy.url.removingPercentEncoding ?? copy.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: Int64(copy.size), countStyle: .file))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    /// "e/s03e17" as "Season 3, Episode 17"; "v/-" as "Standard".
    private func itemName(_ key: String) -> String {
        var parts: [String] = []
        let segments = key.split(separator: "/").map(String.init)
        var i = 0
        while i + 1 < segments.count {
            let (kind, value) = (segments[i], segments[i + 1])
            switch kind {
            case "e":
                let numbers = value.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
                if value.hasPrefix("s"), numbers.count >= 2 {
                    parts.append("Season \(numbers[0]), Episode \(numbers[1])" + (numbers.count > 2 ? "–\(numbers[2])" : ""))
                } else {
                    parts.append(value)
                }
            case "v":
                parts.append(value == "-" ? "Standard" : value.replacingOccurrences(of: "-", with: " ").capitalized)
            case "p":
                parts.append("Part \(value)")
            default:
                parts.append(value)
            }
            i += 2
        }
        return parts.joined(separator: " · ")
    }
}
