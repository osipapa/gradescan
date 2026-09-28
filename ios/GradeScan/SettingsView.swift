import SwiftUI

/// Account and scanning preferences. A tab of its own.
struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var scan: ScanSession
    @State private var confirmWipe = false
    @AppStorage("saveProblemFrames") private var saveProblemFrames = false
    @State private var savedFrames = ProblemFrames.count
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
                        Text("Stand").tag(ScanSession.Mode.stand)
                    }
                } header: {
                    Text("Scanning")
                } footer: {
                    Text("Batch captures every sheet in view, even several laid out at once, and you review them at the end. Single shows each result right away. Stand is batch with the phone propped up: slide sheets under it and listen for the tick.")
                }
                if !store.pending.isEmpty {
                    Section {
                        LabeledContent("Waiting to upload", value: "\(store.pending.count)")
                    } footer: {
                        Text("They upload on their own when there's a connection.")
                    }
                }
                Section {
                    Toggle("Save button on the camera", isOn: $saveProblemFrames)
                    if savedFrames > 0 {
                        ShareLink(items: ProblemFrames.all()) {
                            Label("Share \(savedFrames) saved \(savedFrames == 1 ? "frame" : "frames")", systemImage: "square.and.arrow.up")
                        }
                        Button("Delete saved frames", role: .destructive) {
                            ProblemFrames.clear()
                            savedFrames = 0
                        }
                    }
                } header: {
                    Text("Help improve scanning")
                } footer: {
                    Text("When a sheet won't scan, tap the button on the camera to keep what it sees, then share the frames (AirDrop them to a Mac, say) so scanning can be fixed for them. They stay on this phone until then.")
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
            .onAppear { savedFrames = ProblemFrames.count }
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
