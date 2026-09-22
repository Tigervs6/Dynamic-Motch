import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let panelSize = CGSize(width: 680, height: 300)

    private var model: IslandModel!
    private var panel: NotchPanel!
    private var tracker: MouseTracker!

    private let media = MediaService()
    private let privacy = PrivacyMonitor()
    private let batteryMonitor = BatteryMonitor()
    private let bluetooth = BluetoothMonitor()
    private let calls = CallMonitor()
    private let notifications = NotificationMonitor()

    private var ticker: Timer?
    private var tickCount = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        let geometry = NotchGeometry.detect()
        model = IslandModel(geometry: geometry)
        model.windowWidth = panelSize.width

        panel = NotchPanel(contentRect: panelFrame(for: geometry))
        let host = FirstMouseHostingView(rootView: IslandRootView(model: model))
        host.frame = CGRect(origin: .zero, size: panelSize)
        host.sizingOptions = []
        panel.contentView = host
        panel.orderFrontRegardless()

        tracker = MouseTracker(model: model, panel: panel)
        tracker.start()

        media.model = model
        model.mediaService = media
        media.start()

        model.battery = batteryMonitor.read()

        bluetooth.onEvent = { [weak self] name, connected, audio in
            self?.model.show(.bluetooth(name: name, connected: connected, audio: audio), duration: 2.8)
        }
        bluetooth.start()

        model.callMonitor = calls
        calls.onChange = { [weak self] call in
            self?.model.setIncomingCall(call)
        }
        calls.start()

        model.notificationMonitor = notifications
        notifications.onNew = { [weak self] n in
            self?.model.showNotification(n)
        }
        notifications.onAirDrop = { [weak self] request in
            self?.model.setAirDrop(request)
        }
        notifications.start()

        ticker = Timer.scheduledTimer(timeInterval: 1.0, target: self, selector: #selector(tick),
                                      userInfo: nil, repeats: true)

        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        media.stop()
    }

    private func panelFrame(for g: NotchGeometry) -> CGRect {
        CGRect(x: g.centerX - panelSize.width / 2, y: g.top - panelSize.height,
               width: panelSize.width, height: panelSize.height)
    }

    @objc private func tick() {
        tickCount += 1
        model.tick()

        let p = privacy.read()
        if model.cameraOn != p.camera { model.cameraOn = p.camera }
        if model.micOn != p.mic { model.micOn = p.mic }

        if tickCount % 3 == 0 {
            model.updateBattery(batteryMonitor.read())
        }
    }

    @objc private func screensChanged() {
        let g = NotchGeometry.detect()
        model.geometry = g
        panel.setFrame(panelFrame(for: g), display: true)
    }
}
