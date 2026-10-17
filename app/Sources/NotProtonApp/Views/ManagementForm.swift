import SwiftUI

struct ManagementForm<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) { content }
                .frame(maxWidth: 780, alignment: .leading)
                .padding(32).frame(maxWidth: .infinity)
        }.background(Color(nsColor: .controlBackgroundColor))
    }
}

struct ManagementSection<Content: View, Header: View, Footer: View>: View {
    let content: Content
    let header: Header
    let footer: Footer
    init(
        @ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header,
        @ViewBuilder footer: () -> Footer
    ) {
        self.content = content()
        self.header = header()
        self.footer = footer()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header.font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 14) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
            footer.font(.system(size: 12)).foregroundStyle(.secondary)
            Divider().padding(.top, 8)
        }
    }
}
extension ManagementSection where Header == EmptyView, Footer == EmptyView {
    init(@ViewBuilder content: () -> Content) {
        self.init(content: content, header: { EmptyView() }, footer: { EmptyView() })
    }
}
extension ManagementSection where Header == Text, Footer == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(content: content, header: { Text(title) }, footer: { EmptyView() })
    }
}

struct DesktopPageHeader: View {
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 20, weight: .semibold)).accessibilityAddTraits(
                    .isHeader)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }.padding(.bottom, 6)
    }
}
