import AppKit
import SwiftUI

private final class OnboardingWindow: NSWindow {
    var escape: () -> Void = {}
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { escape() } else { super.keyDown(with: event) }
    }
}

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()
    private var window: OnboardingWindow?
    private weak var parent: NSWindow?
    private weak var launchWindow: NSWindow?
    private var launchPending = true
    private var coordinator: OnboardingCoordinator?
    private var launchDisplayID: NSNumber?

    func prepareLaunchWindow(_ window: NSWindow) {
        guard launchPending else { return }
        launchWindow = window
        window.alphaValue = 0
    }
    func resolveLaunch(showMain: Bool) {
        launchPending = false
        if showMain {
            launchWindow?.alphaValue = 1
            launchWindow?.makeKeyAndOrderFront(nil)
        } else {
            launchWindow?.orderOut(nil)
        }
    }
    func captureLaunchDisplay() {
        let screens = NSScreen.screens
        if let index = OnboardingDisplaySelection.index(
            frames: screens.map(\.frame), pointer: NSEvent.mouseLocation, owner: nil, manual: false)
        {
            launchDisplayID =
                screens[index].deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        }
    }
    func present(status: SystemStatus, manual: Bool, onClose: @escaping (Bool) -> Void) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let invoking = NSApp.keyWindow ?? launchWindow ?? NSApp.windows.first { $0.isVisible }
        let owner = invoking === window ? (parent ?? launchWindow) : invoking
        let screens = NSScreen.screens
        let ownerIndex = screens.firstIndex { $0 === invoking?.screen }
        let selected = OnboardingDisplaySelection.index(
            frames: screens.map(\.frame), pointer: NSEvent.mouseLocation, owner: ownerIndex, manual: manual)
        let captured = screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber) == launchDisplayID
        }
        guard let screen = (!manual ? captured : nil) ?? selected.map({ screens[$0] }) else { return }
        close(restoreParent: false)
        parent = owner
        let c = OnboardingCoordinator(snapshot: status.snapshot, operations: liveOperations(status: status))
        c.onClose = { [weak self] settings in
            self?.close(restoreParent: settings)
            onClose(settings)
        }
        coordinator = c
        c.start()
        let visible = screen.visibleFrame
        let width = min(760, visible.width - 40)
        let height = min(540, visible.height - 40)
        let frame = NSRect(
            x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height)
        let w = OnboardingWindow(
            contentRect: NSRect(origin: .zero, size: frame.size),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false,
            screen: screen)
        w.setFrame(frame, display: false)
        w.title = "NotProton Setup"
        w.backgroundColor = .windowBackgroundColor
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 740, height: 510)
        w.delegate = self
        w.escape = { [weak c] in if c?.isBusy == false { c?.finish(settings: false) } }
        w.contentView = NSHostingView(rootView: OnboardingView(coordinator: c).environment(status))
        window = w
        parent?.orderOut(nil)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard coordinator?.isBusy != true else { return false }
        coordinator?.finish(settings: false)
        return false
    }
    func close(restoreParent: Bool = true) {
        coordinator?.suspend()
        window?.delegate = nil
        window?.close()
        window = nil
        coordinator = nil
        if restoreParent {
            parent?.alphaValue = 1
            parent?.makeKeyAndOrderFront(nil)
        } else {
            parent?.orderOut(nil)
            parent?.alphaValue = 1
        }
    }
}

struct OnboardingLaunchGate: NSViewRepresentable {
    final class GateView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { OnboardingWindowController.shared.prepareLaunchWindow(window) }
        }
    }
    func makeNSView(context: Context) -> GateView { GateView() }
    func updateNSView(_ nsView: GateView, context: Context) {}
}
