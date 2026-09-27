import SwiftUI

/// Account and scanning preferences. A tab of its own.
struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var scan: ScanSession
    @State private var confirmWipe = false
    @State private var wiping = false
    @State private var wiped = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    LabeledContent("Signed in as", value: store.session?.accountEmail ?? "–")
                    Button("Sign out", role: .destructive) { store.signOut() }
                }
                Section {
                    Picker("Start in", selection: $scan.mode) {
                        Text("Batch").tag(ScanSession.Mode.batch)
                        Text("Single").tag(ScanSession.Mode.single)
                    }
                } header: {
                    Text("Scanning")
                } footer: {
                    Text("Batch captures every sheet in view, even several laid out at once, and you review them at the end. Single shows each result right away.")
                }
                if !store.pending.isEmpty {
                    Section {
                        LabeledContent("Waiting to upload", value: "\(store.pending.count)")
                    } footer: {
                        Text("They upload on their own when there's a connection.")
                    }
                }
                // TESTING ONLY — remove before production (with AppStore.wipeEverything and API.wipeEverything).
                Section {
                    Button(role: .destructive) { confirmWipe = true } label: {
                        HStack {
                            Text(wiping ? "Deleting…" : "Delete all my data")
                            if wiping { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(wiping)
                } header: {
                    Text("Testing")
                } footer: {
                    Text(wiped ? "Everything was deleted." : "Deletes every test, scan, student and sheet photo on this account. For testing; this goes away before release.")
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Delete everything on this account?", isPresented: $confirmWipe, titleVisibility: .visible) {
                Button("Delete everything", role: .destructive) {
                    wiping = true
                    Task {
                        scan.forgetBatch()
                        wiped = await store.wipeEverything()
                        wiping = false
                    }
                }
            } message: {
                Text("Every test, scan, student and sheet photo, on this phone and in the portal. This can't be undone.")
            }
        }
    }
}
