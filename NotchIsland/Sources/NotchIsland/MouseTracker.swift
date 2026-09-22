import AppKit

/// Hover-to-expand, click-through outside the island, and trackpad swipes:
///   • two-finger swipe UP on the island   → push it back into the notch (hide)
///   • two-finger swipe DOWN on the notch  → bring hidden activities back
///   • two-finger swipe SIDEWAYS           → switch between two activities
final class MouseTracker {
    private let model: IslandModel
    private let panel: NSPanel

    private var monitors: [Any] = []
    private var pollTimer: Timer?
    private var pending: DispatchWorkItem?
    private var pendingTarget: Bool?

    private var accX: CGFloat = 0
    private var accY: CGFloat = 0
    private var fired = false

    init(model: IslandModel, panel: NSPanel) {
        self.model = model
        self.panel = panel
    }

    func start() {
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in
            self?.update()
        }) { monitors.append(m) }

        if let m = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] event in
            self?.update()
            return event
        }) { monitors.append(m) }

        if let m = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel], handler: { [weak self] event in
            self?.scroll(event)
            return event
        }) { monitors.append(m) }

        // Safety net for pointer changes that produce no events (e.g. after the island resizes).
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.update()
        }
    }

    // MARK: - Hover

    func update() {
        let point = NSEvent.mouseLocation
        let inside = model.hitRect().contains(point)

        // Clicks only land on the island; everywhere else passes straight through to the menu bar/apps.
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        if !inside { model.suppressHover = false }

        // Don't collapse in the middle of a drag.
        if NSEvent.pressedMouseButtons != 0 && model.isHovering { return }

        let want = inside && !model.suppressHover
        if want == model.isHovering {
            pending?.cancel()
            pending = nil
            pendingTarget = nil
            return
        }
        if pendingTarget == want { return }

        pending?.cancel()
        pendingTarget = want
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.pendingTarget = nil
            let stillInside = self.model.hitRect().contains(NSEvent.mouseLocation) && !self.model.suppressHover
            guard stillInside == want else { return }
            self.model.isHovering = want
            if want {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (want ? 0.12 : 0.3), execute: work)
    }

    // MARK: - Trackpad swipes

    private func scroll(_ e: NSEvent) {
        guard e.hasPreciseScrollingDeltas, e.momentumPhase.isEmpty else { return }

        if e.phase.contains(.began) {
            accX = 0
            accY = 0
            fired = false
        }

        // Normalise to finger direction regardless of the "natural scrolling" setting.
        let inverted = e.isDirectionInvertedFromDevice
        let fingersUp = inverted ? -e.scrollingDeltaY : e.scrollingDeltaY
        let fingersRight = inverted ? e.scrollingDeltaX : -e.scrollingDeltaX
        accY += fingersUp
        accX += fingersRight

        if !fired {
            if accY > 45 {
                fired = true
                model.hideCurrent()
                model.squeeze = 0
            } else if accY < -45 {
                fired = true
                model.squeeze = 0
                model.unhideAll()
            } else if abs(accX) > 70 && abs(accX) > abs(accY) * 1.5 {
                fired = true
                model.switchActivity()
            } else if accY > 0, model.presentation != .idle {
                // Island follows the fingers into the notch.
                model.squeeze = min(accY / 45, 1) * 0.5
            }
        }

        if e.phase.contains(.ended) || e.phase.contains(.cancelled) {
            if model.squeeze != 0 { model.squeeze = 0 }
        }
    }
}
