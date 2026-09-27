import SwiftUI

/// After a batch: swipe through the sheets. Next when a sheet looks right; delete or rescan one that doesn't.
/// Deleting is instant; swipe back and tap Undo to take it back. Deleted sheets go when you finish.
struct ReviewScreen: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var scan: ScanSession
    @Environment(\.dismiss) private var dismiss
    @State private var page = ""

    private static let summary = "summary"

    var body: some View {
        NavigationStack {
            TabView(selection: $page) {
                ForEach(scan.items) { item in
                    ScrollView {
                        ItemCard(item: item)
                            .padding()
                            .opacity(item.rejected ? 0.35 : 1)
                            .allowsHitTesting(!item.rejected)
                    }
                    .overlay(alignment: .top) {
                        if item.rejected {
                            Text("Deleted").font(.headline).padding(.horizontal, 16).padding(.vertical, 8)
                                .background(.regularMaterial, in: Capsule()).padding(.top, 12)
                        }
                    }
                    .tag(item.id)
                }
                summary.tag(Self.summary)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .safeAreaInset(edge: .bottom) {
                if let item = scan.items.first(where: { $0.id == page }) { actions(item) }
            }
            .safeAreaInset(edge: .top) {
                ProgressView(value: Double(scan.items.count - scan.undecided), total: Double(max(1, scan.items.count)))
                    .tint(Brand.sage)
                    .padding(.horizontal)
            }
            .navigationTitle(scan.position(page).map { "\($0) of \(scan.items.count)" } ?? "Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
            .onAppear { page = scan.reviewId ?? scan.items.first { !$0.decided }?.id ?? Self.summary }
            .onChange(of: page) { _, id in scan.reviewId = id == Self.summary ? nil : id }
            .onChange(of: scan.reviewId) { _, id in if let id, id != page { page = id } }
        }
    }

    private func actions(_ item: ScanItem) -> some View {
        HStack(spacing: 10) {
            if item.rejected {
                Button { scan.unreject(item.id) } label: {
                    Label("Undo delete", systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else {
                // Looks right: Next. Wrong sheet or a bad capture: delete it or scan it again.
                Button { advance(from: item.id) { scan.reject(item.id) } } label: {
                    Image(systemName: "trash").frame(width: 30)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Delete")
                Button { scan.startRescan(item.id) } label: {
                    Text("Rescan").lineLimit(1).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button { advance(from: item.id) { scan.approve(item.id) } } label: {
                    HStack(spacing: 6) {
                        Text("Next").bold()
                        Image(systemName: "chevron.right").font(.subheadline.weight(.semibold))
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                }
                .primaryButton()
            }
        }
        .controlSize(.large)
        .padding()
        .background(.bar)
    }

    /// Records the decision, then swipes on to the next sheet still waiting (or the summary).
    private func advance(from id: String, _ decide: () -> Void) {
        decide()
        withAnimation(.snappy) { page = scan.nextUndecided(after: id) ?? Self.summary }
    }

    private var summary: some View {
        let kept = scan.items.filter { !$0.rejected }, rejected = scan.items.count - kept.count
        return VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 60)).foregroundStyle(Brand.sage)
            Text(scan.items.isEmpty ? "Nothing to review" : "\(kept.count) saved").font(.largeTitle.bold())
            Group {
                if rejected > 0 { Text("\(rejected) deleted") }
                if scan.undecided > 0 { Text("\(scan.undecided) not looked at yet; swipe back to check them") }
                if let average = scan.average { Text("Average \(Int(average.rounded()))%") }
            }
            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            VStack(spacing: 10) {
                Button {
                    scan.finishBatch()
                    dismiss()
                } label: {
                    Text("Finish and scan more").bold().frame(maxWidth: .infinity)
                }
                .primaryButton()
                Button {
                    scan.finishBatch()
                    store.tab = .tests
                    dismiss()
                } label: {
                    Text("Finish and see results").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
            .padding(.horizontal, 32)
            .padding(.top, 12)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
