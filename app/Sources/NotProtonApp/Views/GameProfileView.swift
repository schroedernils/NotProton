import SwiftUI

struct GameProfileView: View {
    @Environment(\.dismiss) private var dismiss
    let prefix: WinePrefix
    let installedGraphics: [GameGraphics]
    var onSave: (GameProfile) -> String?
    @State private var profile = GameProfile()
    @State private var error: String?

    var body: some View {
        Form {
            Section("Current runtime") {
                LabeledContent("Compatibility tool", value: runtimeTool?.display ?? "Unknown")
                LabeledContent("Runtime", value: runtimeTool?.tool.flavor.name ?? "Not detected")
                Text("This shows the tool selected by Steam for this existing prefix. Runtime selection stays in Steam Compatibility settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Graphics") {
                Picker("Backend", selection: $profile.graphics) {
                    ForEach(pickerGraphics) { backend in
                        let unavailable = !availableGraphics.contains(backend)
                        Text(unavailable ? "\(backend.title) (saved, unavailable)" : backend.title)
                            .tag(backend)
                    }
                }
                if let message = GameProfileStore.graphicsUnavailableMessage(
                    for: profile.graphics, runtimeTool: runtimeTool
                ) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text("Only backends with an installed module for this game’s compatibility build are available.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Synchronization and display") {
                Picker("Allow macOS Game Mode", selection: $profile.gameMode) {
                    ForEach(ProfileSwitch.allCases) { Text($0.title).tag($0) }
                }
                Text("Saved for this game. macOS decides when Game Mode activates; allowing it does not force it on.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("MSync", selection: $profile.msync) { ForEach(ProfileSwitch.allCases) { Text($0.title).tag($0) } }
                Picker("Retina", selection: $profile.retina) { ForEach(ProfileSwitch.allCases) { Text($0.title).tag($0) } }
                Picker("Steam overlay DPI", selection: $profile.overlayDPI) {
                    ForEach(OverlayDPIScaling.allCases) { Text($0.title).tag($0) }
                }
                Text("Disabling overlay DPI scaling is a compatibility workaround for overlay sizing issues; it does not enable adaptive DPI scaling.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Wine fullscreen display capture", selection: $profile.fullscreenDisplayCapture) {
                    ForEach(FullscreenDisplayCapture.allCases) { Text($0.title).tag($0) }
                }
                Text("Opt out of Wine's display-wide capture call in fullscreen. This may help macOS Space behavior; native Spaces fullscreen is not guaranteed.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Hide launcher tile", selection: $profile.hideLauncherTile) {
                    ForEach(ProfileSwitch.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("Launch") {
                LabeledContent("Target", value: profile.launchTarget ?? "Steam default")
                Button("Choose Windows program…", systemImage: "doc.badge.arrow.up") { chooseTarget() }
                if profile.launchTarget != nil {
                    Button("Use Steam launch defaults", systemImage: "arrow.uturn.backward") {
                        profile.launchTarget = nil
                        profile.launchCwd = nil
                    }
                }
                LabeledContent("Working directory", value: profile.launchCwd ?? "Program directory")
            }
            Section("Shared prefix") {
                Picker("Prefix owner", selection: Binding(
                    get: { profile.prefixOwner ?? "" },
                    set: { profile.prefixOwner = $0.isEmpty ? nil : $0 }
                )) {
                    Text("This game’s own prefix").tag("")
                    ForEach(GameProfileStore.shareableOwners(for: prefix), id: \.appID) { owner in
                        Text("\(owner.title) (\(owner.appID))").tag(owner.appID)
                    }
                }
                Text("The owner must be a compatible prefix in the same Steam library. Sharing keeps this game’s profile here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save Profile") {
                    if let message = onSave(profile) { error = message }
                }
                    .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            do { profile = try GameProfileStore.load(for: prefix) }
            catch { self.error = error.localizedDescription }
        }
    }

    private var runtimeTool: InstalledTool? { PrefixTools.tool(for: prefix) }
    private var availableGraphics: [GameGraphics] {
        GameProfileStore.availableGraphics(installed: installedGraphics, runtimeTool: runtimeTool)
    }
    private var pickerGraphics: [GameGraphics] {
        guard !availableGraphics.contains(profile.graphics) else { return availableGraphics }
        return availableGraphics + [profile.graphics]
    }

    private func chooseTarget() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = PrefixTools.runnableTypes.filter {
            ["exe", "bat", "cmd"].contains($0.preferredFilenameExtension?.lowercased() ?? "")
        }
        panel.directoryURL = PrefixStore.installDirectory(of: prefix)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        profile.launchTarget = url.path(percentEncoded: false)
        profile.launchCwd = url.deletingLastPathComponent().path(percentEncoded: false)
    }
}
