import AppKit
import ApplicationServices

struct IncomingCall: Equatable {
    var name: String
    var detail: String
    var appBundleID: String?
    var isTest = false
}

/// Detects incoming calls by reading the call banner/window macOS shows (FaceTime, iPhone calls via
/// Continuity, the Phone app, WhatsApp, Zoom, Teams…) through the Accessibility API, and presses that
/// banner's real Accept / Decline buttons when you use the notch.
///
/// Needs: System Settings → Privacy & Security → Accessibility → NotchIsland.
/// Anything call-like it sees is written to ~/Library/Logs/NotchIsland.log for troubleshooting.
final class CallMonitor {
    var onChange: ((IncomingCall?) -> Void)?

    private var timer: Timer?
    private var last: IncomingCall?
    private var acceptTarget: (element: AXUIElement, action: String)?
    private var declineTarget: (element: AXUIElement, action: String)?
    private var lastLogKey = ""

    private static let acceptWords = ["accept", "answer", "join", "pick up", "annehmen", "accepter", "aceptar", "rispondi"]
    private static let declineWords = ["decline", "reject", "ignore", "hang up", "ablehnen", "refuser", "rechazar", "rifiuta"]
    private static let callWords = ["call", "facetime", "audio", "video", "ringing", "iphone", "calling", "anruf", "appel", "llamada", "chiamata"]

    /// Labels that name the calling app rather than the caller.
    private static let appLabels: [String: String] = [
        "facetime": "com.apple.FaceTime", "phone": "com.apple.mobilephone", "iphone": "com.apple.FaceTime",
        "whatsapp": "net.whatsapp.WhatsApp", "zoom": "us.zoom.xos", "zoom workplace": "us.zoom.xos",
        "microsoft teams": "com.microsoft.teams2", "teams": "com.microsoft.teams2",
        "discord": "com.hnc.Discord", "slack": "com.tinyspeck.slackmacgap",
        "telegram": "ru.keepcoder.Telegram", "signal": "org.whispersystems.signal-desktop",
        "skype": "com.skype.skype", "messenger": "com.facebook.archon",
    ]

    /// Apps whose own (normal-level) windows can be incoming-call windows.
    private static let callAppBundles: Set<String> = [
        "com.apple.FaceTime", "com.apple.mobilephone", "net.whatsapp.WhatsApp", "us.zoom.xos",
        "com.microsoft.teams2", "com.microsoft.teams", "com.hnc.Discord", "com.tinyspeck.slackmacgap",
        "ru.keepcoder.Telegram", "org.whispersystems.signal-desktop", "com.skype.skype", "com.facebook.archon",
    ]

    /// Never inspected (menu bar, Dock, wallpaper…).
    private static let ignoredOwners: Set<String> = [
        "Window Server", "Dock", "SystemUIServer", "Control Center", "Spotlight", "NotchIsland",
        "Wallpaper", "TextInputMenuAgent", "Screenshot", "WindowManager",
    ]

    /// Standard actions every element has; anything else is a custom (notification) action.
    private static let standardActions: Set<String> = [
        "AXPress", "AXShowMenu", "AXRaise", "AXScrollToVisible", "AXCancel", "AXConfirm",
        "AXIncrement", "AXDecrement", "AXShowDefaultUI", "AXShowAlternateUI", "AXZoomWindow",
    ]

    static var logURL: URL { notchLogURL }

    var isTrusted: Bool { AXIsProcessTrusted() }

    func start() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        log("NotchIsland started. Accessibility allowed: \(trusted)")

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.scan()
        }
    }

    func accept() { perform(acceptTarget, "Accept") }
    func decline() { perform(declineTarget, "Decline") }

    private func perform(_ target: (element: AXUIElement, action: String)?, _ label: String) {
        guard let t = target else {
            log("\(label) pressed in the notch, but no call banner button was found")
            return
        }
        let result = AXUIElementPerformAction(t.element, t.action as CFString)
        log("\(label) → \(t.action) result \(result.rawValue)")
    }

    // MARK: - Scanning

    private func scan() {
        guard AXIsProcessTrusted() else {
            publish(nil)
            return
        }

        var found: IncomingCall?
        for (pid, info) in candidateApps() {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.2)

            var roots = elements(app, kAXWindowsAttribute)
            if info.isNotificationCenter {
                // Banners aren't always exposed as windows.
                for child in elements(app, kAXChildrenAttribute) where !roots.contains(where: { CFEqual($0, child) }) {
                    roots.append(child)
                }
            } else {
                // Skip big windows (main app windows) — call banners are small.
                roots = roots.filter { w in
                    guard let s = size(w) else { return true }
                    return s.width < 900 && s.height < 450
                }
            }

            for root in roots {
                if let call = inspect(root, owner: info.name) {
                    found = call
                    break
                }
            }
            if found != nil { break }
        }

        if found == nil {
            acceptTarget = nil
            declineTarget = nil
        }
        publish(found)
    }

    private struct Candidate {
        var name: String
        var isNotificationCenter: Bool
    }

    /// Notification Center, plus any app that currently shows a small floating window
    /// (or a small window of a known calling app).
    private func candidateApps() -> [(pid_t, Candidate)] {
        var result: [pid_t: Candidate] = [:]
        if let nc = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first {
            result[nc.processIdentifier] = Candidate(name: "NotificationCenter", isNotificationCenter: true)
        }

        let me = ProcessInfo.processInfo.processIdentifier
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return result.map { ($0.key, $0.value) }
        }

        for w in list {
            guard let pidNumber = w[kCGWindowOwnerPID as String] as? NSNumber else { continue }
            let pid = pid_t(pidNumber.int32Value)
            if pid == me || result[pid] != nil { continue }

            let owner = (w[kCGWindowOwnerName as String] as? String) ?? ""
            if Self.ignoredOwners.contains(owner) { continue }

            let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            if layer == 20 || layer == 24 || layer == 25 { continue }   // Dock, menu bar, menu bar icons

            var bounds = CGRect.zero
            if let b = w[kCGWindowBounds as String] {
                bounds = CGRect(dictionaryRepresentation: b as! CFDictionary) ?? .zero
            }
            let small = bounds.width > 40 && bounds.width < 900 && bounds.height > 20 && bounds.height < 450
            guard small else { continue }

            let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
            let isCallApp = Self.callAppBundles.contains(bundle)
                || owner.lowercased().contains("call")
                || owner.lowercased().contains("phone")
                || owner.lowercased().contains("facetime")
            if layer > 0 || isCallApp {
                result[pid] = Candidate(name: owner.isEmpty ? bundle : owner, isNotificationCenter: false)
            }
        }
        return result.map { ($0.key, $0.value) }
    }

    private func publish(_ call: IncomingCall?) {
        guard call != last else { return }
        last = call
        if let c = call {
            log("Incoming call detected (app=\(c.appBundleID ?? "?"))")
            log("  caller: \"\(c.name)\" · \"\(c.detail)\"", sensitive: true)
        } else {
            log("Call banner gone")
        }
        onChange?(call)
    }

    private func inspect(_ root: AXUIElement, owner: String) -> IncomingCall? {
        var queue: [AXUIElement] = [root]
        var index = 0
        var texts: [String] = []
        var buttonLabels: [String] = []
        var customActions: [String] = []
        var accept: (element: AXUIElement, action: String)?
        var decline: (element: AXUIElement, action: String)?

        while index < queue.count && index < 500 {
            let el = queue[index]
            index += 1

            let role = string(el, kAXRoleAttribute) ?? ""
            if role == kAXStaticTextRole || role == kAXTextFieldRole,
               let v = string(el, kAXValueAttribute) {
                let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty && t.count < 120 { texts.append(t) }
            }
            // Some banners put the text in the element's title/description instead.
            if role == kAXGroupRole, let d = string(el, kAXDescriptionAttribute), !d.isEmpty, d.count < 160 {
                texts.append(d)
            }

            if role == kAXButtonRole {
                let title = string(el, kAXTitleAttribute) ?? ""
                let label = (title.isEmpty ? (string(el, kAXDescriptionAttribute) ?? "") : title)
                if !label.isEmpty { buttonLabels.append(label) }
                let lower = label.lowercased()
                if accept == nil, Self.matches(lower, Self.acceptWords) {
                    accept = (el, kAXPressAction)
                } else if decline == nil, Self.matches(lower, Self.declineWords) {
                    decline = (el, kAXPressAction)
                }
            }

            // Notification actions are often custom actions: "Name:Accept\nTarget:…"
            for action in actionNames(el) where !Self.standardActions.contains(action) {
                customActions.append(action.replacingOccurrences(of: "\n", with: " | "))
                let name = Self.customActionName(action)
                if accept == nil, Self.matches(name, Self.acceptWords) {
                    accept = (el, action)
                } else if decline == nil, Self.matches(name, Self.declineWords) {
                    decline = (el, action)
                }
            }

            queue.append(contentsOf: elements(el, kAXChildrenAttribute))
        }

        // Log anything with buttons or custom actions, once per distinct banner.
        if !buttonLabels.isEmpty || !customActions.isEmpty {
            let key = owner + texts.joined() + buttonLabels.joined() + customActions.joined()
            if key != lastLogKey {
                lastLogKey = key
                log("""
                Window from \(owner)
                  texts:   \(texts.prefix(12))
                  buttons: \(buttonLabels.prefix(12))
                  actions: \(customActions.prefix(12))
                """, sensitive: true)
            }
        }

        guard let a = accept, let d = decline else { return nil }
        // AirDrop banners also have Accept / Decline — they belong to the AirDrop view.
        if texts.contains(where: { $0.lowercased().contains("airdrop") }) { return nil }

        var appID: String?
        var rest: [String] = []
        for t in texts {
            let lower = t.lowercased()
            if Self.matches(lower, Self.acceptWords + Self.declineWords) { continue }
            if appID == nil, let id = Self.appLabels[lower] {
                appID = id
                continue
            }
            if !rest.contains(t) { rest.append(t) }
        }

        // Guard against look-alikes such as calendar invites (they also have Accept / Decline).
        let ownerLower = owner.lowercased()
        let looksLikeCall = appID != nil
            || ownerLower.contains("facetime") || ownerLower.contains("phone") || ownerLower.contains("call")
            || texts.contains { t in Self.callWords.contains { t.lowercased().contains($0) } }
        guard looksLikeCall else { return nil }

        acceptTarget = a
        declineTarget = d

        let name = rest.first ?? "Incoming call"
        var detail = rest.count > 1 ? rest[1] : "Incoming call"
        if detail.count > 40 { detail = String(detail.prefix(40)) + "…" }
        return IncomingCall(name: name, detail: detail, appBundleID: appID)
    }

    private static func matches(_ label: String, _ words: [String]) -> Bool {
        words.contains { label == $0 || label.hasPrefix($0 + " ") }
    }

    private static func customActionName(_ action: String) -> String {
        let lower = action.lowercased()
        guard let r = lower.range(of: "name:") else { return lower }
        let after = lower[r.upperBound...]
        let firstLine = after.split(separator: "\n").first.map(String.init) ?? ""
        return firstLine.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - AX helpers

    private func string(_ el: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func elements(_ el: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return [] }
        return list
    }

    private func size(_ el: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        guard AXValueGetValue(v as! AXValue, .cgSize, &s) else { return nil }
        return s
    }

    private func actionNames(_ el: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(el, &names) == .success,
              let list = names as? [String] else { return [] }
        return list
    }

    // MARK: - Log

    func log(_ message: String, sensitive: Bool = false) {
        notchLog(message, sensitive: sensitive)
    }
}
