import CoreGraphics

/// Automatic launch follows the launch pointer, manual replay follows its owning window.
enum OnboardingDisplaySelection {
    static func index(frames: [CGRect], pointer: CGPoint, owner: Int?, manual: Bool) -> Int? {
        if manual, let owner, frames.indices.contains(owner) { return owner }
        if let pointed = frames.firstIndex(where: { $0.contains(pointer) }) { return pointed }
        if let owner, frames.indices.contains(owner) { return owner }
        return frames.isEmpty ? nil : 0
    }
}
