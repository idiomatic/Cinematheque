import SwiftUI

// Settings' confirmations, alike on every platform: each says what the
// action does, as it's hard to undo.

/// Leaving the library from Settings, once confirmed: ending it, if no one
/// else is in it.
@MainActor @Observable
final class Leaving {
    var confirming = false
    private(set) var underWay = false
    /// Why it couldn't, if it couldn't.
    private(set) var problem: String?

    /// Asks first, as it's hard to undo.
    func ask() { confirming = true }

    /// Leaves by `leave` (`leaveLibrary`, or `endLibrary`), then calls
    /// `left` if it did.
    fileprivate func start(_ leave: @escaping () async -> String?, then left: @escaping () -> Void) {
        underWay = true
        problem = nil
        Task {
            problem = await leave()
            underWay = false
            if problem == nil { left() }
        }
    }
}

extension View {
    /// Asks before leaving, as `leaving` asks; `left` once it has.
    func confirmsLeaving(_ leaving: Leaving, then left: @escaping () -> Void = {}) -> some View {
        modifier(ConfirmsLeaving(leaving: leaving, left: left))
    }

    /// Asks before removing someone: they come back only by joining again,
    /// as someone new.
    func confirmsRemoving(member: Binding<Member?>) -> some View {
        modifier(ConfirmsRemovingMember(removing: member))
    }

    /// Asks before removing a source: it can't be undone but by adding it
    /// again and looking for its videos anew.
    func confirmsRemoving(source: Binding<Source?>) -> some View {
        modifier(ConfirmsRemovingSource(removing: source))
    }
}

private struct ConfirmsLeaving: ViewModifier {
    @Bindable var leaving: Leaving
    let left: () -> Void
    @Environment(Library.self) private var library

    /// No one else in the library, nor another device of yours: leaving ends it.
    private var alone: Bool { library.members.count == 1 && library.status?.others == 0 }

    func body(content: Content) -> some View {
        content.alert(alone ? "End This Library?" : "Leave This Library?", isPresented: $leaving.confirming) {
            Button(alone ? "Leave and End It" : "Leave", role: .destructive) {
                if alone { leaving.start(library.endLibrary, then: left) } else { leaving.start(library.leaveLibrary, then: left) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(alone
                ? "No one else is in this library, so once this \(Library.deviceKind) leaves, it's gone for good. Its videos stay where they are."
                : "This \(Library.deviceKind) leaves the library, and your other devices no longer list it. To come back, join again.")
        }
    }
}

private struct ConfirmsRemovingMember: ViewModifier {
    @Binding var removing: Member?
    @Environment(Library.self) private var library

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Remove \(removing?.name ?? "Them")?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible,
            presenting: removing
        ) { member in
            Button("Remove", role: .destructive) { library.removeMember(member.key) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("They and their devices leave the library, and what they change from then on is refused. To come back, they join again as someone new; their lists and progress don't come back with them.")
        }
    }
}

private struct ConfirmsRemovingSource: ViewModifier {
    @Binding var removing: Source?
    @Environment(Library.self) private var library

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Remove “\(removing.map { library.folder(of: $0)?.name ?? $0.displayName } ?? "")”?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible,
            presenting: removing
        ) { source in
            Button("Remove", role: .destructive) { library.remove(source) }
            Button("Cancel", role: .cancel) {}
        } message: { source in
            let videos = source.copies == 1 ? "Its one video goes" : "Its \(source.copies.formatted()) videos go"
            let sharing = library.folder(of: source) == nil ? "" : " This \(Library.deviceKind) stops sharing the folder."
            Text("\(videos) from the library, on every device, though its files stay where they are.\(sharing) You can add it again.")
        }
    }
}
