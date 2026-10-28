import MediaSlimCore
import MediaSlimPipeline
import SwiftUI
import UIKit

enum Formatters {
    static func bytes(_ value: Int64) -> String {
        value.formatted(.byteCount(style: .file))
    }

    static func bytesRange(_ low: Int64, _ high: Int64) -> String {
        if Formatters.bytes(low) == Formatters.bytes(high) { return Formatters.bytes(high) }
        return "\(Formatters.bytes(low))–\(Formatters.bytes(high))"
    }

    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }
}

// MARK: - Layout

/// A horizontal stack that turns vertical at accessibility text sizes, so nothing truncates.
struct AdaptiveStack<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: spacing) { content }
        } else {
            HStack(alignment: .top, spacing: spacing) { content }
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// A number with a caption, read by VoiceOver as one sentence.
struct StatTile: View {
    let title: LocalizedStringKey
    let value: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.subheadline)
                .foregroundStyle(Color.secondaryText)
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A selectable row with a title and an explanation, used instead of a segmented control so
/// every option can explain itself and grow with Dynamic Type.
struct ChoiceRow: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    var badge: LocalizedStringKey?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondaryText)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title).font(.headline)
                        if let badge {
                            Text(badge)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(Color.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, 16)
            .foregroundStyle(Color("OnAccent"))
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isEnabled ? Color.accentColor : Color.secondary.opacity(0.5))
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, 16)
            .foregroundStyle(Color.accentColor)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
            )
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// A notice with an icon. The icon is decorative; the text carries the meaning.
struct Notice<Actions: View>: View {
    let systemImage: String
    let title: LocalizedStringKey
    let message: Text
    var tint: Color = .accentColor
    @ViewBuilder var actions: Actions

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.headline)
                    message
                        .font(.subheadline)
                        .foregroundStyle(Color.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            actions
        }
    }
}

extension Notice where Actions == EmptyView {
    init(systemImage: String, title: LocalizedStringKey, message: Text, tint: Color = .accentColor) {
        self.init(systemImage: systemImage, title: title, message: message, tint: tint) { EmptyView() }
    }
}

// MARK: - Display text

extension SkipReason {
    var title: LocalizedStringKey {
        switch self {
        case .livePhoto: "Live Photos"
        case .edited: "Edited in Photos"
        case .raw: "RAW photos"
        case .slowMotion: "Slow-motion videos"
        case .cinematic: "Cinematic videos"
        case .spatial: "Spatial photos and videos"
        case .notInUserLibrary: "Shared or synced items"
        case .unsupportedFormat: "Other file formats"
        case .tooSmall: "Already small"
        case .alreadyCompressed: "Already compressed"
        case .alreadyProcessed: "Already shrunk by MediaSlim"
        case .needsCloudDownload: "Stored only in iCloud"
        case .notEnoughSavings: "Little to gain"
        }
    }

    var explanation: LocalizedStringKey {
        switch self {
        case .livePhoto: "The photo and its short video must stay linked. Support is planned."
        case .edited: "Replacing them would remove your edit history."
        case .raw: "RAW files are kept as they are for editing."
        case .slowMotion: "Slow-motion timing would be lost."
        case .cinematic: "The editable focus track would be lost."
        case .spatial: "Depth for Apple Vision Pro would be lost."
        case .notInUserLibrary: "These belong to a shared album or another device."
        case .unsupportedFormat: "Only HEIC, JPEG, PNG and standard video are handled."
        case .tooSmall: "Shrinking them would free almost nothing."
        case .alreadyCompressed: "Usually received through a messaging app. Shrinking again would lower quality."
        case .alreadyProcessed: "Shrinking twice would lower quality."
        case .needsCloudDownload: "Turn on iCloud downloads in Settings to include them."
        case .notEnoughSavings: "Less than a tenth of the size could be saved at your quality setting."
        }
    }

    var systemImage: String {
        switch self {
        case .livePhoto: "livephoto"
        case .edited: "slider.horizontal.3"
        case .raw: "camera.aperture"
        case .slowMotion: "slowmo"
        case .cinematic: "film"
        case .spatial: "visionpro"
        case .notInUserLibrary: "person.2"
        case .unsupportedFormat: "doc.questionmark"
        case .tooSmall, .notEnoughSavings: "arrow.down.right.and.arrow.up.left"
        case .alreadyCompressed: "message"
        case .alreadyProcessed: "checkmark.seal"
        case .needsCloudDownload: "icloud"
        }
    }
}

extension PauseReason {
    var explanation: LocalizedStringKey {
        switch self {
        case .user: "Paused by you."
        case .thermal: "Your iPhone is warm. MediaSlim continues when it cools down."
        case .lowPower: "Low Power Mode is on. Turn it off or connect a charger to continue."
        case .lowStorage: "Space is almost full. Delete the originals processed so far to continue."
        }
    }

    var systemImage: String {
        switch self {
        case .user: "pause.circle"
        case .thermal: "thermometer.sun"
        case .lowPower: "battery.25"
        case .lowStorage: "externaldrive.badge.exclamationmark"
        }
    }
}

extension QualityLevel {
    var title: LocalizedStringKey {
        switch self {
        case .maximumQuality: "Maximum quality"
        case .balanced: "Balanced"
        case .maximumSavings: "Maximum savings"
        }
    }

    var detail: LocalizedStringKey {
        switch self {
        case .maximumQuality: "Practically identical to the original, even when zoomed in. Frees less space."
        case .balanced: "No visible difference when viewing normally. Recommended."
        case .maximumSavings: "Frees the most space. Small differences may show when zooming in."
        }
    }
}

extension LibraryError {
    var message: LocalizedStringKey {
        switch self {
        case .notAuthorized: "MediaSlim needs access to your photos. You can allow it in Settings."
        case .assetNotFound: "That album or item is no longer in your library."
        case .needsCloudDownload: "These items are stored only in iCloud."
        default: "Something went wrong while reading your library. Nothing was changed."
        }
    }
}

/// Opens this app's page in the Settings app.
@MainActor
func openAppSettings() {
    if let url = URL(string: UIApplication.openSettingsURLString) {
        UIApplication.shared.open(url)
    }
}

extension Color {
    /// Secondary text with at least 6:1 contrast in both themes (the system secondary
    /// label falls just under the 4.5:1 target on grouped backgrounds).
    static let secondaryText = Color("SecondaryText")
}
