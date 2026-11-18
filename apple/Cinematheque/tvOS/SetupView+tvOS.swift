#if os(tvOS)
import SwiftUI

/// Linking this Apple TV to its user and joining their library, by the
/// user's secret and the founder's key, typed (an iPhone's keyboard can type
/// for the remote). Pairing by six digits shown on both screens is to come.
struct SetupView: View {
    @Environment(Library.self) private var library
    @State private var secret = ""
    @State private var founder = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 40) {
            Text("Link This Apple TV")
                .font(.title)
            Text("In Cinematheque on your Mac, Settings shows your secret (This Device) and the founder's key (Members). Type them here; your iPhone's keyboard can type for the remote.")
                .foregroundStyle(.secondary)
            SecureField("Your secret", text: $secret)
            TextField("The founder's key", text: $founder)
            Button("Link and Join") {
                library.link(secret.trimmingCharacters(in: .whitespacesAndNewlines))
                library.found(founder.trimmingCharacters(in: .whitespacesAndNewlines))
                Keys.save()
            }
            .disabled(secret.isEmpty || founder.isEmpty)
            if let problem = library.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 1100)
        .padding(80)
    }
}
#endif
