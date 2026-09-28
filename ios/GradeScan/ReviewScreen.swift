import SwiftUI

/// After a batch: the sheets that need a look (a row to decide, no name, a duplicate, a period that doesn't match),
/// one after another; the ones that read cleanly wait at the end, to look through only if you want. Next when a
/// sheet looks right; delete or rescan one that doesn't. Deleting is instant; swipe back and tap Undo to take it
/// back. Deleted sheets go when you finish.
struct ReviewScreen: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var scan: ScanSession
    @Environment(\.dismiss) private var dismiss
    @State private var page = ""
    @State private var pages: [String] = []   // the sheets being gone through, fixed while the review is open
    @State private var showAll = false

    private static let summary = "summary"

    private var shown: [ScanItem] { pages.compactMap { id in scan.items.first { $0.id == id } } }
    private var goodCount: Int { scan.items.count - shown.count }

    var body: some View {
        NavigationStack {
            TabView(selection: $page) {
                ForEach(shown) { item in
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
                if let item = shown.first(where: { $0.id == page }) { actions(item) }
            }
            .safeAreaInset(edge: .top) {
                if !shown.isEmpty {
                    ProgressView(value: Double(shown.filter(\.decided).count), total: Double(shown.count))
                        .tint(Brand.sage)
                        .padding(.horizontal)
                }
            }
            .navigationTitle(shown.firstIndex { $0.id == page }.map { "\($0 + 1) of \(shown.count)" } ?? "Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
            .onAppear(perform: start)
            .onChange(of: page) { _, id in scan.reviewId = id == Self.summary ? nil : id }
            .onChange(of: scan.reviewId) { _, id in if let id, id != page, pages.contains(id) { page = id } }
        }
    }

    /// The sheets to go through: those that need a look (or are still being read), unless a clean one was tapped.
    private func start() {
        let needing = scan.items.filter { $0.needsLook || $0.processing || $0.rejected }.map(\.id)
        if let id = scan.reviewId, !needing.contains(id) { showAll = true }
        pages = showAll ? scan.items.map(\.id) : needing
        page = scan.reviewId.flatMap { pages.contains($0) ? $0 : nil } ?? shown.first { !$0.decided }?.id ?? Self.summary
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
        let i = shown.firstIndex { $0.id == id } ?? -1
        let next = shown.indices.first { $0 > i && !shown[$0].decided } ?? shown.indices.first { !shown[$0].decided }
        withAnimation(.snappy) { page = next.map { shown[$0].id } ?? Self.summary }
    }

    private var summary: some View {
        let kept = scan.items.filter { !$0.rejected }, rejected = scan.items.count - kept.count
        let waiting = shown.filter { !$0.decided }.count
        return VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 60)).foregroundStyle(Brand.sage)
            Text(scan.items.isEmpty ? "Nothing to review" : pages.isEmpty ? "All \(kept.count) look good" : "\(kept.count) saved")
                .font(.largeTitle.bold()).multilineTextAlignment(.center)
            Group {
                if !showAll && goodCount > 0 && !pages.isEmpty { Text("\(goodCount) read cleanly and need nothing from you") }
                if rejected > 0 { Text("\(rejected) deleted") }
                if waiting > 0 { Text("\(waiting) still to look at; swipe back to them") }
                if let average = scan.average { Text("Average \(Int(average.rounded()))%") }
            }
            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if !showAll && goodCount > 0 {
                Button("Look through them too") {
                    showAll = true
                    let seen = Set(pages)
                    pages = scan.items.map(\.id)
                    page = scan.items.first { !seen.contains($0.id) }?.id ?? Self.summary
                }
                .font(.subheadline.weight(.medium))
            }
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
