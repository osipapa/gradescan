import SwiftUI

/// After a batch: one card at a time. Approve it, or rescan that sheet.
struct ReviewScreen: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var scan: ScanSession
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDiscard = false

    var body: some View {
        NavigationStack {
            Group {
                if let item = scan.reviewItem {
                    ScrollView {
                        ItemCard(item: item).padding()
                    }
                    .id(item.id)
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)).combined(with: .opacity))
                    .safeAreaInset(edge: .bottom) { actions(item) }
                } else {
                    summary
                }
            }
            .safeAreaInset(edge: .top) {
                if scan.reviewItem != nil {
                    ProgressView(value: Double(scan.items.count - scan.unreviewed), total: Double(max(1, scan.items.count)))
                        .tint(Brand.sage)
                        .padding(.horizontal)
                }
            }
            .navigationTitle(scan.reviewItem.flatMap { scan.position($0.id) }.map { "\($0) of \(scan.items.count)" } ?? "Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
            .confirmationDialog("Delete this scan?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let id = scan.reviewItem?.id { withAnimation(.snappy) { scan.discard(id) } }
                }
            } message: {
                Text("It's removed from the portal too.")
            }
        }
    }

    private func actions(_ item: ScanItem) -> some View {
        HStack(spacing: 10) {
            Button(role: .destructive) { confirmDiscard = true } label: {
                Image(systemName: "trash").frame(width: 28)
            }
            .buttonStyle(.bordered)
            .tint(.secondary)
            .accessibilityLabel("Delete")
            Button { scan.startRescan(item.id) } label: {
                Label("Rescan", systemImage: "camera.viewfinder").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            Button { withAnimation(.snappy) { scan.approve(item.id) } } label: {
                Label("Approve", systemImage: "checkmark").bold().frame(maxWidth: .infinity)
            }
            .primaryButton()
        }
        .controlSize(.large)
        .padding()
        .background(.bar)
    }

    private var summary: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 60)).foregroundStyle(Brand.sage)
            Text(scan.items.isEmpty ? "Nothing to review" : "\(scan.items.count) saved").font(.largeTitle.bold())
            if let average = scan.average {
                Text("Average \(Int(average.rounded()))%").font(.title3).foregroundStyle(.secondary)
            }
            VStack(spacing: 10) {
                Button {
                    scan.finishBatch()
                    dismiss()
                } label: {
                    Text("Scan more").bold().frame(maxWidth: .infinity)
                }
                .primaryButton()
                Button {
                    scan.finishBatch()
                    store.tab = .tests
                    dismiss()
                } label: {
                    Text("Done").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
            .padding(.horizontal, 32)
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
