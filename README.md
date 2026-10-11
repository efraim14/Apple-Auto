# Apple Auto

Use an old iPhone 6 (iOS 12.5.7) as an Android Auto head unit over a phone's hotspot. Personal project.
Design: `docs/superpowers/specs/2026-10-05-apple-auto-design.md`.

## Install on the iPhone
1. Download the `AppleAuto-ipa` artifact from the latest `ios` workflow run (Actions tab).
2. Install Sideloadly (Windows, free Apple ID; iTunes/iCloud from apple.com, not the Microsoft Store).
3. Drag `AppleAuto.ipa` into Sideloadly, pick the iPhone, Start. Re-sign every 7 days.
4. On the iPhone: Settings → General → Device Management → trust your Apple ID.

## Linux dev (WSL)
`export PATH="$HOME/swift/swift-6.1-RELEASE-ubuntu22.04/usr/bin:$PATH"`, then
`swift test --scratch-path "$HOME/.cache/apple-auto-build"`.

## Certificate
The head-unit certificate is **never committed**. See the spec, §2 and §6.

License: GPLv3.
