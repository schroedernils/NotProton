import AppKit
import SwiftUI

struct InstalledAppIcon: View {
    let url: URL
    let fallback: String
    var body: some View {
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false)))
                .resizable().aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: fallback).resizable().scaledToFit().foregroundStyle(.secondary)
        }
    }
}
