import AppKit

enum MediaSource: Equatable {
    case nowPlaying(bundleID: String, parentBundleID: String?)   // Control Center "Now Playing"
    case music
    case spotify
    case browser(app: String, bundleID: String, safari: Bool, window: Int, tab: Int, url: String)
}

struct MediaInfo: Equatable {
    var source: MediaSource
    var title: String
    var artist: String
    var artworkURL: String?
    var artworkData: Data?
    var isPlaying: Bool
    var position: Double
    var duration: Double
    var sampledAt: Date

    var sourceID: String {
        switch source {
        case .nowPlaying(let bundle, let parent): return "np:" + (parent ?? bundle)
        case .music: return "music"
        case .spotify: return "spotify"
        case .browser(let app, _, _, let w, let t, _): return "\(app)#\(w)#\(t)"
        }
    }

    var trackKey: String { sourceID + "|" + title }

    var isYouTube: Bool {
        if case .browser(_, _, _, _, _, let url) = source {
            let u = url.lowercased()
            return u.contains("youtube.com") || u.contains("youtu.be")
        }
        return false
    }

    /// The app that owns the media (for Now Playing, the browser rather than its helper process).
    var appBundleID: String? {
        switch source {
        case .nowPlaying(let bundle, let parent): return parent ?? bundle
        case .music: return "com.apple.Music"
        case .spotify: return "com.spotify.client"
        case .browser(_, let bundleID, _, _, _, _): return bundleID
        }
    }

    var isBrowser: Bool {
        guard let id = appBundleID else { return false }
        return MediaService.browserBundleIDs.contains(id)
    }

    var sourceName: String {
        switch source {
        case .nowPlaying:
            return MediaService.appName(appBundleID ?? "")
        case .music: return "Music"
        case .spotify: return "Spotify"
        case .browser(let app, _, _, _, _, let url):
            let u = url.lowercased()
            if u.contains("music.youtube.com") { return "YouTube Music" }
            if u.contains("youtube.com") || u.contains("youtu.be") { return "YouTube" }
            if u.contains("twitch.tv") { return "Twitch" }
            if u.contains("soundcloud.com") { return "SoundCloud" }
            if u.contains("open.spotify.com") { return "Spotify Web" }
            if u.contains("netflix.com") { return "Netflix" }
            if u.contains("vimeo.com") { return "Vimeo" }
            if u.contains("music.apple.com") { return "Apple Music Web" }
            if let host = URL(string: url)?.host { return host.replacingOccurrences(of: "www.", with: "") }
            return app
        }
    }

    var sourceSymbol: String {
        switch source {
        case .nowPlaying: return isBrowser ? "play.rectangle.fill" : "music.note"
        case .music, .spotify: return "music.note"
        case .browser: return isYouTube ? "play.rectangle.fill" : "globe"
        }
    }

    func position(at now: Date) -> Double {
        guard isPlaying else { return position }
        let p = position + now.timeIntervalSince(sampledAt)
        return duration > 0 ? min(p, duration) : p
    }
}

/// Polls Music, Spotify and browsers once a second and sends playback commands.
/// Browsers are read by running a tiny script inside media tabs (YouTube, SoundCloud, Twitch…)
/// that reports the page's <video>/<audio> state and its Media Session metadata.
final class MediaService {
    enum Command { case toggle, next, previous }

    weak var model: IslandModel?

    /// Control Center's Now Playing. When it reports something, it wins; when it reports
    /// nothing (or can't run), the AppleScript polling below fills in.
    private var adapter: NowPlayingAdapter?
    private var adapterInfo: MediaInfo?
    private var legacyInfo: MediaInfo?

    private let queue = DispatchQueue(label: "notchisland.media")
    private var timer: Timer?
    private var busy = false
    private var scriptCache: [String: NSAppleScript] = [:]
    private var musicArt: (key: String, data: Data?)?

    struct Browser {
        let name: String
        let bundleID: String
        let safari: Bool
    }

    static let browsers: [Browser] = [
        Browser(name: "Safari", bundleID: "com.apple.Safari", safari: true),
        Browser(name: "Google Chrome", bundleID: "com.google.Chrome", safari: false),
        Browser(name: "Brave Browser", bundleID: "com.brave.Browser", safari: false),
        Browser(name: "Microsoft Edge", bundleID: "com.microsoft.edgemac", safari: false),
        Browser(name: "Vivaldi", bundleID: "com.vivaldi.Vivaldi", safari: false),
    ]

    /// Only tabs on these sites are inspected (keeps polling light and private).
    static let mediaSites = [
        "youtube.com", "youtu.be", "soundcloud.com", "twitch.tv", "vimeo.com",
        "open.spotify.com", "netflix.com", "music.apple.com", "bandcamp.com", "dailymotion.com",
    ]

    // JavaScript run inside the page. Single quotes only — it's embedded in an AppleScript string.
    private static let pickJS =
        "var ms=Array.prototype.slice.call(document.querySelectorAll('video,audio')).filter(function(x){return !x.muted&&(x.currentTime>0||!x.paused)});" +
        "var m=ms.filter(function(x){return !x.paused})[0]||ms[0];"

    static let infoJS =
        "(function(){" + pickJS +
        "if(!m)return '';" +
        "var md=navigator.mediaSession&&navigator.mediaSession.metadata;var art='';" +
        "if(md&&md.artwork&&md.artwork.length){art=md.artwork[md.artwork.length-1].src}" +
        "return JSON.stringify({t:(md&&md.title)||document.title,a:(md&&md.artist)||location.hostname,art:art,p:m.paused?1:0,c:m.currentTime||0,d:isFinite(m.duration)?m.duration:0})" +
        "})()"

    static let toggleJS = "(function(){" + pickJS + "if(m){if(m.paused){m.play()}else{m.pause()}}return ''})()"

    static let nextJS =
        "(function(){var b=document.querySelector('.ytp-next-button');if(b){b.click();return ''}" + pickJS +
        "if(m){m.currentTime=Math.min(m.duration||1e9,m.currentTime+10)}return ''})()"

    static let previousJS = "(function(){" + pickJS + "if(m){m.currentTime=m.currentTime>3?0:Math.max(0,m.currentTime-10)}return ''})()"

    static let browserBundleIDs: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac",
        "com.vivaldi.Vivaldi", "company.thebrowser.Browser", "org.mozilla.firefox", "com.operasoftware.Opera",
    ]

    private static var nameCache: [String: String] = [:]

    static func appName(_ bundleID: String) -> String {
        if let cached = nameCache[bundleID] { return cached }
        var name = bundleID
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            name = FileManager.default.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        }
        nameCache[bundleID] = name
        return name
    }

    // MARK: - Start

    func start() {
        if let a = NowPlayingAdapter() {
            adapter = a
            a.onUpdate = { [weak self] info in
                guard let self = self else { return }
                self.adapterInfo = info
                self.publish()
            }
            a.start()
        }
        // Fallback polling always runs, but only does work while Now Playing has nothing.
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
        poll()
    }

    func stop() {
        adapter?.stop()
    }

    /// Short status for the right-click menu.
    var statusText: String {
        guard let a = adapter else { return "Media: helper missing (fallback only)" }
        if a.isRunning { return adapterInfo != nil ? "Media: Now Playing ✓" : "Media: Now Playing running (nothing reported)" }
        return "Media: Now Playing helper stopped (fallback only)"
    }

    private func publish() {
        model?.updateMedia(adapterInfo ?? legacyInfo)
    }

    // MARK: - AppleScript polling (fallback)

    func poll() {
        if busy { return }
        if adapterInfo != nil {
            legacyInfo = nil
            return
        }
        busy = true
        let previousID = model?.media?.sourceID
        queue.async { [weak self] in
            guard let self = self else { return }
            var hints: [String] = []
            let candidates = self.collect(hints: &hints)
            let best =
                candidates.first(where: { $0.isPlaying && $0.sourceID == previousID }) ??
                candidates.first(where: { $0.isPlaying }) ??
                candidates.first(where: { $0.sourceID == previousID }) ??
                candidates.first
            DispatchQueue.main.async {
                self.busy = false
                if self.model?.browserHint != hints.first { self.model?.browserHint = hints.first }
                self.legacyInfo = best
                self.publish()
            }
        }
    }

    private func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private func collect(hints: inout [String]) -> [MediaInfo] {
        var out: [MediaInfo] = []
        if isRunning("com.spotify.client"), let m = spotify(hints: &hints) { out.append(m) }
        if isRunning("com.apple.Music"), let m = music(hints: &hints) { out.append(m) }
        for b in Self.browsers where isRunning(b.bundleID) {
            out.append(contentsOf: browser(b, hints: &hints))
        }
        return out
    }

    private struct ScriptResult {
        var string: String? = nil
        var data: Data? = nil
        var error: String? = nil
    }

    private func run(_ source: String, cache: Bool = true) -> ScriptResult {
        let script: NSAppleScript
        if cache, let cached = scriptCache[source] {
            script = cached
        } else {
            guard let s = NSAppleScript(source: source) else { return ScriptResult(error: "Could not compile script") }
            if cache { scriptCache[source] = s }
            script = s
        }
        var err: NSDictionary?
        let result = script.executeAndReturnError(&err)
        if let err = err {
            return ScriptResult(error: (err[NSAppleScript.errorMessage] as? String) ?? "AppleScript error")
        }
        return ScriptResult(string: result.stringValue, data: result.data)
    }

    private func permissionHint(_ app: String, _ error: String) -> String? {
        let e = error.lowercased()
        if e.contains("not authorized") || e.contains("not allowed") || e.contains("-1743") {
            return "Allow NotchIsland to control \(app): System Settings → Privacy & Security → Automation."
        }
        return nil
    }

    private func number(_ s: String) -> Double {
        Double(s.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) ?? 0
    }

    // MARK: - Spotify

    private func spotify(hints: inout [String]) -> MediaInfo? {
        let src = """
        tell application "Spotify"
            if player state is stopped then return "stopped"
            set t to current track
            return (player state as string) & "|~|" & (name of t) & "|~|" & (artist of t) & "|~|" & (artwork url of t) & "|~|" & ((player position) as string) & "|~|" & (((duration of t) / 1000) as string)
        end tell
        """
        let r = run(src)
        if let e = r.error { if let h = permissionHint("Spotify", e) { hints.append(h) }; return nil }
        guard let s = r.string, s != "stopped" else { return nil }
        let p = s.components(separatedBy: "|~|")
        guard p.count >= 6 else { return nil }
        return MediaInfo(source: .spotify, title: p[1], artist: p[2],
                         artworkURL: p[3].isEmpty ? nil : p[3], artworkData: nil,
                         isPlaying: p[0] == "playing", position: number(p[4]), duration: number(p[5]),
                         sampledAt: Date())
    }

    // MARK: - Apple Music

    private func music(hints: inout [String]) -> MediaInfo? {
        let src = """
        tell application "Music"
            if player state is stopped then return "stopped"
            set t to current track
            set d to 0
            try
                set d to duration of t
            end try
            return (player state as string) & "|~|" & (name of t) & "|~|" & (artist of t) & "|~|" & ((player position) as string) & "|~|" & (d as string)
        end tell
        """
        let r = run(src)
        if let e = r.error { if let h = permissionHint("Music", e) { hints.append(h) }; return nil }
        guard let s = r.string, s != "stopped" else { return nil }
        let p = s.components(separatedBy: "|~|")
        guard p.count >= 5 else { return nil }

        let key = p[1] + "|" + p[2]
        if musicArt?.key != key {
            let art = run("""
            tell application "Music"
                try
                    return raw data of artwork 1 of current track
                end try
                return ""
            end tell
            """)
            let data = (art.error == nil && (art.data?.count ?? 0) > 100) ? art.data : nil
            musicArt = (key, data)
        }

        return MediaInfo(source: .music, title: p[1], artist: p[2], artworkURL: nil,
                         artworkData: musicArt?.data, isPlaying: p[0] == "playing",
                         position: number(p[3]), duration: number(p[4]), sampledAt: Date())
    }

    // MARK: - Browsers (YouTube & friends)

    private func browser(_ b: Browser, hints: inout [String]) -> [MediaInfo] {
        let condition = Self.mediaSites.map { "u contains \"\($0)\"" }.joined(separator: " or ")
        let exec = b.safari ? "do JavaScript js in t" : "execute t javascript js"
        let src = """
        set js to "\(Self.infoJS)"
        set out to ""
        tell application "\(b.name)"
            set wi to 0
            repeat with w in windows
                set wi to wi + 1
                set ti to 0
                try
                    repeat with t in tabs of w
                        set ti to ti + 1
                        set u to ""
                        try
                            set u to URL of t
                        end try
                        if u is missing value then set u to ""
                        if \(condition) then
                            set r to ""
                            try
                                set r to \(exec)
                            on error errMsg
                                return "ERR|~|" & errMsg
                            end try
                            if r is not missing value and r is not "" then set out to out & wi & "|~|" & ti & "|~|" & u & "|~|" & r & linefeed
                        end if
                    end repeat
                end try
            end repeat
        end tell
        return out
        """
        let r = run(src)
        if let e = r.error {
            if let h = permissionHint(b.name, e) { hints.append(h) }
            return []
        }
        guard let s = r.string, !s.isEmpty else { return [] }
        if s.hasPrefix("ERR|~|") {
            let menu = b.safari ? "Develop menu (Settings → Advanced → Show features for web developers)" : "View → Developer"
            hints.append("To show YouTube: in \(b.name), turn on “Allow JavaScript from Apple Events” (\(menu)).")
            return []
        }

        var results: [MediaInfo] = []
        for line in s.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let parts = String(line).components(separatedBy: "|~|")
            guard parts.count >= 4, let wi = Int(parts[0]), let ti = Int(parts[1]) else { continue }
            let url = parts[2]
            let json = parts[3...].joined(separator: "|~|")
            guard let data = json.data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }

            var art = (o["art"] as? String) ?? ""
            if art.isEmpty || art.hasPrefix("blob:"), let id = Self.youTubeID(url) {
                art = "https://i.ytimg.com/vi/\(id)/hqdefault.jpg"
            }
            var title = (o["t"] as? String) ?? ""
            if title.hasSuffix(" - YouTube") { title = String(title.dropLast(10)) }

            results.append(MediaInfo(
                source: .browser(app: b.name, bundleID: b.bundleID, safari: b.safari, window: wi, tab: ti, url: url),
                title: title,
                artist: (o["a"] as? String) ?? "",
                artworkURL: art.isEmpty ? nil : art,
                artworkData: nil,
                isPlaying: ((o["p"] as? NSNumber)?.intValue ?? 1) == 0,
                position: (o["c"] as? NSNumber)?.doubleValue ?? 0,
                duration: (o["d"] as? NSNumber)?.doubleValue ?? 0,
                sampledAt: Date()
            ))
        }
        return results
    }

    static func youTubeID(_ url: String) -> String? {
        guard let comps = URLComponents(string: url), let host = comps.host?.lowercased() else { return nil }
        if host.contains("youtu.be") { return comps.path.split(separator: "/").first.map(String.init) }
        if host.contains("youtube.com") {
            if let v = comps.queryItems?.first(where: { $0.name == "v" })?.value { return v }
            let parts = comps.path.split(separator: "/")
            if parts.count >= 2, parts[0] == "shorts" || parts[0] == "live" { return String(parts[1]) }
        }
        return nil
    }

    // MARK: - Commands

    func send(_ command: Command, to m: MediaInfo) {
        queue.async { [weak self] in
            guard let self = self else { return }
            switch m.source {
            case .nowPlaying:
                switch command {
                case .toggle: self.adapter?.send(.togglePlayPause)
                case .next: self.adapter?.send(.nextTrack)
                case .previous: self.adapter?.send(.previousTrack)
                }
                return
            case .spotify, .music:
                let app = m.source == .spotify ? "Spotify" : "Music"
                let verb: String
                switch command {
                case .toggle: verb = "playpause"
                case .next: verb = "next track"
                case .previous: verb = "previous track"
                }
                _ = self.run("tell application \"\(app)\" to \(verb)", cache: false)
            case .browser(let app, _, let safari, let w, let t, _):
                let js: String
                switch command {
                case .toggle: js = Self.toggleJS
                case .next: js = Self.nextJS
                case .previous: js = Self.previousJS
                }
                let src = safari
                    ? "tell application \"\(app)\" to do JavaScript \"\(js)\" in tab \(t) of window \(w)"
                    : "tell application \"\(app)\" to execute tab \(t) of window \(w) javascript \"\(js)\""
                _ = self.run(src, cache: false)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.poll() }
        }
    }

    /// Brings the source app (and the exact browser tab) to the front.
    func open(_ m: MediaInfo) {
        switch m.source {
        case .nowPlaying:
            if let id = m.appBundleID { activate(id) }
        case .music:
            activate("com.apple.Music")
        case .spotify:
            activate("com.spotify.client")
        case .browser(let app, _, let safari, let w, let t, _):
            let src = safari
                ? """
                  tell application "\(app)"
                      set current tab of window \(w) to tab \(t) of window \(w)
                      set index of window \(w) to 1
                      activate
                  end tell
                  """
                : """
                  tell application "\(app)"
                      set active tab index of window \(w) to \(t)
                      set index of window \(w) to 1
                      activate
                  end tell
                  """
            queue.async { [weak self] in _ = self?.run(src, cache: false) }
        }
    }

    func activate(_ bundleID: String) {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?
            .activate(options: [.activateAllWindows])
    }
}
