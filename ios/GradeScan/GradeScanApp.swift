import SwiftUI

@main
struct GradeScanApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        if store.session == nil { LoginView() } else { ScanView() }
    }
}

struct LoginView: View {
    @EnvironmentObject var store: AppStore
    @State private var email = ""
    @State private var password = ""
    @State private var passphrase = ""
    @State private var busy = false

    var body: some View {
        Form {
            Section("GradeScan") {
                TextField("Email", text: $email)
                    .keyboardType(.emailAddress)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(.password)
            }
            Section {
                SecureField("Roster passphrase (optional)", text: $passphrase)
            } footer: {
                Text("The same passphrase as in the portal. With it, scans show student names; without it, just the Student #.")
            }
            Button(busy ? "Signing in…" : "Sign in") {
                busy = true
                Task {
                    await store.signIn(email: email, password: password, passphrase: passphrase)
                    busy = false
                }
            }
            .disabled(busy || email.isEmpty || password.isEmpty)
            if let problem = store.problem {
                Text(problem).foregroundStyle(.red)
            }
        }
    }
}

struct ScanView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        ZStack(alignment: .bottom) {
            CameraView(preview: store.preview).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 6) {
                Text(store.status).font(.title3.bold())
                if !store.detail.isEmpty { Text(store.detail) }
                HStack {
                    Text("Sent \(store.sent)")
                    if !store.pending.isEmpty {
                        Text("· \(store.pending.count) waiting").foregroundStyle(.orange)
                    }
                    Spacer()
                    Menu {
                        Button("Reload quizzes") { Task { await store.reload() } }
                        Button("Retry sending") { Task { await store.send() } }
                        Button("Sign out", role: .destructive) { store.signOut() }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.title2)
                    }
                }
                .font(.subheadline)
                if let problem = store.problem {
                    Text(problem).font(.footnote).foregroundStyle(.red)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial)
        }
        .task { await store.reload() }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            store.scanner.start()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            store.scanner.stop()
        }
    }
}

struct CameraView: UIViewRepresentable {
    let preview: PreviewView

    func makeUIView(context: Context) -> PreviewView { preview }
    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
