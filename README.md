# Maro for iOS

The Omarchy Music Plugin's phone app, ported from the Android app to SwiftUI.
It signs in to the same marobotic.dev account, controls the desktop, and plays
on the phone itself with AVPlayer (lock screen and Control Center included).

## Build

There is no Xcode project in the repo: `project.yml` is an
[XcodeGen](https://github.com/yonaskolb/XcodeGen) spec. Every push to `main`
runs `.github/workflows/build.yml` on a macOS runner, which generates the
project and builds an unsigned `Maro.ipa` (artifact `Maro-ipa`).

## Install (free Apple ID)

1. Linux: install `usbmuxd` and `libimobiledevice`, plug the iPhone in, tap Trust.
2. Sign and install `Maro.ipa` with a sideloading tool that runs on Linux
   (Plume Impactor, or SideStore's iloader).
3. iPhone: Settings > Privacy & Security > Developer Mode on, then
   Settings > General > VPN & Device Management > trust the Apple ID.

Free signatures last 7 days; SideStore on the phone can refresh them.
