import AppKit

/// Reads the same "Now Playing" media that Control Center shows (any app or browser tab),
/// using the open-source mediaremote-adapter (BSD-3, github.com/ungive/mediaremote-adapter).
///
/// Since macOS 15.4 only Apple-signed programs may read Now Playing, so the adapter runs inside
/// `/usr/bin/perl` and streams updates to us as one JSON object per line.
/// build.sh installs it to ~/Library/Application Support/NotchIsland/adapter.
final class NowPlayingAdapter {
    /// Called on the main thread with the current media, or nil when nothing is playing.
    var onUpdate: ((MediaInfo?) -> Void)?

    private let scriptURL: URL
    private let frameworkURL: URL
    private var process: Process?
    private var buffer = Data()
    private var launchedAt = Date()
    private var stopped = false
    private var restarts = 0
    private var lastLogged = ""
    private var stderrLines = 0

    private(set) var isRunning = false
    private(set) var lastUpdate: Date?

    static var installDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NotchIsland/adapter")
    }

    init?() {
        let fm = FileManager.default
        var dirs = [Self.installDirectory]
        if let res = Bundle.main.resourceURL {
            dirs.append(res.appendingPathComponent("adapter"))   // shipped inside the app (release builds)
            dirs.append(res)
        }
        for dir in dirs {
            let script = dir.appendingPathComponent("mediaremote-adapter.pl")
            let framework = dir.appendingPathComponent("MediaRemoteAdapter.framework")
            if fm.fileExists(atPath: script.path),
               fm.fileExists(atPath: framework.appendingPathComponent("MediaRemoteAdapter").path) {
                scriptURL = script
                frameworkURL = framework
                notchLog("Media: Now Playing helper found in \(dir.path)")
                return
            }
        }
        notchLog("Media: Now Playing helper NOT found — run ./build.sh again. Using fallback only.")
        return nil
    }

    func start() {
        stopped = false
        launch()
    }

    func stop() {
        stopped = true
        process?.terminate()
        process = nil
        isRunning = false
    }

    private func launch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [scriptURL.path, frameworkURL.path, "stream", "--no-diff", "--micros", "--debounce=120"]
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err

        buffer = Data()
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.consume(data)
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            guard let self = self, self.stderrLines < 40,
                  let text = String(data: data, encoding: .utf8) else { return }
            self.stderrLines += 1
            notchLog("Media helper error: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            DispatchQueue.main.async { self?.handleExit(status) }
        }

        do {
            try p.run()
            process = p
            isRunning = true
            launchedAt = Date()
            notchLog("Media: helper started (pid \(p.processIdentifier))")
        } catch {
            isRunning = false
            notchLog("Media: couldn't start /usr/bin/perl — \(error.localizedDescription)")
        }
    }

    private func handleExit(_ status: Int32) {
        process = nil
        isRunning = false
        if stopped { return }
        restarts += 1
        notchLog("Media: helper exited with status \(status) after \(Int(Date().timeIntervalSince(launchedAt)))s")
        guard restarts < 20 else {
            notchLog("Media: helper keeps failing — giving up, fallback only.")
            return
        }
        let delay: TimeInterval = restarts < 3 ? 2 : 15
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, !self.stopped else { return }
            self.launch()
        }
    }

    // Runs on the pipe's background queue (calls are serial).
    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            if !line.isEmpty { parse(line) }
        }
    }

    private func parse(_ line: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            notchLog("Media: helper sent something unexpected: \(String(data: line.prefix(200), encoding: .utf8) ?? "?")", sensitive: true)
            return
        }
        let payload = obj["payload"] as? [String: Any] ?? [:]
        let info = Self.mediaInfo(from: payload)

        let summary = info.map { "\($0.appBundleID ?? "?") · \($0.title) · playing=\($0.isPlaying)" } ?? "nothing playing"
        if summary != lastLogged {
            lastLogged = summary
            if let i = info {
                notchLog("Media: Now Playing → \(i.appBundleID ?? "?") playing=\(i.isPlaying)")
                notchLog("  title: \(i.title)", sensitive: true)
            } else {
                notchLog("Media: Now Playing → nothing playing")
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.lastUpdate = Date()
            self?.onUpdate?(info)
        }
    }

    private static func mediaInfo(from p: [String: Any]) -> MediaInfo? {
        guard let bundle = p["bundleIdentifier"] as? String,
              let title = p["title"] as? String, !title.isEmpty else { return nil }

        let playing = (p["playing"] as? NSNumber)?.boolValue ?? false
        let duration = ((p["durationMicros"] as? NSNumber)?.doubleValue ?? 0) / 1_000_000
        var position = ((p["elapsedTimeMicros"] as? NSNumber)?.doubleValue ?? 0) / 1_000_000
        if playing, let ts = (p["timestampEpochMicros"] as? NSNumber)?.doubleValue, ts > 0 {
            position += max(0, Date().timeIntervalSince1970 - ts / 1_000_000)
        }
        if duration > 0 { position = min(position, duration) }

        var artwork: Data?
        if let b64 = p["artworkData"] as? String {
            artwork = Data(base64Encoded: b64, options: .ignoreUnknownCharacters)
        }

        return MediaInfo(
            source: .nowPlaying(bundleID: bundle, parentBundleID: p["parentApplicationBundleIdentifier"] as? String),
            title: title,
            artist: (p["artist"] as? String) ?? (p["album"] as? String) ?? "",
            artworkURL: nil,
            artworkData: artwork,
            isPlaying: playing,
            position: position,
            duration: duration,
            sampledAt: Date()
        )
    }

    // MARK: - Commands (same as the Control Center buttons)

    enum RemoteCommand: Int {
        case togglePlayPause = 2
        case nextTrack = 4
        case previousTrack = 5
    }

    func send(_ command: RemoteCommand) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [scriptURL.path, frameworkURL.path, "send", String(command.rawValue)]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}
