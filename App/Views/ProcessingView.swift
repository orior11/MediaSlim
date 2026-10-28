import MediaSlimCore
import MediaSlimLibrary
import SwiftUI
import UIKit

struct ProcessingView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmStop = false

    var body: some View {
        Group {
            if let progress = model.progress {
                if progress.isFinished {
                    ResultsView(progress: progress)
                } else {
                    running(progress)
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(model.progress?.isFinished == true ? Text("Done") : Text("Shrinking"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
    }

    private func running(_ progress: RunProgress) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                ProgressRing(fraction: progress.fraction)
                    .frame(width: 180, height: 180)
                    .padding(.top, 12)
                    .accessibilityHidden(true)

                VStack(spacing: 6) {
                    Text("\(progress.completed) of \(progress.total)")
                        .font(.title.bold())
                        .monospacedDigit()
                    Text("\(Formatters.bytes(progress.bytesSaved)) saved so far")
                        .font(.headline)
                        .foregroundStyle(Color.secondaryText)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Progress"))
                .accessibilityValue(Text("\(progress.completed) of \(progress.total) done. \(Formatters.bytes(progress.bytesSaved)) saved so far."))
                .accessibilityIdentifier("processing.progress")

                ProgressView(value: progress.fraction)
                    .accessibilityHidden(true)

                if let item = progress.currentItem, !progress.isPaused {
                    CurrentItemRow(item: item, isDemo: model.isDemo)
                }

                ForEach(progress.pauseReasons.sorted { $0.rawValue < $1.rawValue }, id: \.self) { reason in
                    Notice(systemImage: reason.systemImage, title: "Paused", message: Text(reason.explanation), tint: .orange)
                }

                if progress.options.originalHandling == .replace,
                   progress.lowStorageWarning || progress.pauseReasons.contains(.lowStorage) {
                    Notice(systemImage: "externaldrive.badge.exclamationmark", title: "Space is running low",
                           message: Text("Delete the originals processed so far to make room. You'll confirm in the next step."), tint: .orange) {
                        Button("Delete Processed Originals") { Task { await model.deleteOriginals() } }
                            .buttonStyle(PrimaryButtonStyle())
                    }
                }

                AdaptiveStack {
                    if progress.pauseReasons.contains(.user) {
                        Button("Resume") { model.resume() }
                            .buttonStyle(PrimaryButtonStyle())
                            .accessibilityIdentifier("processing.resume")
                    } else {
                        Button("Pause") { model.pause() }
                            .buttonStyle(SecondaryButtonStyle())
                            .accessibilityIdentifier("processing.pause")
                    }
                    Button("Stop", role: .destructive) { confirmStop = true }
                        .buttonStyle(SecondaryButtonStyle())
                        .accessibilityIdentifier("processing.stop")
                }

                Text("Files are replaced only after the smaller copy is saved and checked.")
                    .font(.footnote)
                    .foregroundStyle(Color.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .padding(16)
        }
        .confirmationDialog("Stop now?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop", role: .destructive) { model.cancelRun() }
            Button("Keep Going", role: .cancel) {}
        } message: {
            Text("Files already done stay done. Nothing is lost.")
        }
    }
}

/// Decorative ring; the numbers next to it carry the meaning for VoiceOver.
private struct ProgressRing: View {
    let fraction: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 14)
            Circle()
                .trim(from: 0, to: max(0.001, fraction))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: fraction)
            Text(Formatters.percent(fraction))
                .font(.title2.weight(.semibold))
                .monospacedDigit()
        }
    }
}

private struct CurrentItemRow: View {
    let item: MediaItem
    let isDemo: Bool
    @State private var thumbnail: UIImage?
    @Environment(\.displayScale) private var scale

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                } else {
                    Image(systemName: item.kind == .photo ? "photo" : "video")
                        .font(.title2)
                        .foregroundStyle(Color.secondaryText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.quaternary)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.kind == .photo ? "Working on a photo" : "Working on a video")
                    .font(.subheadline.weight(.semibold))
                if let bytes = item.byteSize {
                    Text(Formatters.bytes(bytes))
                        .font(.footnote)
                        .foregroundStyle(Color.secondaryText)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .task(id: item.id) {
            thumbnail = nil
            guard !isDemo else { return }
            thumbnail = await ThumbnailLoader().image(for: item.id, side: 56, scale: scale)
        }
    }
}
