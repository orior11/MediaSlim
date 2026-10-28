import MediaSlimCore
import SwiftUI

struct HistoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.history.isEmpty {
                ContentUnavailableView("No History Yet", systemImage: "clock", description: Text("Finished runs appear here."))
            } else {
                List(model.history) { run in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(run.startedAt, format: .dateTime.day().month().year().hour().minute())
                            .font(.headline)
                        Text("\(Formatters.bytes(run.bytesSaved)) saved from \(run.processed) items")
                            .font(.subheadline)
                        if run.skipped + run.failed > 0 {
                            Text("\(run.skipped + run.failed) left as they were")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .navigationTitle("History")
        .task { await model.refresh() }
    }
}
