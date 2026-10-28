import MediaSlimCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmErase = false

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Picker(selection: $settings.qualityLevel) {
                    ForEach(QualityLevel.allCases, id: \.self) { level in
                        Text(level.title).tag(level)
                    }
                } label: {
                    Text("Default quality")
                }
                .pickerStyle(.navigationLink)
            } header: {
                Text("Quality")
            } footer: {
                Text(settings.qualityLevel.detail)
            }

            Section {
                Toggle("Photos", isOn: $settings.includePhotos)
                Toggle("Videos", isOn: $settings.includeVideos)
            } header: {
                Text("Include")
            }

            Section {
                Toggle("Download from iCloud when needed", isOn: $settings.allowCloudDownloads)
            } footer: {
                Text("If an original is stored only in iCloud, the Photos app downloads it first. MediaSlim itself never connects to the internet.")
            }

            Section {
                Toggle("Continue while charging", isOn: $settings.continueWhileCharging)
            } footer: {
                Text("If you leave the app during a run, iOS can finish it later while your iPhone charges. Originals are deleted only after you confirm.")
            }

            Section {
                Label("All processing happens on this iPhone.", systemImage: "iphone")
                Label("No accounts, servers, ads or analytics.", systemImage: "hand.raised")
                Label("Working files are encrypted and deleted after each item.", systemImage: "lock")
                Button("Erase App Records", role: .destructive) { confirmErase = true }
            } header: {
                Text("Privacy")
            } footer: {
                Text("Erasing removes MediaSlim's history and settings. Your photos and videos are not touched.")
            }

            Section {
                LabeledContent("Version", value: version)
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog("Erase app records?", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("Erase", role: .destructive) { Task { await model.eraseAllData() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your photos and videos are not touched.")
        }
    }
}
