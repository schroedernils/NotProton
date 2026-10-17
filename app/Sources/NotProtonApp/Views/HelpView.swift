import AppKit
import SwiftUI

struct HelpView: View {
    @Environment(SystemStatus.self) private var status
    @State private var query = ""
    @State private var copied = false
    @State private var showReport = false
    @State private var report = ""

    private var topics: [HelpTopic] { HelpTopic.all.filter { $0.matches(query) } }

    var body: some View {
        ManagementForm {
            DesktopPageHeader(
                title: "Help", subtitle: "Guidance for setup and your games.", symbol: "questionmark.circle")
            ManagementSection("Common questions") {
                if topics.isEmpty {
                    Text("No matching help. Try a shorter search, such as controller, Steam or saves.")
                        .foregroundStyle(.secondary)
                }
                ForEach(topics) { topic in
                    DisclosureGroup(topic.title) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(topic.body).textSelection(.enabled)
                            if let url = topic.url { Link(("More information"), destination: url) }
                        }.padding(.vertical, 6)
                    }.disclosureGroupStyle(WholeRowDisclosureStyle())
                }
            }
            ManagementSection("Support summary") {
                Text(
                    "Copy app versions and component status for a bug report. No account data or paths are included."
                )
                .foregroundStyle(.secondary)
                Button("Preview support summary…") {
                    report = SupportReport.make(snapshot: status.snapshot)
                    copied = false
                    showReport = true
                }
                Button("Reveal local log…") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppLog.file])
                }
                Text(
                    "The raw local log may contain private paths or error details. Review it before sharing."
                )
                .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .toolbar {
            if #available(macOS 26, *) { ToolbarSpacer(.flexible, placement: .primaryAction) }
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search common questions", text: $query).textFieldStyle(.plain)
                        .accessibilityLabel("Search common questions")
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain).accessibilityLabel("Clear search")
                    }
                }.padding(.horizontal, 10).padding(.vertical, 7).frame(width: 230)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .sheet(isPresented: $showReport) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Support summary").font(.system(size: 22, weight: .semibold))
                ScrollView {
                    Text(report).font(.system(.body, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Text((copied ? "Copied" : "Nothing is uploaded."))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Close") { showReport = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Copy summary") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report, forType: .string)
                        copied = true
                    }.buttonStyle(.borderedProminent)
                }
            }.padding(24).frame(width: 600, height: 480)
        }
    }

}
