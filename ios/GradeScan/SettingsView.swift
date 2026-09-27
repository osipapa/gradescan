import PhotosUI
import SwiftUI
import Vision

/// Account, scanning preferences, the ZipGrade test, and the class list.
struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var scan: ScanSession
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    LabeledContent("Signed in as", value: store.session?.email ?? "This phone")
                    Button("Sign out", role: .destructive) {
                        dismiss()
                        store.signOut()
                    }
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
                Section {
                    Picker("Test", selection: $scan.zipgradeQuizId) {
                        Text("Ask when scanning").tag(String?.none)
                        ForEach(store.tests.filter(ZipGrade.fits)) { test in Text(test.title).tag(Optional(test.id)) }
                    }
                } header: {
                    Text("ZipGrade sheets")
                } footer: {
                    Text("ZipGrade sheets don't say which test they're for, so they go to this one.")
                }
                Section {
                    Button { importing = true } label: { Label("Import from Jupiter", systemImage: "camera.viewfinder") }
                    LabeledContent("Students", value: "\(store.students.count)")
                } header: {
                    Text("Class list")
                } footer: {
                    Text("Take a photo of a class page in Jupiter. The names are read and added to the period you choose.")
                }
                if !store.pending.isEmpty {
                    Section {
                        LabeledContent("Waiting to upload", value: "\(store.pending.count)")
                    } footer: {
                        Text("They upload on their own when there's a connection.")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $importing) { RosterImportView().environmentObject(store) }
        }
        // The scanner lets go of the camera while this is open, so the Jupiter photo can use it.
        .onAppear { scan.scanner.stop() }
        .onDisappear { if store.tab == .scan && !scan.showReview { scan.scanner.start() } }
    }
}

/// Adds students from a photo of a Jupiter class page (names listed "Last, First").
struct RosterImportView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var takingPhoto = false
    @State private var picked: PhotosPickerItem?
    @State private var reading = false
    @State private var names: [String] = []
    @State private var skip: Set<String> = []
    @State private var period = 1
    @State private var added: Int?

    var body: some View {
        NavigationStack {
            List {
                if names.isEmpty {
                    Section {
                        Text("Open the class in Jupiter on your computer, then take a photo of the list of names. One period at a time.")
                            .foregroundStyle(.secondary)
                        Button { takingPhoto = true } label: { Label("Take a photo", systemImage: "camera") }
                            .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                        PhotosPicker(selection: $picked, matching: .images) { Label("Choose a photo or screenshot", systemImage: "photo") }
                    }
                    if reading { Section { HStack { ProgressView(); Text("Reading names…").foregroundStyle(.secondary) } } }
                    if let added { Section { Text(added == 0 ? "Everyone on that page was already on your list." : "Added \(added) students.") } }
                } else {
                    Section {
                        Picker("Period", selection: $period) { ForEach(1...9, id: \.self) { Text("Period \($0)").tag($0) } }
                    } footer: {
                        Text("Students already on your list for this period are skipped.")
                    }
                    Section("\(names.count - skip.count) of \(names.count) names") {
                        ForEach(names, id: \.self) { name in
                            Button {
                                if skip.contains(name) { skip.remove(name) } else { skip.insert(name) }
                            } label: {
                                HStack {
                                    Image(systemName: skip.contains(name) ? "circle" : "checkmark.circle.fill")
                                        .foregroundStyle(skip.contains(name) ? Color.secondary : Brand.sageStrong)
                                    Text(name).foregroundStyle(.primary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Import from Jupiter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(names.isEmpty ? "Done" : "Cancel") { dismiss() } }
                if !names.isEmpty {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add \(names.count - skip.count)") {
                            let list = names.filter { !skip.contains($0) }.map { (name: $0, period: Optional(period)) }
                            Task {
                                added = await store.addStudents(list)
                                names = []
                                skip = []
                            }
                        }
                        .disabled(names.count == skip.count)
                    }
                }
            }
            .fullScreenCover(isPresented: $takingPhoto) {
                CameraPhoto { image in read(image) }.ignoresSafeArea()
            }
            .onChange(of: picked) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) { read(image) }
                    picked = nil
                }
            }
        }
    }

    private func read(_ image: UIImage) {
        guard let cg = image.cgImage else { return }
        reading = true
        added = nil
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        Task {
            names = await RosterReader.names(in: cg, orientation: orientation)
            skip = []
            reading = false
            if names.isEmpty { added = nil }
        }
    }
}

/// Reads a Jupiter class list from a photo: every line that looks like "Last, First".
enum RosterReader {
    static func names(in image: CGImage, orientation: CGImagePropertyOrientation) async -> [String] {
        await Task.detached(priority: .userInitiated) { () -> [String] in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            let wanted = ["en-US", "es-ES"]
            if let supported = try? request.supportedRecognitionLanguages() { request.recognitionLanguages = wanted.filter(supported.contains) }
            guard (try? VNImageRequestHandler(cgImage: image, orientation: orientation).perform([request])) != nil else { return [] }
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            return parse(lines)
        }.value
    }

    /// Words from Jupiter's menus and buttons, which can read like "Help, Logout".
    static let menuWords: Set<String> = ["help", "logout", "copy", "delete", "new", "update", "revert", "done", "post", "grades", "roll",
                                         "log", "reports", "more", "setup", "attach", "rubric", "period", "student", "score", "comment",
                                         "find", "fill", "due", "worth", "category", "directions", "mean", "range", "count", "points"]

    /// "Garcia, Lena" → "Lena Garcia". Keeps hyphens, accents and middle names; drops scores, headers and menus.
    static func parse(_ lines: [String]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for line in lines {
            let text = String(line.prefix { !$0.isNumber })   // a score read on the same line
                .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ",.")))
            let parts = text.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { continue }
            let allowed = CharacterSet.letters.union(CharacterSet(charactersIn: " -'’."))
            guard parts.allSatisfy({ $0.unicodeScalars.allSatisfy(allowed.contains) }) else { continue }
            let words = parts.flatMap { $0.split(separator: " ") }
            guard (2...6).contains(words.count), words.allSatisfy({ $0.count >= 2 || $0.hasSuffix(".") }),
                  !words.contains(where: { menuWords.contains($0.lowercased()) }) else { continue }
            let name = "\(parts[1]) \(parts[0])"
            if seen.insert(name.lowercased()).inserted { out.append(name) }
        }
        return out
    }
}

private extension CGImagePropertyOrientation {
    init(_ o: UIImage.Orientation) {
        switch o {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

/// The system camera, for one photo.
struct CameraPhoto: UIViewControllerRepresentable {
    let done: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPhoto
        init(_ parent: CameraPhoto) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.done(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
