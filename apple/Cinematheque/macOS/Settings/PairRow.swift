#if os(macOS)
import AppKit
import SwiftUI

/// A new device nearby offering to be added: the code it shows, entered
/// here, then Yours or Someone New, pairs it (and adds its person, if
/// someone new's), and `paired` moves it on. Once the code's in, Yours is
/// the default, Return in the code pressing it; someone else's device takes
/// a click on Someone New.
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
                // Its name, and under it what kind of device it is.
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.deviceName ?? "A new device")
                        if let model = device.model {
                            Text(model).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: "plus.circle")
                }
                Spacer()
                // Before the boxes, in the row's slack: appearing, it moves
                // nothing, the row being right-aligned.
                if pairing {
                    ProgressView().controlSize(.small)
                }
                CodeField(code: $code, shakes: shakes) { pairYours() }
                    .disabled(pairing)
                // Whose it is, once its code is in: each pairs it.
                Group {
                    // The default, drawn so only once it can act.
                    if code.count == CodeBoxes.length {
                        Button("Yours") { pairYours() }.buttonStyle(.borderedProminent)
                    } else {
                        Button("Yours") { pairYours() }
                    }
                    Button("Someone New") { pairSomeoneNew() }
                }
                .disabled(code.count != CodeBoxes.length || pairing)
            }
            if let failure {
                Text(failure).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Adds it as another of this person's devices.
    private func pairYours() { pair(library.pairPerson) }

    /// Adds it as a new member's.
    private func pairSomeoneNew() { pair(library.pairMember) }

    private func pair(_ adding: @escaping (NearbyDevice, String) async -> String?) {
        guard code.count == CodeBoxes.length, !pairing else { return }
        pairing = true
        Task {
            failure = await adding(device, code)
            // A wrong code: shaken off, to type again. Paired, it stays
            // pairing (its buttons dimmed) until it leaves New Devices, as
            // the device stops offering.
            if failure != nil {
                pairing = false
                withAnimation(.linear(duration: 0.4)) { shakes += 1 }
                code = ""
            } else {
                // Out of New Devices, and into Your Devices (or People).
                withAnimation { paired(device) }
            }
        }
    }
}

/// Where a pairing code is typed: six boxes, showing its length before
/// it's typed, over a field that's invisible but takes focus, typing, and
/// pasting ("123 456" as well as "123456"), keeping digits alone, six at
/// most. Return submits it, once whole; a wrong code shakes it, as the
/// login window shakes off a wrong password.
private struct CodeField: View {
    @Binding var code: String
    let shakes: Int
    let submit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        CodeBoxes(digits: code, size: 17, caret: focused)
            .accessibilityHidden(true)
            .overlay {
                TextField("Pairing code, 6 digits", text: $code)
                    .textFieldStyle(.plain)
                    .labelsHidden()
                    .focused($focused)
                    .onSubmit(submit)
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
