import AppKit
import SwiftUI

/// Reads the same official icon packaged in the real app and the isolated preview.
struct NotProtonIcon: View {
    private static let icon: NSImage = {
        if let url = Bundle.main.url(forResource: "NotProton", withExtension: "icns"),
            let image = NSImage(contentsOf: url)
        {
            return image
        }
        return NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }()

    var body: some View {
        Image(nsImage: Self.icon).resizable().scaledToFit().accessibilityHidden(true)
    }
}
