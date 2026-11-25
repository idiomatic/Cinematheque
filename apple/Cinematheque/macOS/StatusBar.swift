#if os(macOS)
import SwiftUI

/// What last went wrong, along the bottom of a window, until dismissed or
/// the next action of its kind succeeds: modeless, never an alert.
struct ProblemBar: View {
    @Environment(Library.self) private var library

    var body: some View {
        if let problem = library.problem {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(problem)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Dismiss", systemImage: "xmark") { library.problem = nil }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(.bar)
        }
    }
}

/// Along the bottom of the grid, over it: the shelf's counts, what a long
/// operation is doing and how far it has come, or what went wrong. It fades
/// out a few seconds after it last changed, unless something is running or
/// wrong, or the pointer is near it; floating, so fading moves nothing.
struct StatusBar: View {
    let counts: String
    let hovering: Bool
    @Environment(Library.self) private var library
    @State private var fresh = true
    @AppStorage(Library.showsSyncActivity) private var showsSyncActivity = false

    static let height: CGFloat = 30

    private var sticky: Bool { library.problem != nil || library.activity != nil || hovering }
    private var visible: Bool { fresh || sticky }

    /// The widest scroll bar's column, which the bar fades out before, so
    /// the grid's scroll bar, shown always or while scrolling, runs the
    /// window's height through it; and the fade's own width.
    private static let scroller = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
    private static let fade: CGFloat = 24

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 1)
            HStack(spacing: 8) {
                if let problem = library.problem {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    Text(problem).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Button("Dismiss", systemImage: "xmark") { library.problem = nil }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                } else {
                    // Whole, before the line of exchanges, which shortens instead.
                    Text(counts).lineLimit(1).fixedSize()
                }
                Spacer(minLength: 12)
                if let activity = library.activity {
                    Text(Self.describe(activity, library.steps))
                        .lineLimit(1)
                        .monospacedDigit()
                        .layoutPriority(1)
                    if let p = library.steps, p.total > 0 {
                        ProgressView(value: Double(min(p.done, p.total)), total: Double(p.total))
                            .progressViewStyle(.linear)
                            .frame(width: 100)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                } else if library.problem == nil, showsSyncActivity {
                    // The last exchange with devices each way, for diagnosis
                    // (making way for a problem, which matters more).
                    Text(library.syncLine)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            // What it says ends before the fade, whole.
            .padding(.trailing, Self.fade + Self.scroller)
            .frame(height: Self.height - 1)
        }
        // Its divider and background alone fade out.
        .background {
            VStack(spacing: 0) {
                Divider()
                Rectangle().fill(.bar)
            }
            .mask {
                HStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: Self.fade)
                    Color.clear.frame(width: Self.scroller)
                }
            }
        }
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .animation(.easeInOut(duration: 0.6), value: visible)
        // Shown afresh whenever it changes, then faded after a while.
        .task(id: "\(counts)|\(library.problem ?? "")|\(sticky)|\(showsSyncActivity ? "\(library.received?.at ?? .distantPast)|\(library.sent?.at ?? .distantPast)" : "")") {
            fresh = true
            guard !sticky else { return }
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { fresh = false }
        }
    }

    /// "Looking in 3 of 6 sources", "Finding covers for 1,200 of 5,000" (covers and
    /// details found), or what's running ("Looking for new videos").
    static func describe(_ activity: String, _ p: Library.Steps?) -> String {
        guard let p, let phase = p.phase else { return activity + "…" }
        let done = min(p.done + (phase == .describing ? 0 : 1), p.total).formatted()
        let total = p.total.formatted()
        return switch phase {
        case .crawling: "Looking in \(done) of \(total) \(p.total == 1 ? "source" : "sources")…"
        case .describing: p.total == 0 ? "Finding covers…" : "Finding covers for \(p.done.formatted()) of \(total)…"
        // Catching up, as a refresh does first, says only what it's for.
        case .syncing: activity + "…"
        }
    }
}
#endif
