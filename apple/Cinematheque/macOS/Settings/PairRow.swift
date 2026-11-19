#if os(macOS)
import AppKit
import SwiftUI

/// A new device nearby offering to pair, to be another of yours or a new
/// member's: the code it shows, entered here, pairs it (and adds its person,
/// if joining), and `paired` moves it on.
struct PairRow: View {
    let device: NearbyDevice
    let paired: (NearbyDevice) -> Void
    @Environment(Library.self) private var library
    @State private var code = ""
    @State private var pairing = false
    @State private var failure: String?
    /// Counts wrong codes, each shaking the field.
    @State private var shakes = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(device.deviceName ?? "A new device", systemImage: device.joining ? "person.crop.circle.badge.plus" : "appletv")
                Text(device.joining ? "wants to join" : "wants to pair").foregroundStyle(.secondary)
                Spacer()
                // Before the boxes, in the row's slack: appearing, it moves
                // nothing, the row being right-aligned.
                if pairing {
                    ProgressView().controlSize(.small)
                }
                CodeField(code: $code, shakes: shakes, complete: pair)
                    .disabled(pairing)
                Button(device.joining ? "Add" : "Pair", action: pair)
                    .disabled(code.count != CodeBoxes.length || pairing)
            }
            if let failure {
                Text(failure).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func pair() {
        guard code.count == CodeBoxes.length, !pairing else { return }
        pairing = true
        Task {
            let (joined, why) = await library.pair(device, code: code)
            failure = why
            pairing = false
            // A wrong code: shaken off, to type again.
            if joined == nil {
                withAnimation(.linear(duration: 0.4)) { shakes += 1 }
                code = ""
            }
            // Out of New Devices, and into Your Devices (or People).
            if let joined {
                withAnimation {
                    library.welcome(joined, from: device)
                    paired(device)
                }
            }
        }
    }
}

/// Where a pairing code is typed: six boxes, showing its length before
/// it's typed, over a field that's invisible but takes focus, typing, and
/// pasting ("123 456" as well as "123456"), keeping digits alone, six at
/// most. The sixth digit pairs at once (`complete`); a wrong code shakes it,
/// as the login window shakes off a wrong password.
private struct CodeField: View {
    @Binding var code: String
    let shakes: Int
    let complete: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        CodeBoxes(digits: code, size: 17, caret: focused)
            .accessibilityHidden(true)
            .overlay {
                TextField("Pairing code, 6 digits", text: $code)
                    .textFieldStyle(.plain)
                    .labelsHidden()
                    .focused($focused)
                    // Not hidden, which would stop it taking focus.
                    .opacity(0.011)
                    .accessibilityLabel("Pairing code, 6 digits")
            }
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
            .modifier(Shake(phase: CGFloat(shakes)))
            // Disabled while pairing, it lost focus: back, to type again.
            .onChange(of: shakes) { focused = true }
            .onChange(of: code) { _, typed in
                let digits = String(typed.filter(\.isNumber).prefix(CodeBoxes.length))
                if digits != typed { code = digits }
                if digits.count == CodeBoxes.length { complete() }
            }
    }
}

/// Side to side, three times over, as `phase` goes up by one.
private struct Shake: GeometryEffect {
    var phase: CGFloat
    var animatableData: CGFloat {
        get { phase }
        set { phase = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 6 * sin(phase * .pi * 6), y: 0))
    }
}
#endif
