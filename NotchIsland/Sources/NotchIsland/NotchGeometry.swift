import AppKit

/// Where the notch is, in screen coordinates (origin bottom-left, like all AppKit screen math).
struct NotchGeometry: Equatable {
    var screenFrame: CGRect
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var centerX: CGFloat
    var hasNotch: Bool

    var top: CGFloat { screenFrame.maxY }

    /// Reads the real notch from macOS. Falls back to the 14" default (185 × 32 pt)
    /// on Macs or displays without a notch.
    static func detect() -> NotchGeometry {
        let screens = NSScreen.screens
        let notched = screens.first { $0.safeAreaInsets.top > 0 }

        if let s = notched, let left = s.auxiliaryTopLeftArea, let right = s.auxiliaryTopRightArea {
            let f = s.frame
            let width = f.width - left.width - right.width
            return NotchGeometry(
                screenFrame: f,
                notchWidth: width,
                notchHeight: s.safeAreaInsets.top,
                centerX: f.minX + left.width + width / 2,
                hasNotch: true
            )
        }

        let screen = NSScreen.main ?? screens.first
        let f = screen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let menuBar = screen.map { $0.frame.maxY - $0.visibleFrame.maxY } ?? 24
        return NotchGeometry(
            screenFrame: f,
            notchWidth: 185,
            notchHeight: max(menuBar, 24),
            centerX: f.midX,
            hasNotch: false
        )
    }
}
