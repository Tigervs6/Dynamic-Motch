import SwiftUI
import AppKit
import ApplicationServices
import UniformTypeIdentifiers

private let islandSpring = Animation.spring(response: 0.42, dampingFraction: 0.8)

// MARK: - Root

struct IslandRootView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        let size = model.displaySize
        let presentation = model.presentation

        ZStack(alignment: .top) {
            IslandBody(model: model, size: size, presentation: presentation)
                .frame(width: size.width + 2 * size.flare, height: size.height)
                .opacity(!model.geometry.hasNotch && presentation == .idle ? 0 : 1)

            if let second = model.secondaryKind {
                SecondaryDot(model: model, kind: second, diameter: size.height)
                    .offset(x: size.width / 2 + 6 + size.height / 2)
                    .transition(.scale(scale: 0.2).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(islandSpring, value: size)
        .animation(islandSpring, value: presentation)
        .preferredColorScheme(.dark)
    }
}

// MARK: - The black shape + its content

struct IslandBody: View {
    @ObservedObject var model: IslandModel
    let size: IslandSize
    let presentation: Presentation

    private var shape: NotchShape {
        NotchShape(flare: size.flare, bottomRadius: size.bottomRadius)
    }

    var body: some View {
        ZStack(alignment: .top) {
            shape.fill(Color.black)
            content
                .frame(width: size.width, height: size.height, alignment: .top)
                .id(presentation.key)
                .transition(.blurFade)
        }
        .clipShape(shape)
        .contentShape(shape)
        .gesture(swipeIntoNotch)
        .onDrop(of: [UTType.fileURL], isTargeted: Binding(
            get: { model.dropTargeted },
            set: { model.dropTargeted = $0 })) { providers in
                receive(providers)
                return true
            }
        .contextMenu {
            Button("Show hidden activities") { model.unhideAll() }
            Divider()
            Button("Test incoming call") { model.testIncomingCall() }
            Button("Test AirDrop") { model.testAirDrop() }
            Button("Test notification") {
                model.showNotification(SystemNotification(
                    id: UUID().uuidString, appName: "Messages", title: "Michael",
                    body: "Are we still on for tonight? I can bring the snacks 🍿", icon: nil))
            }
            if let monitor = model.notificationMonitor {
                Button(monitor.hideMacBanners ? "✓ Hide Mac banners (notch only)" : "Hide Mac banners (notch only)") {
                    monitor.hideMacBanners.toggle()
                }
            }
            Button(AXIsProcessTrusted() ? "Calls: Accessibility is on ✓" : "Calls: turn on Accessibility…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
            Text(model.mediaService?.statusText ?? "Media: starting…")
            Button(notchDebugLogging ? "✓ Debug logging (includes message text)" : "Debug logging (includes message text)") {
                notchDebugLogging.toggle()
                notchLog("Debug logging \(notchDebugLogging ? "on" : "off")")
            }
            Button("Open log") {
                NSWorkspace.shared.open(CallMonitor.logURL)
            }
            Divider()
            Button("Quit NotchIsland") { NSApp.terminate(nil) }
        }
    }

    @ViewBuilder private var content: some View {
        switch presentation {
        case .idle:
            IdleView(model: model, height: size.height)
        case .incomingCall(let call):
            IncomingCallView(model: model, call: call)
        case .airdrop(let request):
            AirDropView(model: model, request: request)
        case .compact(let kind):
            CompactView(model: model, kind: kind, height: size.height)
        case .alert(let alert):
            AlertView(model: model, alert: alert, height: size.height)
        case .expanded(let c):
            ExpandedView(model: model, content: c)
        }
    }

    /// Files dragged onto the notch land in the shelf, ready to AirDrop.
    private func receive(_ providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                if let direct = item as? URL { url = direct }
                guard let found = url else { return }
                DispatchQueue.main.async { model.addFiles([found]) }
            }
        }
    }

    /// Drag the island up, or drag a side inward, and it follows your pointer back into the notch.
    private var swipeIntoNotch: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                guard presentation != .idle else { return }
                let up = -value.translation.height
                let center = model.windowWidth / 2
                let inward = value.startLocation.x < center ? value.translation.width : -value.translation.width
                let progress = max(up / 90, inward / 70, 0)
                model.squeeze = min(progress, 1) * 0.7
            }
            .onEnded { value in
                let flickUp = -value.predictedEndTranslation.height > 160
                if model.squeeze >= 0.35 || flickUp {
                    model.hideCurrent()
                }
                model.squeeze = 0
            }
    }
}

// MARK: - Layout helper: content either side of the notch

struct EarRow<Left: View, Right: View>: View {
    let notchWidth: CGFloat
    let height: CGFloat
    let left: Left
    let right: Right

    init(notchWidth: CGFloat, height: CGFloat,
         @ViewBuilder left: () -> Left, @ViewBuilder right: () -> Right) {
        self.notchWidth = notchWidth
        self.height = height
        self.left = left()
        self.right = right()
    }

    var body: some View {
        HStack(spacing: 0) {
            left.frame(maxWidth: .infinity)
            Color.clear.frame(width: notchWidth)
            right.frame(maxWidth: .infinity)
        }
        .frame(height: height)
    }
}

struct PrivacyDots: View {
    let camera: Bool
    let mic: Bool
    var body: some View {
        HStack(spacing: 3) {
            if camera { Circle().fill(Color.green).frame(width: 6, height: 6) }
            if mic { Circle().fill(Color.orange).frame(width: 6, height: 6) }
        }
    }
}

// MARK: - Idle

struct IdleView: View {
    @ObservedObject var model: IslandModel
    let height: CGFloat

    var body: some View {
        if model.privacyActive {
            EarRow(notchWidth: model.geometry.notchWidth, height: height) {
                Color.clear
            } right: {
                PrivacyDots(camera: model.cameraOn, mic: model.micOn)
            }
        } else {
            Color.clear
        }
    }
}

// MARK: - Compact

struct CompactView: View {
    @ObservedObject var model: IslandModel
    let kind: ActivityKind
    let height: CGFloat

    var body: some View {
        EarRow(notchWidth: model.geometry.notchWidth, height: height) {
            leading
        } right: {
            HStack(spacing: 4) {
                trailing
                if model.privacyActive { PrivacyDots(camera: model.cameraOn, mic: model.micOn) }
            }
        }
    }

    @ViewBuilder private var leading: some View {
        switch kind {
        case .call:
            Image(systemName: "phone.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.green)
        case .files:
            Image(systemName: "paperclip")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(red: 0.25, green: 0.6, blue: 1.0))
        case .media:
            ArtworkView(image: model.artwork, size: 22, radius: 6,
                        symbol: model.media?.sourceSymbol ?? "music.note")
        case .timer:
            Image(systemName: "timer")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.orange)
        }
    }

    @ViewBuilder private var trailing: some View {
        switch kind {
        case .call:
            Text(formatTime(model.now.timeIntervalSince(model.activeCall?.startedAt ?? model.now)))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(.green)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        case .files:
            Text("\(model.shelf.count)")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(Color(red: 0.25, green: 0.6, blue: 1.0))
        case .media:
            Waveform(color: model.accent, playing: model.media?.isPlaying ?? false)
        case .timer:
            Text(formatTime(model.timer?.remaining(at: model.now) ?? 0, roundUp: true))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(.orange)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
    }
}

// MARK: - Alerts (charging, low battery, Bluetooth, timer done)

struct AlertView: View {
    @ObservedObject var model: IslandModel
    let alert: IslandAlert
    let height: CGFloat

    var body: some View {
        switch alert {
        case .charging(let percent):
            EarRow(notchWidth: model.geometry.notchWidth, height: height) {
                Image(systemName: "bolt.fill").font(.system(size: 13, weight: .bold)).foregroundColor(.green)
            } right: {
                Text("\(percent)%").font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit().foregroundColor(.green)
            }
        case .lowBattery(let percent):
            EarRow(notchWidth: model.geometry.notchWidth, height: height) {
                Image(systemName: "battery.25").font(.system(size: 14, weight: .semibold)).foregroundColor(.red)
            } right: {
                Text("\(percent)%").font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit().foregroundColor(.red)
            }
        case .bluetooth(let name, let connected, let audio):
            Banner(notchHeight: model.geometry.notchHeight,
                   symbol: bluetoothSymbol(name: name, audio: audio),
                   tint: connected ? .white : .gray,
                   title: name,
                   subtitle: connected ? "Connected" : "Disconnected")
        case .notification(let n):
            NotificationBanner(model: model, notification: n)
        case .timerDone:
            Banner(notchHeight: model.geometry.notchHeight,
                   symbol: "timer", tint: .orange,
                   title: "Timer done", subtitle: "Swipe up to dismiss")
        }
    }

    private func bluetoothSymbol(name: String, audio: Bool) -> String {
        let n = name.lowercased()
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods pro") { return "airpodspro" }
        if n.contains("airpods") { return "airpods" }
        if n.contains("beats") || audio { return "headphones" }
        if n.contains("keyboard") { return "keyboard" }
        if n.contains("mouse") { return "computermouse" }
        if n.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        return "dot.radiowaves.left.and.right"
    }
}

struct Banner: View {
    let notchHeight: CGFloat
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notchHeight)
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(tint)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                    Text(subtitle).font(.system(size: 11)).foregroundColor(.white.opacity(0.55)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Expanded

struct ExpandedView: View {
    @ObservedObject var model: IslandModel
    let content: ExpandedContent

    var body: some View {
        VStack(spacing: 0) {
            EarRow(notchWidth: model.geometry.notchWidth, height: model.geometry.notchHeight) {
                topLeft
                    .padding(.leading, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } right: {
                HStack(spacing: 6) {
                    topRight
                    if model.privacyActive { PrivacyDots(camera: model.cameraOn, mic: model.micOn) }
                }
                .padding(.trailing, 20)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

            Group {
                switch content {
                case .media: MediaPanel(model: model)
                case .timer: TimerPanel(model: model)
                case .call: CallPanel(model: model)
                case .files: FilesPanel(model: model)
                case .home: HomePanel(model: model)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var topLeft: some View {
        switch content {
        case .media:
            if let m = model.media {
                HStack(spacing: 5) {
                    Image(systemName: m.sourceSymbol).font(.system(size: 10, weight: .semibold))
                    Text(m.sourceName).font(.system(size: 11, weight: .medium)).lineLimit(1)
                }
                .foregroundColor(m.isYouTube ? Color.red.opacity(0.9) : .white.opacity(0.55))
            }
        case .timer:
            Text("Timer").font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.55))
        case .call:
            HStack(spacing: 5) {
                Image(systemName: "phone.fill").font(.system(size: 10, weight: .semibold))
                Text("On call").font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(.green)
        case .files:
            Text(model.dropTargeted ? "Drop to send" : "\(model.shelf.count) file\(model.shelf.count == 1 ? "" : "s")")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.55))
        case .home:
            Text(model.now, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.55))
        }
    }

    @ViewBuilder private var topRight: some View {
        switch content {
        case .files:
            Text("\(model.shelf.count)")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(Color(red: 0.25, green: 0.6, blue: 1.0))
        case .media:
            Waveform(color: model.accent, playing: model.media?.isPlaying ?? false)
        case .timer:
            EmptyView()
        case .call:
            Waveform(color: .green, playing: model.micOn)
        case .home:
            if let b = model.battery {
                HStack(spacing: 4) {
                    Text("\(b.percent)%").font(.system(size: 11, weight: .medium)).monospacedDigit()
                    Image(systemName: b.pluggedIn ? "battery.100.bolt" : batterySymbol(b.percent))
                        .font(.system(size: 12))
                }
                .foregroundColor(b.percent <= 20 && !b.pluggedIn ? .red : .white.opacity(0.7))
            }
        }
    }

    private func batterySymbol(_ p: Int) -> String {
        switch p {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }
}

struct MediaPanel: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        if let m = model.media {
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    ArtworkView(image: model.artwork, size: 54, radius: 12, symbol: m.sourceSymbol)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(m.title.isEmpty ? m.sourceName : m.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text(m.artist)
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .onTapGesture { model.openMedia() }

                ProgressRow(media: m, accent: model.accent)

                HStack(spacing: 40) {
                    IconButton(symbol: "backward.fill", size: 16) { model.sendMedia(.previous) }
                    IconButton(symbol: m.isPlaying ? "pause.fill" : "play.fill", size: 22) { model.sendMedia(.toggle) }
                    IconButton(symbol: "forward.fill", size: 16) { model.sendMedia(.next) }
                }
            }
        }
    }
}

struct ProgressRow: View {
    let media: MediaInfo
    let accent: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let pos = media.position(at: context.date)
            HStack(spacing: 8) {
                Text(formatTime(pos))
                    .font(.system(size: 10, weight: .medium)).monospacedDigit()
                    .foregroundColor(.white.opacity(0.5))
                    .frame(width: 38, alignment: .leading)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.18))
                        Capsule().fill(accent)
                            .frame(width: media.duration > 0 ? geo.size.width * CGFloat(pos / media.duration) : 0)
                    }
                }
                .frame(height: 4)
                Text(media.duration > 0 ? "-" + formatTime(media.duration - pos) : "LIVE")
                    .font(.system(size: 10, weight: .medium)).monospacedDigit()
                    .foregroundColor(media.duration > 0 ? .white.opacity(0.5) : .red)
                    .frame(width: 38, alignment: .trailing)
            }
        }
    }
}

struct TimerPanel: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        if let t = model.timer {
            HStack(spacing: 14) {
                Text(formatTime(t.remaining(at: model.now), roundUp: true))
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(.orange)
                Spacer(minLength: 0)
                CircleButton(symbol: t.isPaused ? "play.fill" : "pause.fill", tint: .orange) {
                    model.toggleTimerPause()
                }
                CircleButton(symbol: "xmark", tint: .gray) {
                    model.cancelTimer()
                }
            }
        }
    }
}

struct HomePanel: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.now, format: .dateTime.hour().minute())
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                    Text(model.now, format: .dateTime.weekday(.wide).day().month(.wide))
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 5) {
                    Text("Quick timer")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
                    HStack(spacing: 6) {
                        ForEach([1, 5, 10, 25], id: \.self) { minutes in
                            Button {
                                model.startTimer(minutes: Double(minutes))
                            } label: {
                                Text("\(minutes)m")
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundColor(.orange)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 5)
                                    .background(Capsule().fill(Color.orange.opacity(0.16)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Second activity (small circle beside the island)

struct SecondaryDot: View {
    @ObservedObject var model: IslandModel
    let kind: ActivityKind
    let diameter: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(Color.black)
            switch kind {
            case .call:
                Image(systemName: "phone.fill")
                    .font(.system(size: diameter * 0.36, weight: .semibold))
                    .foregroundColor(.green)
            case .timer:
                Image(systemName: "timer")
                    .font(.system(size: diameter * 0.4, weight: .semibold))
                    .foregroundColor(.orange)
            case .files:
                Image(systemName: "paperclip")
                    .font(.system(size: diameter * 0.36, weight: .semibold))
                    .foregroundColor(Color(red: 0.25, green: 0.6, blue: 1.0))
            case .media:
                ArtworkView(image: model.artwork, size: diameter * 0.55, radius: diameter * 0.28,
                            symbol: model.media?.sourceSymbol ?? "music.note")
            }
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .onTapGesture { model.switchActivity() }
    }
}

// MARK: - Small components

struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    let radius: CGFloat
    let symbol: String

    var body: some View {
        Group {
            if let img = image {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.12)
                    Image(systemName: symbol)
                        .font(.system(size: size * 0.42, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

struct Waveform: View {
    let color: Color
    let playing: Bool
    var bars: Int = 4

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !playing)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<bars, id: \.self) { i in
                    let level = playing ? 0.3 + 0.7 * abs(sin(t * (3.1 + Double(i) * 1.3) + Double(i) * 0.9)) : 0.22
                    Capsule()
                        .fill(color)
                        .frame(width: 2.6, height: max(3, 14 * CGFloat(level)))
                }
            }
            .frame(height: 14)
        }
    }
}

struct IconButton: View {
    let symbol: String
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 34, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct CircleButton: View {
    let symbol: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(tint)
                .frame(width: 40, height: 40)
                .background(Circle().fill(tint.opacity(0.2)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Calls

/// Incoming call — laid out like the iPhone concept: photo on the left of the notch,
/// Decline / Accept on the right, name underneath.
struct IncomingCallView: View {
    @ObservedObject var model: IslandModel
    let call: IncomingCall

    var body: some View {
        let nw = model.geometry.notchWidth
        let nh = model.geometry.notchHeight
        VStack(spacing: 1) {
            EarRow(notchWidth: nw, height: nh + 14) {
                CallerAvatar(name: call.name, size: 38)
                    .padding(.leading, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } right: {
                HStack(spacing: 10) {
                    CallButton(symbol: "phone.down.fill", color: Color(red: 0.93, green: 0.23, blue: 0.2), pulse: false) {
                        model.declineCall()
                    }
                    CallButton(symbol: "phone.fill", color: Color(red: 0.2, green: 0.78, blue: 0.35), pulse: true) {
                        model.acceptCall()
                    }
                }
                .padding(.trailing, 16)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            Text(call.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .padding(.horizontal, 24)
            Text(call.detail)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.5))
                .lineLimit(1)
                .padding(.horizontal, 24)
        }
    }
}

/// Call in progress (expanded on hover).
struct CallPanel: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        if let call = model.activeCall {
            HStack(spacing: 12) {
                CallerAvatar(name: call.name, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(call.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(formatTime(model.now.timeIntervalSince(call.startedAt)))
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(.green)
                }
                Spacer(minLength: 0)
                CircleButton(symbol: "arrow.up.forward.app", tint: .green) {
                    model.openCallApp()
                }
            }
        }
    }
}

struct CallerAvatar: View {
    let name: String
    let size: CGFloat

    private var initials: String? {
        let words = name.split(separator: " ").filter { $0.first?.isLetter == true }
        guard !words.isEmpty else { return nil }
        var result = ""
        for word in words.prefix(2) {
            if let first = word.first { result += String(first).uppercased() }
        }
        return result
    }

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Color(white: 0.62), Color(white: 0.38)],
                                         startPoint: .top, endPoint: .bottom))
            if let text = initials {
                Text(text)
                    .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.45))
                    .foregroundColor(.white)
            }
        }
        .frame(width: size, height: size)
    }
}

struct CallButton: View {
    let symbol: String
    let color: Color
    let pulse: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !pulse)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let scale = pulse ? 1 + 0.06 * CGFloat(sin(t * 5)) : 1
                ZStack {
                    Circle().fill(color)
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                }
                .frame(width: 36, height: 36)
                .scaleEffect(scale)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Notifications

struct NotificationBanner: View {
    @ObservedObject var model: IslandModel
    let notification: SystemNotification

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: model.geometry.notchHeight)
            HStack(alignment: .top, spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(notification.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(notification.appName.isEmpty ? "now" : notification.appName)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.4))
                            .lineLimit(1)
                    }
                    if !notification.body.isEmpty {
                        Text(notification.body)
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.72))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.openNotification(notification) }
    }

    @ViewBuilder private var icon: some View {
        if let img = notification.icon {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 34, height: 34)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.14))
                Image(systemName: "bell.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
            }
            .frame(width: 34, height: 34)
        }
    }
}

// MARK: - AirDrop

private let airDropBlue = Color(red: 0.25, green: 0.6, blue: 1.0)

/// Someone is sending you files.
struct AirDropView: View {
    @ObservedObject var model: IslandModel
    let request: AirDropRequest

    var body: some View {
        let nw = model.geometry.notchWidth
        let nh = model.geometry.notchHeight
        VStack(spacing: 4) {
            EarRow(notchWidth: nw, height: nh + 16) {
                ZStack {
                    Circle().fill(airDropBlue.opacity(0.22))
                    Image(systemName: "dot.radiowaves.up.forward")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(airDropBlue)
                }
                .frame(width: 38, height: 38)
                .padding(.leading, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            } right: {
                Group {
                    if request.progress == nil {
                        HStack(spacing: 10) {
                            CallButton(symbol: "xmark", color: Color(white: 0.3), pulse: false) {
                                model.declineAirDrop()
                            }
                            CallButton(symbol: "arrow.down", color: airDropBlue, pulse: true) {
                                model.acceptAirDrop()
                            }
                        }
                    } else {
                        Text("\(Int((request.progress ?? 0) * 100))%")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(airDropBlue)
                    }
                }
                .padding(.trailing, 18)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

            Text(request.sender)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .padding(.horizontal, 22)

            if let progress = request.progress {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.18))
                        Capsule().fill(airDropBlue).frame(width: geo.size.width * CGFloat(progress))
                    }
                }
                .frame(height: 4)
                .padding(.horizontal, 26)
                .padding(.top, 3)
            } else {
                Text(request.detail)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
                    .padding(.horizontal, 22)
            }
        }
    }
}

/// Files waiting on the notch, ready to send.
struct FilesPanel: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        VStack(spacing: 10) {
            if model.shelf.isEmpty {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(airDropBlue.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .frame(height: 56)
                    .overlay(
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.down.doc")
                            Text("Drop files to AirDrop them")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                    )
            } else {
                HStack(spacing: 10) {
                    ForEach(model.shelf.prefix(5), id: \.self) { url in
                        FileChip(url: url)
                    }
                    if model.shelf.count > 5 {
                        Text("+\(model.shelf.count - 5)")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: 44)

                HStack(spacing: 8) {
                    Button(action: { model.airDropShelf() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "dot.radiowaves.up.forward")
                            Text("AirDrop")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(airDropBlue))
                    }
                    .buttonStyle(.plain)

                    Button(action: { model.revealShelf() }) {
                        Image(systemName: "folder")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.85))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Color.white.opacity(0.14)))
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 0)

                    Button(action: { model.clearShelf() }) {
                        Text("Clear")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct FileChip: View {
    let url: URL

    var body: some View {
        VStack(spacing: 3) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 26, height: 26)
            Text(url.lastPathComponent)
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.6))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 58)
        }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
    }
}
