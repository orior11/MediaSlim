import MediaSlimCore
import SwiftUI

struct ReviewView: View {
    @Environment(AppModel.self) private var model
    /// Deliberately starts empty: the user decides about originals on every run.
    @State private var handling: OriginalHandling?
    @State private var showSkipped = false

    var body: some View {
        Group {
            switch model.scanState {
            case .idle, .scanning:
                ProgressView {
                    Text("Looking through your library…")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("review.scanning")
            case let .failed(error):
                ContentUnavailableView {
                    Label("Couldn't read the library", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.message)
                } actions: {
                    if error == .notAuthorized {
                        Button("Open Settings") { openAppSettings() }
                    }
                }
            case let .ready(report):
                if report.eligible.isEmpty {
                    nothingToDo(report)
                } else {
                    content(report)
                }
            }
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func nothingToDo(_ report: ScanReport) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                ContentUnavailableView(
                    "Nothing to shrink here",
                    systemImage: "checkmark.circle",
                    description: Text("These items are already efficient, or are types MediaSlim leaves as they are.")
                )
                if report.skippedCount > 0 { skippedList(report) }
            }
            .padding(16)
        }
    }

    private func content(_ report: ScanReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Card {
                    StatTile(
                        title: "Estimated space to free",
                        value: Formatters.bytesRange(report.estimatedSavingsLow, report.estimatedSavingsHigh),
                        systemImage: "arrow.down.circle"
                    )
                    .accessibilityIdentifier("review.estimate")
                    Text("\(report.photoCount) photos and \(report.videoCount) videos, \(Formatters.bytes(report.eligibleBytes)) in total.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("The real result is measured for every file. Anything that doesn't pass the quality check is left untouched.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                section(title: "Quality") {
                    ForEach(QualityLevel.allCases, id: \.self) { level in
                        ChoiceRow(title: level.title, detail: level.detail,
                                  badge: level == .balanced ? "Recommended" : nil,
                                  isSelected: model.settings.qualityLevel == level) {
                            model.settings.qualityLevel = level
                        }
                        .accessibilityIdentifier("quality.\(level.rawValue)")
                    }
                }

                section(title: "Originals") {
                    ChoiceRow(
                        title: "Replace originals",
                        detail: "The smaller copy takes the original's place, with the same date, location and albums. After you confirm, originals move to Recently Deleted for 30 days.",
                        badge: model.settings.lastOriginalHandling == .replace ? "Last time" : nil,
                        isSelected: handling == .replace
                    ) { handling = .replace }
                    .accessibilityIdentifier("handling.replace")

                    ChoiceRow(
                        title: "Keep both",
                        detail: "The smaller copy is added to the MediaSlim album and nothing is deleted. Space is freed only when you delete originals yourself.",
                        badge: model.settings.lastOriginalHandling == .keepBoth ? "Last time" : nil,
                        isSelected: handling == .keepBoth
                    ) { handling = .keepBoth }
                    .accessibilityIdentifier("handling.keepBoth")
                }

                if report.skippedCount > 0 { skippedList(report) }

                VStack(spacing: 8) {
                    Button {
                        if let handling { model.startRun(handling: handling) }
                    } label: {
                        Text("Start")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(handling == nil)
                    .accessibilityIdentifier("review.start")
                    .accessibilityHint(handling == nil ? Text("Choose what happens to the originals first.") : Text(""))

                    Group {
                        if handling == nil {
                            Text("Choose what happens to the originals to continue.")
                        } else {
                            Text("Keep MediaSlim open, or connect a charger and it continues in the background.")
                        }
                    }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(16)
        }
    }

    private func section<Content: View>(title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.bold())
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func skippedList(_ report: ScanReport) -> some View {
        Card {
            DisclosureGroup(isExpanded: $showSkipped) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(report.skipped.sorted { $0.value > $1.value }, id: \.key) { entry in
                        let reason = entry.key, count = entry.value
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: reason.systemImage)
                                .foregroundStyle(.secondary)
                                .frame(width: 24)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(reason.title).font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text(count, format: .number).monospacedDigit()
                                }
                                Text(reason.explanation)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.top, 8)
            } label: {
                Text("\(report.skippedCount) items will be left as they are")
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
        }
    }
}
