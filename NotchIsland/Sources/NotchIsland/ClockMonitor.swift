import AppKit
import ApplicationServices

/// Mirrors a running timer from Apple's Clock app into the notch.
///
/// The Clock app is sandboxed and has no API, so the countdown is read from what's on screen
/// (Accessibility permission): its Dock icon, which counts down live, and its window when open.
final class ClockMonitor {
    /// Seconds remaining, or nil when no Clock timer is running.
    var onChange: ((TimeInterval?) -> Void)?

    private var timer: Timer?
    private var last: TimeInterval?
    private var loggedOnce = false

    private static let clockBundleIDs = ["com.apple.clock", "com.apple.Clock"]

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.scan()
        }
    }

    private func scan() {
        guard AXIsProcessTrusted() else { return }
        guard let clock = Self.clockBundleIDs
            .compactMap({ NSRunningApplication.runningApplications(withBundleIdentifier: $0).first })
            .first
        else {
            publish(nil)
            return
        }

        // 1. The Dock icon counts down while a timer runs.
        var seconds = dockCountdown(for: clock)

        // 2. Otherwise read the Clock window, if it's open.
        if seconds == nil {
            seconds = windowCountdown(pid: clock.processIdentifier)
        }

        publish(seconds)
    }

    private func publish(_ seconds: TimeInterval?) {
        // Only react to whole-second changes, and ignore a countdown that isn't moving.
        if let s = seconds, let l = last, abs(s - l) < 0.5 { return }
        if seconds == nil && last == nil { return }
        last = seconds
        if let s = seconds {
            notchLog("Clock: timer running, \(Int(s))s left")
        } else {
            notchLog("Clock: no timer")
        }
        onChange?(seconds)
    }

    // MARK: - Sources

    private func dockCountdown(for clock: NSRunningApplication) -> TimeInterval? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.2)

        let clockName = clock.localizedName ?? "Clock"
        var queue = children(app, kAXChildrenAttribute)
        var i = 0
        while i < queue.count && i < 400 {
            let el = queue[i]
            i += 1
            let title = string(el, kAXTitleAttribute) ?? ""
            if title == clockName || title.hasPrefix("Clock") {
                // The countdown shows up as the icon's badge/status label.
                for attribute in ["AXStatusLabel", kAXValueAttribute, kAXDescriptionAttribute, kAXHelpAttribute] {
                    if let text = string(el, attribute), let s = Self.parseCountdown(text) {
                        return s
                    }
                }
                if notchDebugLogging && !loggedOnce {
                    loggedOnce = true
                    let attrs = attributeNames(el)
                    notchLog("Clock: Dock item \"\(title)\" attributes=\(attrs)", sensitive: true)
                }
            }
            queue.append(contentsOf: children(el, kAXChildrenAttribute))
        }
        return nil
    }

    private func windowCountdown(pid: pid_t) -> TimeInterval? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var queue = children(app, kAXWindowsAttribute)
        var i = 0
        var best: TimeInterval?
        while i < queue.count && i < 300 {
            let el = queue[i]
            i += 1
            let role = string(el, kAXRoleAttribute) ?? ""
            if role == kAXStaticTextRole, let value = string(el, kAXValueAttribute),
               let s = Self.parseCountdown(value) {
                // The timer tab shows the largest countdown on screen.
                if best == nil || s > best! { best = s }
            }
            queue.append(contentsOf: children(el, kAXChildrenAttribute))
        }
        return best
    }

    /// "4:59", "1:04:59" or "59" → seconds. Returns nil for anything that isn't a countdown.
    static func parseCountdown(_ text: String) -> TimeInterval? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 9 else { return nil }
        let parts = trimmed.split(separator: ":")
        guard parts.count >= 2, parts.count <= 3 else { return nil }
        var total: TimeInterval = 0
        for part in parts {
            guard let value = Int(part), value >= 0, value < 100 else { return nil }
            total = total * 60 + TimeInterval(value)
        }
        return total > 0 ? total : nil
    }

    // MARK: - AX helpers

    private func string(_ el: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attribute as CFString, &value) == .success else { return nil }
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    private func children(_ el: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return [] }
        return list
    }

    private func attributeNames(_ el: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(el, &names) == .success,
              let list = names as? [String] else { return [] }
        return list
    }
}
