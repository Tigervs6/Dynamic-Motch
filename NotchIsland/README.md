# NotchIsland

**A Dynamic Island for your MacBook's notch.** The notch grows into a live, animated island for music,
incoming calls, notifications, timers, charging and more. Hover to expand it, and swipe up to tuck it back in.

> Requires a MacBook with a notch (MacBook Pro 14"/16" 2021 or later, MacBook Air M2 or later) and macOS 13 or later.
> Not affiliated with Apple.

## Features

| | |
|---|---|
| 🎵 **Now Playing** | Anything Control Center shows: Spotify, Apple Music, Podcasts, and YouTube or other video in any browser. Shows artwork, a waveform tinted to match the art, a progress bar, and play/pause/skip controls. |
| 📞 **Incoming calls** | FaceTime, iPhone calls on your Mac, WhatsApp, Zoom, Teams and more, with the caller's name and **Accept / Decline** buttons. After you answer, it shows a call timer. |
| 💬 **Notifications** | Message, Mail and Slack banners (and any other app's) drop out of the notch. Click one to open it. You can also hide the regular macOS banners so notifications only appear in the notch. |
| 📤 **AirDrop** | Incoming AirDrop appears in the notch with **Accept / Decline** and a progress bar. Drag files onto the notch and they wait there, ready to AirDrop with one click. |
| ⏱ **Timers** | Quick 1/5/10/25-minute timers, with a live countdown next to the notch. |
| 🔋 **Charging & battery** | Charging animation when you plug in; warnings at 20% and 10%. |
| 🎧 **AirPods & Bluetooth** | A banner when devices connect or disconnect. |
| 🟢 **Privacy dots** | Green when the camera is in use, orange for the microphone. |

**Gestures:**
- **Hover** over the notch to expand it.
- **Click** to jump to the app that's playing.
- **Two-finger swipe up** (or drag the island up) to push it back into the notch and hide it.
- **Two-finger swipe down** on the notch to bring it back.
- **Swipe sideways** to switch between two activities.
- **Drag files onto the notch** to park them there for AirDrop.
- **Right-click** for options.

## Install

### Option A: download (easiest)

1. Download **NotchIsland.zip** from the [Releases](../../releases) page and unzip it.
2. Drag **NotchIsland.app** into your Applications folder.
3. The app isn't notarized by Apple yet, so macOS blocks it the first time. To allow it, pick one:
   - Open it once, then go to **System Settings → Privacy & Security** and click **Open Anyway**.
   - Or run this in Terminal:
     ```
     xattr -dr com.apple.quarantine /Applications/NotchIsland.app
     ```
4. Open NotchIsland. It has no Dock icon; just hover over your notch.

### Option B: build it yourself

```
git clone https://github.com/<you>/NotchIsland.git
cd NotchIsland
./build.sh
```

You need Apple's command line tools (`xcode-select --install`). `build.sh` compiles the app and signs it with a local
certificate that it creates in your keychain. Because the signature stays the same, macOS remembers the app's
permissions across rebuilds. If a keychain window asks about `codesign`, click **Always Allow**.

## Permissions

| Permission | What it's for | Where |
|---|---|---|
| **Accessibility** | Showing notifications and calls in the notch, and making Accept / Decline work | System Settings → Privacy & Security → Accessibility. Turn NotchIsland on, or click **+** and add it. |
| Bluetooth | Showing AirPods and other devices connecting | Asked automatically |
| Automation (optional) | Backup media reading for Music, Spotify and browser tabs, if Now Playing isn't available | Asked automatically |

Everything else works without any permissions.

## Privacy

NotchIsland runs entirely on your Mac. It has **no analytics, no accounts and no servers**. The only network requests
it makes are to download album or video artwork that a media app points it to.

To show notifications and calls, it reads what's on screen through the Accessibility permission. That text is only
kept in memory while it's being shown. The log file (`~/Library/Logs/NotchIsland.log`) contains only technical
events. Message text, caller names and song titles are logged only if you turn on
**right-click → Debug logging**.

## Troubleshooting

- **Nothing happens when I hover:** make sure the app is running. Right-click where the notch is; if nothing appears, open the app again.
- **Notifications or calls don't show:** turn on Accessibility (see above), then quit and reopen the app.
  Right-click the notch → **Test notification** / **Test incoming call** checks that the animations work.
- **Media doesn't show:** right-click the notch. The menu shows the media status. Then **Open log**
  and look at the lines starting with `Media:`.
- **Quit:** right-click the notch → **Quit NotchIsland**.

Found a bug? Please [open an issue](../../issues). Include the lines from the log, with Debug logging off unless
you're comfortable sharing message content.

## How it works

| File | What it does |
|---|---|
| `NotchGeometry.swift` | Reads the exact notch size from macOS |
| `NotchShape.swift` | The black shape that grows out of the notch, and its transitions |
| `IslandModel.swift` | States (idle / compact / alert / expanded), sizes, priorities |
| `IslandViews.swift` | Everything you see |
| `MouseTracker.swift` | Hover, click-through, trackpad swipes |
| `NowPlayingAdapter.swift` | Control Center Now Playing, via the bundled helper |
| `MediaService.swift` | Media sources and controls, including the AppleScript fallback |
| `CallMonitor.swift` | Incoming call detection and Accept / Decline |
| `NotificationMonitor.swift` | Notification banners and incoming AirDrop |
| `SystemMonitors.swift` | Camera/mic, battery, Bluetooth |
| `Log.swift` | Privacy-aware logging |

Since macOS 15.4, only Apple-signed programs can read Now Playing. NotchIsland therefore uses the open-source
[mediaremote-adapter](https://github.com/ungive/mediaremote-adapter), which runs through `/usr/bin/perl`.
A future macOS update may break this; if it does, the app falls back to reading Music, Spotify and browser tabs directly.

## Releasing

Push a version tag and GitHub Actions builds `NotchIsland.zip` and attaches it to a release:

```
git tag v1.0 && git push origin v1.0
```

## License

MIT, see [LICENSE](LICENSE). Includes mediaremote-adapter (BSD-3-Clause), see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
