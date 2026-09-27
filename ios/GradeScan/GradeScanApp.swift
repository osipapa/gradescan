import SwiftUI

@main
struct GradeScanApp: App {
    @StateObject private var store: AppStore
    @StateObject private var scan: ScanSession

    init() {
        let store = AppStore()
        _store = StateObject(wrappedValue: store)
        _scan = StateObject(wrappedValue: ScanSession(store: store))
    }

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store).environmentObject(scan)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        if store.session == nil { LoginView() } else { MainTabs() }
    }
}

struct LoginView: View {
    @EnvironmentObject var store: AppStore
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .onSubmit(signIn)
                } footer: {
                    Text("Use the same account as the portal. You only sign in once on this phone.")
                }
                Section {
                    Button(action: signIn) {
                        Text(busy ? "Signing in…" : "Sign in").bold().frame(maxWidth: .infinity)
                    }
                    .disabled(busy || email.isEmpty || password.isEmpty)
                }
                if let problem = store.problem {
                    Section { Text(problem).foregroundStyle(.red) }
                }
            }
            .navigationTitle("GradeScan")
        }
    }

    private func signIn() {
        guard !busy, !email.isEmpty, !password.isEmpty else { return }
        busy = true
        Task {
            await store.signIn(email: email, password: password)
            busy = false
        }
    }
}

struct CameraView: UIViewRepresentable {
    let preview: PreviewView

    func makeUIView(context: Context) -> PreviewView { preview }
    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

extension View {
    /// Liquid Glass on iOS 26 and later, with corners that follow the screen's; frosted material before that.
    @ViewBuilder func glassPanel() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: ConcentricRectangle(corners: .concentric(minimum: .fixed(24)), isUniform: true))
        } else {
            background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    /// A glass capsule, for pills and small controls over the camera.
    @ViewBuilder func glassCapsule(_ tint: Color? = nil) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(tint.map { .regular.tint($0) } ?? .regular, in: Capsule())
        } else {
            background(tint.map { AnyShapeStyle($0.opacity(0.85)) } ?? AnyShapeStyle(.ultraThinMaterial), in: Capsule())
        }
    }
}
