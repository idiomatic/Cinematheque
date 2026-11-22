import TVServices

/// The Top Shelf: Continue Watching, then each list, as the app last
/// wrote them to the app group's container (`TopShelfPublisher`, whose
/// shape `Content` copies), each item opening its title's page.
final class ContentProvider: TVTopShelfContentProvider {
    private static let group = "group.com.rbrian.cinematheque"
    /// The group container's caches, where a tvOS device lets the app write.
    private static let path = "Library/Caches/TopShelf"

    private struct Content: Decodable {
        struct Section: Decodable {
            let title: String
            let items: [Item]
        }

        struct Item: Decodable {
            let id: String
            let title: String
            let image: String?
            let square: Bool
            let url: String
            /// The link that plays it at once; else, its page's.
            let play: String?
        }

        let sections: [Section]
    }

    override func loadTopShelfContent() async -> (any TVTopShelfContent)? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.group) else { return nil }
        let directory = container.appending(path: Self.path, directoryHint: .isDirectory)
        guard let data = try? Data(contentsOf: directory.appending(path: "content.json")),
              let content = try? JSONDecoder().decode(Content.self, from: data)
        else { return nil }
        let sections = content.sections.map { section -> TVTopShelfItemCollection<TVTopShelfSectionedItem> in
            let collection = TVTopShelfItemCollection(items: section.items.map { item -> TVTopShelfSectionedItem in
                let shelfItem = TVTopShelfSectionedItem(identifier: item.id)
                shelfItem.title = item.title
                shelfItem.imageShape = item.square ? .square : .poster
                if let image = item.image {
                    shelfItem.setImageURL(directory.appending(path: image), for: [.screenScale1x, .screenScale2x])
                }
                // Select shows its page; Play/Pause plays it at once.
                if let url = URL(string: item.url) {
                    shelfItem.displayAction = TVTopShelfAction(url: url)
                    shelfItem.playAction = TVTopShelfAction(url: item.play.flatMap(URL.init(string:)) ?? url)
                }
                return shelfItem
            })
            collection.title = section.title
            return collection
        }
        return sections.isEmpty ? nil : TVTopShelfSectionedContent(sections: sections)
    }
}
