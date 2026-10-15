import AppKit
import ApplicationServices

struct AirDropRequest: Equatable {
    var key: String
    var sender: String
    var detail: String
    var progress: Double?      // 0…1 while receiving
    var isTest = false
}

struct SystemNotification: Equatable {
    let id: String
    var appName: String
    var title: String
    var body: String
    var icon: NSImage?
}

/// Mirrors macOS notification banners into the notch.
/// Reads the banners Notification Center shows via the Accessibility API (same permission as calls).
/// Optionally closes the Mac banner once it's in the notch ("Hide Mac banners" in the right-click menu).
final class NotificationMonitor {
    var onNew: ((SystemNotification) -> Void)?
    /// Incoming AirDrop, or nil when the banner is gone.
    var onAirDrop: ((AirDropRequest?) -> Void)?

    /// When on, the macOS banner is closed as soon as the notch shows it.
    var hideMacBanners: Bool {
        get { UserDefaults.standard.bool(forKey: "hideMacBanners") }
        set { UserDefaults.standard.set(newValue, forKey: "hideMacBanners") }
    }

    private var timer: Timer?
    private var seen: [String: Date] = [:]
    private var primed = false
    private var elementsByID: [String: AXUIElement] = [:]
    private var lastLogKey = ""

    private struct Found {
        var key: String
        var element: AXUIElement
        var texts: [String]
        var description: String
        var isCall: Bool
        var isAirDrop: Bool
        var accept: (element: AXUIElement, action: String)?
        var decline: (element: AXUIElement, action: String)?
        var progress: Double?
    }

    private var airDropAccept: (element: AXUIElement, action: String)?
    private var airDropDecline: (element: AXUIElement, action: String)?
    private var lastAirDrop: AirDropRequest?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.scan()
        }
    }

    /// Clicking the notification in the notch = clicking the Mac banner (opens the app / conversation).
    func open(_ n: SystemNotification) {
        guard let el = elementsByID[n.id] else { return }
        AXUIElementPerformAction(el, kAXPressAction as CFString)
    }

    // MARK: - Scanning

    private func scan() {
        guard AXIsProcessTrusted(),
              let nc = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first
        else { return }

        let app = AXUIElementCreateApplication(nc.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.2)

        var found: [Found] = []
        var budget = 900
        for root in children(app, kAXWindowsAttribute) {
            _ = collect(root, depth: 0, into: &found, budget: &budget)
        }

        let now = Date()
        // Many notifications at once = the Notification Center panel is open (history), not new banners.
        let panelOpen = found.count > 4

        // Incoming AirDrop gets its own presentation in the notch.
        if let drop = found.first(where: { $0.isAirDrop }) {
            airDropAccept = drop.accept
            airDropDecline = drop.decline
            let request = makeAirDrop(drop)
            if request != lastAirDrop {
                lastAirDrop = request
                notchLog("AirDrop: incoming banner (progress=\(request.progress.map { String(format: "%.0f%%", $0 * 100) } ?? "-"))")
                onAirDrop?(request)
            }
            for f in found { seen[f.key] = now }
            primed = true
            return
        } else if lastAirDrop != nil {
            lastAirDrop = nil
            airDropAccept = nil
            airDropDecline = nil
            notchLog("AirDrop: banner gone")
            onAirDrop?(nil)
        }

        for f in found {
            let isNew = seen[f.key] == nil
            seen[f.key] = now
            guard isNew, primed, !panelOpen, !f.isCall else { continue }

            let n = makeNotification(f)
            elementsByID[n.id] = f.element
            logStructure(f)
            onNew?(n)
            if hideMacBanners { close(f.element) }
        }

        // Forget banners that have been gone for a while, so a repeat later shows again.
        seen = seen.filter { now.timeIntervalSince($0.value) < 90 }
        if elementsByID.count > 50 { elementsByID.removeAll() }
        primed = true
    }

    /// Depth-first walk. Returns true if this subtree contains a notification.
    /// Only the innermost notification groups are collected (not the stacks that contain them).
    private func collect(_ el: AXUIElement, depth: Int, into found: inout [Found], budget: inout Int) -> Bool {
        guard budget > 0, depth < 16 else { return false }
        budget -= 1

        let subrole = (string(el, kAXSubroleAttribute) ?? "").lowercased()
        let isNotification = subrole.contains("notification")

        var childHasNotification = false
        for child in children(el, kAXChildrenAttribute) {
            if collect(child, depth: depth + 1, into: &found, budget: &budget) { childHasNotification = true }
        }

        if isNotification && !childHasNotification {
            let texts = staticTexts(in: el)
            let desc = string(el, kAXDescriptionAttribute) ?? ""
            if !texts.isEmpty || !desc.isEmpty {
                let (accept, decline) = acceptDeclineTargets(in: el)
                let hasChoice = accept != nil && decline != nil
                let haystack = (desc + " " + texts.joined(separator: " ")).lowercased()
                let isAirDrop = haystack.contains("airdrop")
                let key = desc + "|" + texts.joined(separator: "|")
                found.append(Found(key: key, element: el, texts: texts, description: desc,
                                   isCall: hasChoice && !isAirDrop, isAirDrop: isAirDrop,
                                   accept: accept, decline: decline,
                                   progress: isAirDrop ? progressValue(in: el) : nil))
            }
        }
        return isNotification || childHasNotification
    }

    /// Accept / Decline on a banner: either buttons, or custom actions ("Name:Accept\nTarget:…").
    private func acceptDeclineTargets(in root: AXUIElement)
        -> ((element: AXUIElement, action: String)?, (element: AXUIElement, action: String)?) {
        var accept: (element: AXUIElement, action: String)?
        var decline: (element: AXUIElement, action: String)?
        var queue = [root]
        var i = 0
        while i < queue.count && i < 80 {
            let el = queue[i]
            i += 1
            if string(el, kAXRoleAttribute) == kAXButtonRole {
                let title = string(el, kAXTitleAttribute) ?? ""
                let label = (title.isEmpty ? (string(el, kAXDescriptionAttribute) ?? "") : title).lowercased()
                if accept == nil, label.hasPrefix("accept") || label.hasPrefix("save") || label.hasPrefix("open") {
                    accept = (el, kAXPressAction)
                } else if decline == nil, label.hasPrefix("decline") || label.hasPrefix("reject") {
                    decline = (el, kAXPressAction)
                }
            }
            for action in actionNames(el) {
                let lower = action.lowercased()
                if accept == nil, lower.contains("name:accept") || lower.contains("name:save") || lower.contains("name:open") {
                    accept = (el, action)
                } else if decline == nil, lower.contains("name:decline") {
                    decline = (el, action)
                }
            }
            queue.append(contentsOf: children(el, kAXChildrenAttribute))
        }
        return (accept, decline)
    }

    /// Transfer progress, if the banner shows a progress bar.
    private func progressValue(in root: AXUIElement) -> Double? {
        var queue = [root]
        var i = 0
        while i < queue.count && i < 80 {
            let el = queue[i]
            i += 1
            if string(el, kAXRoleAttribute) == kAXProgressIndicatorRole {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &value) == .success,
                   let number = value as? NSNumber {
                    let v = number.doubleValue
                    return v > 1 ? min(v / 100, 1) : max(0, min(v, 1))
                }
            }
            queue.append(contentsOf: children(el, kAXChildrenAttribute))
        }
        return nil
    }

    private func staticTexts(in root: AXUIElement) -> [String] {
        var out: [String] = []
        var queue = [root]
        var i = 0
        while i < queue.count && i < 60 {
            let el = queue[i]
            i += 1
            if string(el, kAXRoleAttribute) == kAXStaticTextRole, let v = string(el, kAXValueAttribute) {
                let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty && !out.contains(t) { out.append(t) }
            }
            queue.append(contentsOf: children(el, kAXChildrenAttribute))
        }
        return out
    }

    private func makeNotification(_ f: Found) -> SystemNotification {
        var texts = f.texts
        var appName = ""
        var icon: NSImage?

        // The app is usually named in the banner's description ("Messages, Anna, See you soon")
        // or as one of its texts. Match it against running apps to get the icon.
        let candidates = f.description.components(separatedBy: ", ").prefix(2) + texts.prefix(2)
        for c in candidates {
            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == c }) {
                appName = c
                icon = app.icon
                break
            }
        }
        if !appName.isEmpty, let i = texts.firstIndex(of: appName) { texts.remove(at: i) }

        var title = texts.first ?? ""
        var body = texts.dropFirst().joined(separator: " ")
        if title.isEmpty {
            // Fall back to the description: "App, Title, Body"
            var parts = f.description.components(separatedBy: ", ")
            if !appName.isEmpty, parts.first == appName { parts.removeFirst() }
            title = parts.first ?? "Notification"
            body = parts.dropFirst().joined(separator: ", ")
        }

        return SystemNotification(id: UUID().uuidString, appName: appName, title: title, body: body, icon: icon)
    }

    private func makeAirDrop(_ f: Found) -> AirDropRequest {
        let texts = f.texts.filter { $0.lowercased() != "airdrop" }
        let sender = texts.first ?? "AirDrop"
        let detail = texts.count > 1 ? texts[1] : (f.progress != nil ? "Receiving…" : "Wants to share")
        return AirDropRequest(key: f.key, sender: sender, detail: detail, progress: f.progress)
    }

    func acceptAirDrop() {
        guard let t = airDropAccept else { return }
        AXUIElementPerformAction(t.element, t.action as CFString)
    }

    func declineAirDrop() {
        guard let t = airDropDecline else { return }
        AXUIElementPerformAction(t.element, t.action as CFString)
    }

    private func close(_ el: AXUIElement) {
        for action in actionNames(el) where action.lowercased().contains("name:close") {
            AXUIElementPerformAction(el, action as CFString)
            return
        }
    }

    private func logStructure(_ f: Found) {
        guard notchDebugLogging else { return }
        let key = f.description + f.texts.joined()
        guard key != lastLogKey else { return }
        lastLogKey = key
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] Notification: description=\"\(f.description)\" texts=\(f.texts) actions=\(actionNames(f.element).map { $0.replacingOccurrences(of: "\n", with: " | ") })\n"
        let url = CallMonitor.logURL
        if let h = try? FileHandle(forWritingTo: url), let d = line.data(using: .utf8) {
            h.seekToEndOfFile()
            h.write(d)
            try? h.close()
        }
    }

    // MARK: - AX helpers

    private func string(_ el: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func children(_ el: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return [] }
        return list
    }

    private func actionNames(_ el: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(el, &names) == .success,
              let list = names as? [String] else { return [] }
        return list
    }
}
