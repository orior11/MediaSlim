import MediaSlimCore
import PhotosUI
import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var showAlbums = false
    @State private var pickerItems: [PhotosPickerItem] = []

    private var totalSaved: Int64 { model.history.reduce(0) { $0 + $1.bytesSaved } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                accessNotice
                pendingDeletionNotice
                interruptedNotice
                sourcesCard
                if !model.history.isEmpty { historyCard }
            }
            .padding(16)
        }
        .navigationTitle("MediaSlim")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.path.append(.settings)
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel(Text("Settings"))
            }
        }
        .sheet(isPresented: $showAlbums) {
            AlbumPickerView { album in
                showAlbums = false
                Task { await model.scan(.album(id: album.id)) }
            }
        }
        .onChange(of: pickerItems) { _, items in
            let ids = items.compactMap(\.itemIdentifier)
            pickerItems = []
            guard !ids.isEmpty else { return }
            Task { await model.scan(.items(ids: ids)) }
        }
        .refreshable { await model.refresh() }
    }

    // MARK: - Notices

    @ViewBuilder private var accessNotice: some View {
        switch model.authorization {
        case .denied, .restricted, .notDetermined:
            Notice(systemImage: "lock", title: "Photo access needed",
                   message: Text("MediaSlim can't see your photos. Allow access in Settings to continue."), tint: .orange) {
                Button("Open Settings") { openAppSettings() }
                    .buttonStyle(SecondaryButtonStyle())
            }
        case .limited:
            Notice(systemImage: "photo.badge.checkmark", title: "Limited access",
                   message: Text("MediaSlim sees only the items you shared with it. You can share more in Settings."))
        case .full:
            EmptyView()
        }
    }

    @ViewBuilder private var pendingDeletionNotice: some View {
        if model.pendingDeletionCount > 0, !model.isRunning {
            Notice(systemImage: "trash.circle", title: "Ready to free space",
                   message: Text("\(model.pendingDeletionCount) compressed copies are safely in your library. Delete the originals to free \(Formatters.bytes(model.pendingDeletionBytes)).")) {
                AdaptiveStack {
                    Button("Delete Originals") { Task { await model.deleteOriginals() } }
                        .buttonStyle(PrimaryButtonStyle())
                    Button("Keep Both") { Task { await model.keepBothVersions() } }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    @ViewBuilder private var interruptedNotice: some View {
        if let interrupted = model.interrupted, !model.isRunning {
            Notice(systemImage: "arrow.clockwise.circle", title: "Unfinished run",
                   message: Text("\(interrupted.count) items were not processed yet. Nothing was lost.")) {
                AdaptiveStack {
                    Button("Continue") { Task { await model.resumeInterrupted() } }
                        .buttonStyle(PrimaryButtonStyle())
                    Button("Discard") { Task { await model.discardInterrupted() } }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    // MARK: - Sources

    private var sourcesCard: some View {
        Card {
            Text("What should MediaSlim shrink?")
                .font(.title3.bold())
                .accessibilityAddTraits(.isHeader)
            Text("You'll see an estimate before anything changes.")
                .font(.subheadline)
                .foregroundStyle(Color.secondaryText)

            SourceButton(systemImage: "photo.on.rectangle.angled", title: "Whole Library",
                         detail: "Every photo and video") {
                Task { await model.scan(.entireLibrary) }
            }
            .accessibilityIdentifier("source.library")

            SourceButton(systemImage: "rectangle.stack", title: "An Album",
                         detail: "Pick one album") {
                showAlbums = true
            }
            .accessibilityIdentifier("source.album")

            PhotosPicker(selection: $pickerItems, matching: .any(of: [.images, .videos]), photoLibrary: .shared()) {
                SourceRow(systemImage: "checkmark.circle", title: "Choose Items", detail: "Select specific photos and videos")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("source.picker")
        }
        .disabled(!model.authorization.canRead || model.isRunning)
    }

    private var historyCard: some View {
        Card {
            StatTile(title: "Space freed so far", value: Formatters.bytes(totalSaved), systemImage: "externaldrive")
            Button {
                model.path.append(.history)
            } label: {
                Label("History", systemImage: "clock")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
        }
    }
}

private struct SourceButton: View {
    let systemImage: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SourceRow(systemImage: systemImage, title: title, detail: detail)
        }
        .buttonStyle(.plain)
    }
}

private struct SourceRow: View {
    let systemImage: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(Color.secondaryText)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.forward")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 10)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// Lists albums to choose from.
struct AlbumPickerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var loaded = false
    let onSelect: (AlbumInfo) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if !loaded {
                    ProgressView("Loading albums…")
                } else if model.albums.isEmpty {
                    ContentUnavailableView("No Albums", systemImage: "rectangle.stack", description: Text("Albums you create in Photos appear here."))
                } else {
                    List(model.albums) { album in
                        Button {
                            onSelect(album)
                        } label: {
                            HStack {
                                Text(album.title)
                                Spacer()
                                Text(album.itemCount, format: .number)
                                    .foregroundStyle(Color.secondaryText)
                                    .monospacedDigit()
                            }
                            .contentShape(Rectangle())
                        }
                        .foregroundStyle(.primary)
                        .accessibilityLabel(Text("\(album.title), \(album.itemCount) items"))
                    }
                }
            }
            .navigationTitle("Albums")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                await model.loadAlbums()
                loaded = true
            }
        }
    }
}
