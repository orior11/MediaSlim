import MediaSlimCore
import SwiftUI

struct ResultsView: View {
    @Environment(AppModel.self) private var model
    let progress: RunProgress

    private var summary: RunSummary? { progress.summary }
    private var isReplace: Bool { progress.options.originalHandling == .replace }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Card {
                    AdaptiveStack(spacing: 16) {
                        StatTile(title: "Shrunk", value: (summary?.processed ?? 0).formatted(), systemImage: "checkmark.circle")
                        StatTile(title: "Left as is", value: (summary?.skipped ?? 0).formatted(), systemImage: "minus.circle")
                        if (summary?.failed ?? 0) > 0 {
                            StatTile(title: "Couldn't process", value: (summary?.failed ?? 0).formatted(), systemImage: "exclamationmark.circle")
                        }
                    }
                }
                deletionSection
                Button("Done") { model.closeResults() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(progress.deletion == .inProgress)
                    .accessibilityIdentifier("results.done")
            }
            .padding(16)
        }
    }

    private var header: some View {
        Card {
            Group {
                if progress.wasCancelled { Text("Stopped") } else { Text("All done") }
            }
            .font(.title2.bold())
            .accessibilityAddTraits(.isHeader)
            StatTile(
                title: isReplace ? "Space freed" : "Smaller copies save",
                value: Formatters.bytes(summary?.bytesSaved ?? 0),
                systemImage: "externaldrive"
            )
            .accessibilityIdentifier("results.saved")
            if let summary, summary.bytesBefore > 0 {
                Text("\(Formatters.percent(summary.savedFraction)) smaller on average for the files that were shrunk.")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondaryText)
            }
        }
    }

    @ViewBuilder private var deletionSection: some View {
        if !isReplace {
            Notice(systemImage: "rectangle.stack", title: "Both versions kept",
                   message: Text("The smaller copies are in the MediaSlim album. Your originals are untouched."))
        } else {
            switch progress.deletion {
            case .notNeeded:
                EmptyView()
            case .waiting, .inProgress:
                Notice(systemImage: "hand.raised", title: "Waiting for your confirmation",
                       message: Text("iOS asks you to approve deleting the originals.")) {
                    if case .waiting = progress.deletion {
                        Button("Delete Originals") { Task { await model.deleteOriginals() } }
                            .buttonStyle(PrimaryButtonStyle())
                    }
                }
            case let .deleted(count, _):
                Notice(systemImage: "checkmark.seal", title: "Originals moved to Recently Deleted",
                       message: Text("\(count) originals can be restored from Recently Deleted in Photos for 30 days. After that, iOS removes them for good."))
            case let .declined(count):
                Notice(systemImage: "info.circle", title: "Originals kept",
                       message: Text("You chose not to delete \(count) originals, so no space was freed yet. Both versions are in your library.")) {
                    AdaptiveStack {
                        Button("Delete Originals") { Task { await model.deleteOriginals() } }
                            .buttonStyle(PrimaryButtonStyle())
                        Button("Keep Both") { Task { await model.keepBothVersions() } }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
            case .failed:
                Notice(systemImage: "exclamationmark.triangle", title: "Originals not deleted",
                       message: Text("Some originals couldn't be deleted. Nothing was lost; you can try again from the home screen."),
                       tint: .orange)
            }
        }
    }
}
