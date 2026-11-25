#if os(iOS)
import SwiftUI

/// The iPhone's Settings, from Home's corner, as iOS's own apps' are: the
/// shared pages (`SettingsView`), grouped lists in a sheet.
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SettingsView()
                .navigationTitle("Settings")
                .toolbar { Button("Done") { dismiss() } }
        }
    }
}
#endif
