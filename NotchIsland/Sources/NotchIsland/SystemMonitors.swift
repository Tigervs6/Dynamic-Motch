import AppKit
import CoreAudio
import CoreMediaIO
import IOKit.ps
import IOBluetooth

// MARK: - Camera & microphone in use (privacy dots)

final class PrivacyMonitor {
    func read() -> (camera: Bool, mic: Bool) {
        (isCameraInUse(), isMicInUse())
    }

    private func isCameraInUse() -> Bool {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, &size) == 0,
              size > 0 else { return false }
        let count = Int(size) / MemoryLayout<CMIODeviceID>.size
        var devices = [CMIODeviceID](repeating: 0, count: count)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil,
                                        size, &used, &devices) == 0 else { return false }

        for device in devices {
            var runAddr = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
            var running: UInt32 = 0
            var got: UInt32 = 0
            if CMIOObjectGetPropertyData(device, &runAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size),
                                         &got, &running) == 0, running != 0 {
                return true
            }
        }
        return false
    }

    private func isMicInUse() -> Bool {
        // macOS 14.2+: ask which processes are actually recording (no false positives from AirPods playback).
        if #available(macOS 14.2, *) {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyProcessObjectList,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            if AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
               size > 0 {
                var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
                if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &processes) == noErr {
                    for p in processes {
                        var inAddr = AudioObjectPropertyAddress(
                            mSelector: kAudioProcessPropertyIsRunningInput,
                            mScope: kAudioObjectPropertyScopeGlobal,
                            mElement: kAudioObjectPropertyElementMain)
                        var value: UInt32 = 0
                        var vSize = UInt32(MemoryLayout<UInt32>.size)
                        if AudioObjectGetPropertyData(p, &inAddr, 0, nil, &vSize, &value) == noErr, value != 0 {
                            return true
                        }
                    }
                    return false
                }
            }
        }
        return legacyMicInUse()
    }

    /// Older macOS: an input-only device (e.g. the built-in mic) that is running.
    private func legacyMicInUse() -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return false }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devices) == noErr
        else { return false }

        for d in devices where streamCount(d, scope: kAudioDevicePropertyScopeInput) > 0
            && streamCount(d, scope: kAudioDevicePropertyScopeOutput) == 0 {
            var runAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var running: UInt32 = 0
            var rSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(d, &runAddr, 0, nil, &rSize, &running) == noErr, running != 0 {
                return true
            }
        }
        return false
    }

    private func streamCount(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }
}

// MARK: - Battery

final class BatteryMonitor {
    func read() -> BatteryState? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            else { continue }
            if let type = desc[kIOPSTypeKey] as? String, type != kIOPSInternalBatteryType { continue }
            let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            let charging = desc[kIOPSIsChargingKey] as? Bool ?? false
            let plugged = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let percent = maximum > 0 ? Int((Double(current) / Double(maximum) * 100).rounded()) : current
            return BatteryState(percent: percent, charging: charging, pluggedIn: plugged)
        }
        return nil
    }
}

// MARK: - Bluetooth (AirPods etc.)

final class BluetoothMonitor: NSObject {
    /// name, connected, isAudioDevice
    var onEvent: ((String, Bool, Bool) -> Void)?

    private var connectNotification: IOBluetoothUserNotification?
    private var startedAt = Date()

    func start() {
        startedAt = Date()
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(deviceConnected(_:device:)))
    }

    @objc private func deviceConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        _ = device.register(forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:)))
        // macOS reports already-connected devices right after launch — don't announce those.
        guard Date().timeIntervalSince(startedAt) > 3 else { return }
        onEvent?(device.name ?? "Bluetooth device", true, isAudio(device))
    }

    @objc private func deviceDisconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        onEvent?(device.name ?? "Bluetooth device", false, isAudio(device))
    }

    private func isAudio(_ device: IOBluetoothDevice) -> Bool {
        device.deviceClassMajor == BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorAudio)
    }
}
