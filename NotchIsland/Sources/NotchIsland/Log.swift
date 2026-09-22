import Foundation

/// When on, the log also records content (notification text, caller names, song titles).
/// Off by default — turn on from the right-click menu only while troubleshooting.
var notchDebugLogging: Bool {
    get { UserDefaults.standard.bool(forKey: "debugLogging") }
    set { UserDefaults.standard.set(newValue, forKey: "debugLogging") }
}

let notchLogURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/NotchIsland.log")

/// Appends a line to ~/Library/Logs/NotchIsland.log (right-click the notch → Open log).
/// `sensitive` lines (anything containing personal content) are only written with Debug logging on.
func notchLog(_ message: String, sensitive: Bool = false) {
    if sensitive && !notchDebugLogging { return }
    let url = notchLogURL
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    let fm = FileManager.default
    if let attrs = try? fm.attributesOfItem(atPath: url.path),
       let size = attrs[.size] as? NSNumber, size.intValue > 2_000_000 {
        try? fm.removeItem(at: url)
    }
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
    }
}
