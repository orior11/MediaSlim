import MediaSlimCore
import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var isRequesting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Image(systemName: "photo.stack")
                    .font(.system(size: 56, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                    .padding(.top, 32)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Free up space without losing quality")
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text("MediaSlim re-saves your photos and videos more efficiently. They look the same and take about half the space.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 20) {
                    Point(systemImage: "lock.iphone", title: "Everything stays on your iPhone",
                          detail: "No uploads, no accounts, no tracking. MediaSlim has no servers.")
                    Point(systemImage: "checkmark.shield", title: "Nothing changes without you",
                          detail: "You choose what to shrink, and you confirm before any original is deleted.")
                    Point(systemImage: "arrow.uturn.backward.circle", title: "Originals can be restored",
                          detail: "Deleted originals stay in Recently Deleted in Photos for 30 days.")
                }

                if model.authorization == .denied || model.authorization == .restricted {
                    Notice(systemImage: "exclamationmark.triangle", title: "Photo access is off",
                           message: Text("Turn on access to all photos for MediaSlim in Settings."), tint: .orange) {
                        Button("Open Settings") { openAppSettings() }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }

                Button {
                    Task {
                        isRequesting = true
                        await model.requestAccess()
                        isRequesting = false
                        if model.authorization.canRead {
                            model.settings.hasCompletedOnboarding = true
                            await model.refresh()
                        }
                    }
                } label: {
                    if isRequesting {
                        ProgressView().tint(Color("OnAccent"))
                    } else {
                        Text("Allow Photo Access")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isRequesting)
                .accessibilityHint(Text("Shows the system permission dialog."))

                Text("MediaSlim asks for full access because replacing a file means reading the original and then deleting it. You can also share only some items.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

private struct Point: View {
    let systemImage: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
