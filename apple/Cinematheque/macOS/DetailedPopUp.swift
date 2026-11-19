#if os(macOS)
import AppKit
import SwiftUI

/// A pop-up button whose open menu gives each choice a detail (a size) at
/// its trailing edge, by a right tab stop in the item's title, as SwiftUI's
/// menus can't: they keep only an item's first text. The closed button
/// shows only `label`. A detail may be orange (a warning), which a SwiftUI
/// menu item can't be without being drawn as if disabled. A `footer`, last,
/// can't be chosen, its detail in the same column (the space free, which
/// the sizes above are measured against, as a total under its figures).
struct DetailedPopUp: NSViewRepresentable {
    struct Choice {
        let tag: String
        let title: String
        var detail: String? = nil
        var warning = false
    }

    struct Section {
        let choices: [Choice]
    }

    let sections: [Section]
    var footer: (title: String, detail: String)? = nil
    let selection: String
    let label: String
    let select: (String) -> Void

    /// The inspector's small controls' font, the menu's too.
    private static let font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small))
    /// Between a title and its detail, at the least.
    private static let gap: CGFloat = 24

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .small
        button.font = Self.font
        button.target = context.coordinator
        button.action = #selector(Coordinator.picked(_:))
        // The closed button shows the label alone, not the item's detail.
        (button.cell as? NSPopUpButtonCell)?.usesItemFromMenu = false
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.select = select
        let menu = NSMenu()
        menu.font = Self.font
        menu.autoenablesItems = false
        let all = sections.flatMap(\.choices)
        let width = { (text: String) in (text as NSString).size(withAttributes: [.font: Self.font]).width }
        let titles = (all.map(\.title) + [footer?.title].compactMap { $0 }).map(width).max() ?? 0
        let details = (all.compactMap(\.detail) + [footer?.detail].compactMap { $0 }).map(width).max() ?? 0
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: ceil(titles + Self.gap + details))]
        /// A title with its detail at the tab stop.
        func tabbed(_ text: String, _ detail: String, _ color: NSColor, titleColor: NSColor? = nil) -> NSAttributedString {
            let title = NSMutableAttributedString(string: text + "\t", attributes: [.font: Self.font, .paragraphStyle: style])
            if let titleColor { title.addAttribute(.foregroundColor, value: titleColor, range: NSRange(location: 0, length: title.length)) }
            title.append(NSAttributedString(string: detail, attributes: [.font: Self.font, .paragraphStyle: style, .foregroundColor: color]))
            return title
        }
        var selected: NSMenuItem?
        for (i, section) in sections.enumerated() {
            if i > 0 { menu.addItem(.separator()) }
            for choice in section.choices {
                let item = NSMenuItem(title: choice.title, action: nil, keyEquivalent: "")
                item.representedObject = choice.tag
                if let detail = choice.detail {
                    item.attributedTitle = tabbed(choice.title, detail, choice.warning ? .systemOrange : .secondaryLabelColor)
                }
                if choice.tag == selection { selected = item }
                menu.addItem(item)
            }
        }
        if let footer {
            menu.addItem(.separator())
            let item = NSMenuItem(title: footer.title, action: nil, keyEquivalent: "")
            item.attributedTitle = tabbed(footer.title, footer.detail, .secondaryLabelColor, titleColor: .secondaryLabelColor)
            item.isEnabled = false
            menu.addItem(item)
        }
        button.menu = menu
        if let selected { button.select(selected) }
        (button.cell as? NSPopUpButtonCell)?.menuItem = NSMenuItem(title: label, action: nil, keyEquivalent: "")
    }

    func makeCoordinator() -> Coordinator { Coordinator(select: select) }

    final class Coordinator: NSObject {
        var select: (String) -> Void
        init(select: @escaping (String) -> Void) { self.select = select }

        @objc func picked(_ sender: NSPopUpButton) {
            if let tag = sender.selectedItem?.representedObject as? String { select(tag) }
        }
    }
}
#endif
