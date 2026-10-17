import SwiftUI

enum Pane: String, CaseIterable, Identifiable, Hashable {
    case status
    case prefixes
    case backups
    case help
    case settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .status: String(localized: "Status")
        case .prefixes: String(localized: "Game environments")
        case .backups: String(localized: "Backups")
        case .help: String(localized: "Help")
        case .settings: String(localized: "Settings")
        }
    }

    var symbol: String {
        switch self {
        case .status: "checklist"
        case .prefixes: "externaldrive"
        case .backups: "externaldrive.badge.timemachine"
        case .help: "questionmark.circle"
        case .settings: "gearshape"
        }
    }
}

struct RootView: View {

    @Binding var pane: Pane
    @Environment(SystemStatus.self) private var status
    private let onboarding = OnboardingWindowController.shared
    init(pane: Binding<Pane>) {
        _pane = pane
    }

    private var sidebarSelection: Binding<Pane?> {
        Binding(get: { pane }, set: { if let value = $0 { pane = value } })
    }

    private var setupRequest: Binding<Bool> {
        Binding(
            get: { false },
            set: { requested in
                if requested { presentSetup(manual: true) }
            })
    }
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    NotProtonIcon().frame(width: 24, height: 24)
                    Text("NotProton").font(.headline)
                }.padding(.horizontal, 16).padding(.vertical, 16)
                List(selection: sidebarSelection) {
                    ForEach([Pane.status, .prefixes, .backups]) { item in
                        sidebarLabel(item).tag(item).padding(.vertical, 3)
                    }
                }.listStyle(.sidebar)
                Spacer(minLength: 0)
                List(selection: sidebarSelection) {
                    ForEach([Pane.help, .settings]) { item in
                        sidebarLabel(item).tag(item).padding(.vertical, 3)
                    }
                }.listStyle(.sidebar).frame(height: 88)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            switch pane {
            case .status: StatusView(showGuide: setupRequest)
            case .prefixes: PrefixesView()
            case .backups: BackupsView()
            case .help: HelpView()
            case .settings: SettingsView(showGuide: setupRequest)
            }
        }
        .navigationTitle(pane.label)
        .background(OnboardingLaunchGate().allowsHitTesting(false))
        .font(.system(size: 13))
        .task { await loadSetup() }
    }
    private func loadSetup() async {
        if status.snapshot == nil { await status.refresh() }
        if OnboardingCoordinator.shouldOpen(snapshot: status.snapshot, defaults: .standard) {
            onboarding.resolveLaunch(showMain: false)
            presentSetup(manual: false)
        } else {
            onboarding.resolveLaunch(showMain: true)
        }
    }
    private func sidebarLabel(_ item: Pane) -> some View {
        Label {
            Text(item.label)
        } icon: {
            Image(systemName: item.symbol).foregroundStyle(.secondary)
        }
    }
    private func presentSetup(manual: Bool) {
        onboarding.present(status: status, manual: manual) { settings in
            if settings { pane = .settings }
        }
    }
}
