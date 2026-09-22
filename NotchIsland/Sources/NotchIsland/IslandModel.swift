import SwiftUI
import AppKit
import CoreImage

enum ActivityKind: String, Hashable {
    case call, media, timer, files
}

enum ExpandedContent: Equatable {
    case home, media, timer, call, files
}

enum IslandAlert: Equatable {
    case charging(Int)
    case lowBattery(Int)
    case bluetooth(name: String, connected: Bool, audio: Bool)
    case timerDone
    case notification(SystemNotification)

    var isNotification: Bool {
        if case .notification(_) = self { return true }
        return false
    }

    /// Banners drop down below the notch; the rest are compact (either side of the notch).
    var isBanner: Bool {
        switch self {
        case .bluetooth, .timerDone, .notification: return true
        default: return false
        }
    }

    var key: String {
        switch self {
        case .charging: return "charging"
        case .lowBattery: return "low"
        case .bluetooth(let name, let connected, _): return "bt-\(name)-\(connected)"
        case .timerDone: return "timerdone"
        case .notification(let n): return "notif-\(n.id)"
        }
    }
}

enum Presentation: Equatable {
    case idle
    case incomingCall(IncomingCall)
    case airdrop(AirDropRequest)
    case compact(ActivityKind)
    case alert(IslandAlert)
    case expanded(ExpandedContent)

    var key: String {
        switch self {
        case .idle: return "idle"
        case .incomingCall: return "incoming-call"
        case .airdrop: return "airdrop"
        case .compact(let k): return "compact-\(k.rawValue)"
        case .alert(let a): return "alert-\(a.key)"
        case .expanded(let c): return "expanded-\(c)"
        }
    }
}

struct IslandSize: Equatable {
    var width: CGFloat        // body width (between the shoulders)
    var height: CGFloat
    var bottomRadius: CGFloat
    var flare: CGFloat        // shoulder size; total drawn width = width + 2 * flare
}

struct TimerState: Equatable {
    var total: TimeInterval
    var endDate: Date?                // nil while paused
    var pausedRemaining: TimeInterval

    var isPaused: Bool { endDate == nil }

    func remaining(at now: Date) -> TimeInterval {
        if let end = endDate { return max(0, end.timeIntervalSince(now)) }
        return pausedRemaining
    }
}

struct ActiveCall: Equatable {
    var name: String
    var appBundleID: String?
    var startedAt: Date
}

struct BatteryState: Equatable {
    var percent: Int
    var charging: Bool
    var pluggedIn: Bool
}

/// All island state lives here. Views read it; monitors and gestures write it.
final class IslandModel: ObservableObject {
    // Geometry
    @Published var geometry: NotchGeometry
    var windowWidth: CGFloat = 680

    // Interaction
    @Published var isHovering = false
    @Published var squeeze: CGFloat = 0          // 0…1, how far the island is being pushed back into the notch
    @Published var hidden: Set<ActivityKind> = []
    @Published var swapped = false
    var suppressHover = false                    // after a swipe-to-hide, ignore hover until the pointer leaves

    // Activities & events
    @Published var media: MediaInfo?
    @Published var artwork: NSImage?
    @Published var accent: Color = Color(white: 0.92)
    @Published var timer: TimerState?
    @Published var alert: IslandAlert?
    @Published var cameraOn = false
    @Published var micOn = false
    @Published var battery: BatteryState?
    @Published var browserHint: String?
    @Published var incomingCall: IncomingCall?
    @Published var activeCall: ActiveCall?
    @Published var airdrop: AirDropRequest?
    @Published var shelf: [URL] = []
    @Published var dropTargeted = false
    @Published var now = Date()

    weak var mediaService: MediaService?
    weak var callMonitor: CallMonitor?
    weak var notificationMonitor: NotificationMonitor?
    private var pendingCall: (call: IncomingCall, until: Date)?
    private var micOffSince: Date?
    private var shelfAddedAt: Date?
    private var ignoreCallBannerUntil = Date.distantPast
    private(set) var lastPlayingAt = Date.distantPast
    private var alertWork: DispatchWorkItem?
    private var artworkKey: String?

    /// Width added on each side of the notch in the compact state.
    let side: CGFloat = 44

    init(geometry: NotchGeometry) {
        self.geometry = geometry
    }

    // MARK: - Derived state

    var mediaActive: Bool {
        guard let m = media else { return false }
        return m.isPlaying || now.timeIntervalSince(lastPlayingAt) < 45
    }

    /// Running activities in priority order: call, then timer, then media.
    var activeKinds: [ActivityKind] {
        var kinds: [ActivityKind] = []
        if activeCall != nil { kinds.append(.call) }
        if !shelf.isEmpty { kinds.append(.files) }
        if timer != nil { kinds.append(.timer) }
        if mediaActive { kinds.append(.media) }
        return kinds
    }

    var visibleKinds: [ActivityKind] {
        var kinds = activeKinds.filter { !hidden.contains($0) }
        if swapped && kinds.count > 1 { kinds.reverse() }
        return kinds
    }

    var presentation: Presentation {
        if let call = incomingCall { return .incomingCall(call) }   // always on top, like iPhone
        if let drop = airdrop { return .airdrop(drop) }
        if dropTargeted { return .expanded(.files) }                // files being dragged onto the notch
        if let a = alert, a.isNotification { return .alert(a) }     // stays put while you move to click it
        if isHovering {
            switch visibleKinds.first {
            case .some(.call): return .expanded(.call)
            case .some(.files): return .expanded(.files)
            case .some(.media): return .expanded(.media)
            case .some(.timer): return .expanded(.timer)
            case .none: return .expanded(.home)
            }
        }
        if let a = alert { return .alert(a) }
        if let k = visibleKinds.first { return .compact(k) }
        return .idle
    }

    /// Second activity shown as a small circle beside the compact island.
    var secondaryKind: ActivityKind? {
        if case .compact(_) = presentation, visibleKinds.count > 1 { return visibleKinds[1] }
        return nil
    }

    var privacyActive: Bool { cameraOn || micOn }

    // MARK: - Sizes (all relative to the real notch)

    var targetSize: IslandSize {
        let nw = geometry.notchWidth
        let nh = geometry.notchHeight
        switch presentation {
        case .idle:
            if privacyActive {
                return IslandSize(width: nw + 36, height: nh, bottomRadius: 12, flare: 6)
            }
            return IslandSize(width: nw - 2, height: nh, bottomRadius: 9, flare: 0)
        case .incomingCall(_):
            return IslandSize(width: max(nw + 230, 410), height: nh + 62, bottomRadius: 24, flare: 8)
        case .airdrop(_):
            return IslandSize(width: max(nw + 230, 410), height: nh + 66, bottomRadius: 24, flare: 8)
        case .compact(_):
            return IslandSize(width: nw + side * 2, height: nh + 6, bottomRadius: 13, flare: 6)
        case .alert(let a):
            if a.isNotification {
                return IslandSize(width: max(nw + 250, 430), height: nh + 74, bottomRadius: 24, flare: 8)
            }
            if a.isBanner {
                return IslandSize(width: max(nw + 200, 380), height: nh + 54, bottomRadius: 22, flare: 8)
            }
            return IslandSize(width: nw + side * 2, height: nh + 6, bottomRadius: 13, flare: 6)
        case .expanded(let content):
            let extra: CGFloat
            switch content {
            case .media: extra = 140
            case .timer: extra = 84
            case .call: extra = 84
            case .files: extra = 104
            case .home: extra = 92
            }
            return IslandSize(width: max(nw + 230, 410), height: nh + extra, bottomRadius: 26, flare: 8)
        }
    }

    /// What's actually drawn: the target size, pulled toward the notch while being swiped in.
    var displaySize: IslandSize {
        var s = targetSize
        guard squeeze > 0 else { return s }
        let nw = geometry.notchWidth
        let nh = geometry.notchHeight
        s.width += (nw - s.width) * squeeze
        s.height += (nh - s.height) * squeeze
        return s
    }

    /// The area (screen coordinates) that reacts to the pointer.
    func hitRect() -> CGRect {
        let g = geometry
        if case .idle = presentation, !privacyActive {
            return CGRect(x: g.centerX - g.notchWidth / 2, y: g.top - g.notchHeight,
                          width: g.notchWidth, height: g.notchHeight)
        }
        let s = targetSize
        let total = s.width + 2 * s.flare
        var r = CGRect(x: g.centerX - total / 2, y: g.top - s.height, width: total, height: s.height)
        if secondaryKind != nil {
            let d = s.height
            r = r.union(CGRect(x: g.centerX + s.width / 2 + 6, y: g.top - d, width: d, height: d))
        }
        if isHovering { r = r.insetBy(dx: -10, dy: -12) }
        return r
    }

    // MARK: - Actions

    func hideCurrent() {
        switch presentation {
        case .expanded(let content):
            if content == .media { hidden.insert(.media) }
            if content == .timer { hidden.insert(.timer) }
            if content == .call { hidden.insert(.call) }
            if content == .files { hidden.insert(.files) }
            suppressHover = true
            isHovering = false
        case .compact(let kind):
            hidden.insert(kind)
        case .alert(_):
            alertWork?.cancel()
            alert = nil
        case .idle, .incomingCall(_), .airdrop(_):
            break   // a call or AirDrop needs Accept or Decline
        }
    }

    func unhideAll() {
        if !hidden.isEmpty { hidden.removeAll() }
    }

    func switchActivity() {
        if visibleKinds.count > 1 { swapped.toggle() }
    }

    func show(_ a: IslandAlert, duration: TimeInterval = 2.2) {
        alertWork?.cancel()
        alert = a
        scheduleAlertEnd(a, after: duration)
    }

    /// Alerts disappear after `duration`, but not while the pointer is over them.
    private func scheduleAlertEnd(_ a: IslandAlert, after duration: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.alert == a else { return }
            if self.isHovering && a.isNotification {
                self.scheduleAlertEnd(a, after: 1.5)
            } else {
                self.alert = nil
            }
        }
        alertWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func showNotification(_ n: SystemNotification) {
        guard incomingCall == nil else { return }
        show(.notification(n), duration: 5)
    }

    func openNotification(_ n: SystemNotification) {
        notificationMonitor?.open(n)
        alertWork?.cancel()
        alert = nil
    }

    // MARK: - Timer

    func startTimer(minutes: Double) {
        let total = minutes * 60
        timer = TimerState(total: total, endDate: Date().addingTimeInterval(total), pausedRemaining: 0)
        hidden.remove(.timer)
        swapped = false
    }

    func toggleTimerPause() {
        guard var t = timer else { return }
        if let end = t.endDate {
            t.pausedRemaining = max(0, end.timeIntervalSinceNow)
            t.endDate = nil
        } else {
            t.endDate = Date().addingTimeInterval(t.pausedRemaining)
        }
        timer = t
    }

    func cancelTimer() {
        timer = nil
    }

    /// Called once a second.
    func tick() {
        now = Date()
        updateCallState()
        if let added = shelfAddedAt, now.timeIntervalSince(added) > 600 { clearShelf() }   // 10 minutes
        if let t = timer, let end = t.endDate, end <= now {
            timer = nil
            show(.timerDone, duration: 4)
            NSSound(named: NSSound.Name("Glass"))?.play()
        }
    }

    // MARK: - Calls

    func setIncomingCall(_ call: IncomingCall?) {
        guard Date() >= ignoreCallBannerUntil, call != incomingCall else { return }
        if let old = incomingCall, call == nil {
            // Banner went away: answered elsewhere (banner, iPhone) or missed. If the mic turns on soon, it was answered here.
            pendingCall = (old, Date().addingTimeInterval(10))
        }
        incomingCall = call
        if call != nil {
            isHovering = false
            hidden.remove(.call)
        }
    }

    /// Shows a fake incoming call so you can check the notch animation without anyone calling.
    func testIncomingCall() {
        let test = IncomingCall(name: "Michael", detail: "FaceTime Audio · test call", appBundleID: nil, isTest: true)
        ignoreCallBannerUntil = .distantPast
        isHovering = false
        incomingCall = test
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            if self?.incomingCall == test { self?.incomingCall = nil }
        }
    }

    func acceptCall() {
        guard let call = incomingCall else { return }
        if call.isTest {
            incomingCall = nil
            return
        }
        callMonitor?.accept()
        pendingCall = (call, Date().addingTimeInterval(10))
        ignoreCallBannerUntil = Date().addingTimeInterval(1.5)
        incomingCall = nil
    }

    func declineCall() {
        if incomingCall?.isTest == true {
            incomingCall = nil
            return
        }
        callMonitor?.decline()
        pendingCall = nil
        ignoreCallBannerUntil = Date().addingTimeInterval(1.5)
        incomingCall = nil
    }

    func openCallApp() {
        let id = activeCall?.appBundleID ?? "com.apple.FaceTime"
        mediaService?.activate(id)
    }

    /// A call counts as "in progress" while the microphone is in use after it was answered.
    private func updateCallState() {
        if let p = pendingCall {
            if micOn {
                activeCall = ActiveCall(name: p.call.name, appBundleID: p.call.appBundleID, startedAt: now)
                pendingCall = nil
                micOffSince = nil
                hidden.remove(.call)
            } else if now > p.until {
                pendingCall = nil
            }
        }
        if activeCall != nil {
            if micOn {
                micOffSince = nil
            } else if let off = micOffSince {
                if now.timeIntervalSince(off) > 3 {
                    activeCall = nil
                    micOffSince = nil
                }
            } else {
                micOffSince = now
            }
        }
    }

    // MARK: - AirDrop & files

    func setAirDrop(_ request: AirDropRequest?) {
        guard request != airdrop else { return }
        airdrop = request
        if request != nil { isHovering = false }
    }

    func acceptAirDrop() {
        if airdrop?.isTest == true { airdrop = nil; return }
        notificationMonitor?.acceptAirDrop()
    }

    func declineAirDrop() {
        if airdrop?.isTest == true { airdrop = nil; return }
        notificationMonitor?.declineAirDrop()
        airdrop = nil
    }

    func testAirDrop() {
        airdrop = AirDropRequest(key: "test", sender: "Michael\u{2019}s iPhone",
                                 detail: "Wants to share 3 photos", progress: nil, isTest: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            if self?.airdrop?.isTest == true { self?.airdrop = nil }
        }
    }

    /// Files dragged onto the notch wait here until you send or clear them.
    func addFiles(_ urls: [URL]) {
        for url in urls where !shelf.contains(url) { shelf.append(url) }
        if shelf.count > 12 { shelf.removeFirst(shelf.count - 12) }
        shelfAddedAt = Date()
        hidden.remove(.files)
        swapped = false
    }

    func clearShelf() {
        shelf.removeAll()
        shelfAddedAt = nil
    }

    func airDropShelf() {
        guard !shelf.isEmpty else { return }
        let items = shelf
        NSApp.activate(ignoringOtherApps: true)
        if let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: items) {
            service.perform(withItems: items)
        } else {
            notchLog("AirDrop: sharing service unavailable")
        }
    }

    func revealShelf() {
        NSWorkspace.shared.activateFileViewerSelecting(shelf)
    }

    // MARK: - Battery

    func updateBattery(_ b: BatteryState?) {
        guard let b = b, b != battery else { return }
        if let old = battery {
            if b.pluggedIn && !old.pluggedIn {
                show(.charging(b.percent))
            } else if !b.pluggedIn && old.percent > 10 && b.percent <= 10 {
                show(.lowBattery(b.percent), duration: 3)
            } else if !b.pluggedIn && old.percent > 20 && b.percent <= 20 {
                show(.lowBattery(b.percent), duration: 3)
            }
        }
        battery = b
    }

    // MARK: - Media

    func updateMedia(_ new: MediaInfo?) {
        guard let n = new else {
            if media != nil {
                media = nil
                artwork = nil
                artworkKey = nil
            }
            return
        }
        if n.isPlaying { lastPlayingAt = Date() }
        if media?.trackKey != n.trackKey && n.isPlaying {
            hidden.remove(.media)        // a new track pops a hidden player back out
        }
        media = n
        // Artwork often arrives a moment after the title, so include it in the key.
        let key = n.trackKey + "#\(n.artworkData?.count ?? 0)#" + (n.artworkURL ?? "")
        if key != artworkKey {
            let sameTrack = artworkKey?.hasPrefix(n.trackKey + "#") ?? false
            artworkKey = key
            if sameTrack && n.artworkData == nil && n.artworkURL == nil { return }   // keep what we have
            loadArtwork(for: n, key: key)
        }
    }

    func sendMedia(_ command: MediaService.Command) {
        guard let m = media else { return }
        mediaService?.send(command, to: m)
        if command == .toggle {
            media?.isPlaying.toggle()
            if media?.isPlaying == true { lastPlayingAt = Date() }
        }
    }

    func openMedia() {
        guard let m = media else { return }
        mediaService?.open(m)
    }

    private func loadArtwork(for m: MediaInfo, key: String) {
        if let data = m.artworkData, let img = NSImage(data: data) {
            setArtwork(img)
            return
        }
        guard let s = m.artworkURL, let url = URL(string: s) else {
            artwork = nil
            accent = Color(white: 0.92)
            return
        }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data, let img = NSImage(data: data) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.artworkKey == key else { return }
                self.setArtwork(img)
            }
        }.resume()
    }

    private func setArtwork(_ img: NSImage) {
        artwork = img
        if let c = img.islandAccent { accent = Color(nsColor: c) }
    }
}

// MARK: - Helpers

extension NSImage {
    /// Average colour of the artwork, brightened so it reads on black (used to tint the waveform).
    var islandAccent: NSColor? {
        guard let tiff = tiffRepresentation, let ci = CIImage(data: tiff) else { return nil }
        guard let filter = CIFilter(name: "CIAreaAverage",
                                    parameters: [kCIInputImageKey: ci,
                                                 kCIInputExtentKey: CIVector(cgRect: ci.extent)]),
              let output = filter.outputImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CIContext(options: [.workingColorSpace: NSNull()])
        ctx.render(output, toBitmap: &px, rowBytes: 4,
                   bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                   format: .RGBA8, colorSpace: nil)
        let base = NSColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255,
                           blue: CGFloat(px[2]) / 255, alpha: 1)
        guard let rgb = base.usingColorSpace(.deviceRGB) else { return base }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: h, saturation: min(s * 1.2, 0.85), brightness: max(b, 0.82), alpha: 1)
    }
}

func formatTime(_ t: Double, roundUp: Bool = false) -> String {
    let total = max(0, Int(roundUp ? t.rounded(.up) : t.rounded(.down)))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}
