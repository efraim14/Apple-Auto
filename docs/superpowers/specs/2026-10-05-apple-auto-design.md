# Apple-Auto — Design Spec

**Date:** 2026-10-05
**Status:** Approved (brainstormed + grilled 2026-10-05)

## 1. Goal

Turn an iPhone 6 (iOS 12.5.7, max supported) into an Android Auto head unit for an
Oppo Find N3, connected over the Oppo's personal hotspot. Personal use only; never
distributed via the App Store.

### Success criteria (v1)

- The Android Auto UI from the Oppo renders on the iPhone 6 in landscape.
- One- and two-finger touch on the iPhone controls Android Auto.
- The app reconnects on its own after the connection drops, reliably enough to use while driving.

### Out of scope (v1)

- Audio. Media and navigation sound stay on the Oppo, which plays through the car's
  Bluetooth. The iPhone advertises no audio sinks.
- Microphone, Google Assistant, calls.
- USB connection, Bluetooth-based wireless AA handshake.
- App Store distribution.
- Automating the head-unit-server start on the Oppo. Investigated in M5 only.

Audio (iPhone as media/nav audio sink) is the planned v2 follow-up.

## 2. Constraints

| Constraint | Consequence |
|---|---|
| iPhone 6 tops out at iOS 12.5.7 | Deployment target iOS 12.0. No Swift concurrency (`async/await` needs iOS 13), no SwiftUI, no Combine. UIKit + GCD + callbacks. |
| Developer works on Windows/WSL, no Mac | iOS builds run on GitHub Actions `macos-15` with **Xcode 16.4** pinned (the last line verified to accept an iOS 12 target; Xcode 27 rejects it). The Xcode project is generated (XcodeGen), never hand-edited. Protocol work is developed and tested on Linux. |
| Xcode 16.4 = Swift 6.1 | **SwiftProtobuf pinned to 1.33.x** (1.34+ needs swift-tools 6.2). |
| OpenSSL needed on both platforms | iOS: `krzyzanowskim/OpenSSL-Package` (binary xcframework, declares iOS 12). Linux: system OpenSSL via a SwiftPM `systemLibrary` target. |
| AA only accepts a Google-signed head-unit cert | Use the publicly available head-unit cert+key shipped by `opencardev/aasdk` (`cert/headunit.crt`/`.key`). **Never in the repo or any CI artifact.** It is imported once on the phone (§6), and given to `aaprobe` by file path. |
| AA TLS is tunnelled inside AA messages | Network.framework TLS is unusable. OpenSSL is driven through memory BIOs. |
| Free Apple ID signing | Install only via **Sideloadly** (Windows; needs non-Store iTunes/iCloud). AltStore no longer supports iOS 12. App expires every 7 days; re-sign weekly. CI produces an **unsigned** `.ipa`. |
| AA `.proto` files from `opencardev/aasdk` (GPLv3) | Project license: GPLv3. |

## 3. Connection model

The Oppo runs Android Auto's developer-mode **head unit server** (Android Auto → tap
the version 10× → ⋮ → *Start head unit server*). It listens on TCP 5277 and shows a
foreground notification while running. The Oppo must be unlocked to start it. The
iPhone joins the Oppo's hotspot and connects to `<hotspot gateway>:5277`.

v1 accepts starting the server by hand each drive. Expect to restart it after it stops.

## 4. Architecture

```
Apple-Auto/
├─ Package.swift              SwiftPM package; builds on Linux and iOS
├─ Sources/COpenSSL/          systemLibrary target (Linux only)
├─ Sources/AAProtocol/        protocol core, no UI, no platform-specific APIs
│   ├─ Transport              POSIX TCP socket (shared Linux/iOS)
│   ├─ Framing                AA frame encode/decode, fragment reassembly
│   ├─ Cryptor                OpenSSL client-mode TLS over memory BIOs
│   ├─ Session                state machine: version → TLS → auth → discovery → running
│   └─ Channels               control, video, input, sensor
├─ Sources/aaprobe/           Linux CLI: `connect` (dump H.264), `logs` (UDP log receiver)
├─ Proto/                     AA .proto definitions (from opencardev/aasdk) → SwiftProtobuf
├─ App/                       iOS app (UIKit)
│   ├─ project.yml            XcodeGen spec
│   ├─ VideoView              AVSampleBufferDisplayLayer H.264 rendering
│   ├─ TouchMapper            view points → 1280×720 AA touch coordinates (2 pointers)
│   ├─ StatusView             connection state, which gateway method worked, errors
│   ├─ SettingsView           manual IP, DPI, night schedule, log target, cert import
│   └─ Overlay                3-finger long-press → Disconnect / Settings
├─ Tests/AAProtocolTests/
└─ .github/workflows/         linux.yml (build+test), ios.yml (xcodegen, unsigned .ipa)
```

### Unit responsibilities

- **Transport**: connect, read bytes, write bytes, close. Reports bytes and disconnects
  through callbacks. Knows nothing about AA.
- **Framing**: converts byte stream ↔ frames (channel id; flags: first/last fragment,
  control/data, encrypted; length; total length for fragmented first frames). Reassembles
  fragments into whole messages. Pure, fully unit-testable.
- **Cryptor**: wraps OpenSSL `SSL` with a read/write memory-BIO pair. API: feed incoming
  handshake bytes, get outgoing handshake bytes, `isHandshakeComplete`, `encrypt(Data)`,
  `decrypt(Data)`. Loads cert+key from PEM supplied by the caller.
- **Session**: owns Transport, Framing, Cryptor, and channels. Drives the state machine,
  routes messages to channels by channel id, and tears everything down on any error.
  Runs on one serial `DispatchQueue`. Configuration (resolution, DPI, night mode) is
  passed in.
- **Channels**: one type per AA service. Control (version, ping, audio-focus replies,
  service discovery, channel open), Video (setup, focus, frames → delegate, media acks),
  Input (touch events out), Sensor (driving status, night mode).
- **iOS app**: thin. Hosts the Session, renders video frames, maps touches, shows
  status/settings, forwards logs.

## 5. Data flow

1. **Discover gateway**, trying each step only if the previous one fails to connect:
   1. Default route from the routing table (`sysctl` `NET_RT_FLAGS`). This is widely used on iOS but not
      officially supported.
   2. The iPhone's own Wi-Fi (`en0`) IPv4 address with the last octet replaced by `.1`.
   3. Manual IP from settings (persisted in `UserDefaults`).
   The status screen shows which method succeeded.
2. **TCP connect** to `<gateway>:5277`.
3. **Version exchange**: the iPhone sends a version request on control channel 0 and the
   Oppo replies.
4. **TLS handshake**: the iPhone is the TLS client and presents the head-unit certificate.
   Handshake records are carried in AA SSL-handshake messages until complete. The iPhone
   then sends *auth complete* (OK). All later messages are encrypted.
5. **Service discovery**: the iPhone answers the Oppo's request with:
   - Video sink: H.264 baseline, **1280×720 @ 30fps**, density **160 dpi** (configurable),
     with margins so the stream fits the 1334×750 display at its 16:9 aspect ratio.
   - Input source: touchscreen 1280×720, multi-touch.
   - Sensor source: driving status, night mode.
   - No audio sinks, no microphone.
6. **Channel open**: the iPhone accepts each channel-open request.
7. **Sensors**: driving status = **always unrestricted**. Night mode = **fixed schedule**,
   default 18:00–06:00, editable in settings. Re-sent when the schedule boundary passes.
8. **Video**: setup request → config response (max unacked frames) → video focus
   granted → frames arrive. The first frame is codec config (SPS/PPS). The iPhone acks
   every frame; unacked frames throttle the sender.
9. **Touch**: UIKit touches (up to 2 fingers) → scaled to 1280×720 → AA input event
   (action, pointer id per finger, x, y, timestamp). Touches with 3+ fingers are never forwarded.
10. **Housekeeping**: reply to pings. Reply to audio-focus requests so AA does not stall
    waiting for an answer.

## 6. iOS app UX

- **Landscape only** (left and right). `isIdleTimerDisabled = true`. The README recommends
  Guided Access in the car.
- **First run**: the status screen asks for the certificate. **Import via a Files picker**
  (`UIDocumentPickerViewController`) of a combined `headunit.pem` (cert + key), with a
  **paste-text** fallback. Stored in the app's container. M0 verifies that a Sideloadly
  re-sign preserves the container; if it does not, storage moves to the Keychain.
- **Status screen**: "Waiting for phone…", current gateway attempt, last error, Settings
  button.
- **Settings screen** (in-app): manual IP, DPI, night schedule, log target (PC IP:port),
  certificate import/replace.
- **During a session**: video is fullscreen and every 1–2 finger touch goes to AA.
  **3-finger long press (1 s)** opens an overlay: Disconnect, Settings.
- Identity: bundle ID `io.github.efraim14.appleauto`, display name **Apple Auto**.

## 7. Error handling & reliability

- **Any error** (socket closed, read/write failure, framing error, TLS failure,
  a known message arriving out of order for the current session state, ping timeout) → full session teardown → status
  screen → retry every 3 s with a brand-new Session. Never patch a half-broken session.
- **Foreground only**: iOS suspends backgrounded apps' sockets. Going to the background tears the session down, and
  returning to the foreground restarts the retry loop.
- **Logging**: a single logger writes to a rotating local file and, optionally, sends UDP
  to the configured PC address. `aaprobe logs` listens and prints. This substitutes for the
  Xcode console.
- **Unknown messages** on a known channel are logged and ignored. They are not treated as
  errors.

## 8. Testing

- **Unit tests (Linux, CI)**:
  - Framing: encode/decode, every flag combination, fragmentation and reassembly, partial reads.
  - Cryptor: client↔server round trip over memory BIOs using a throwaway self-signed
    cert generated in the test.
  - Session: state machine driven by a scripted fake phone (sequence of messages in →
    expected messages out), including error paths leading to teardown.
  - TouchMapper: coordinate scaling including margins, two pointers, ignoring 3+ fingers.
  - Night-mode schedule: boundary and overnight-wrap cases.
- **Manual integration (PC)**: the PC joins the Oppo hotspot (WSL reaches it through Windows) and runs
  `aaprobe connect --cert headunit.pem --out out.h264`; `ffplay out.h264` shows the AA UI.
- **iOS**: CI build verifies compilation; a manual on-device checklist ships in the README.

## 9. Build, install & workflow

- `linux.yml`: `swift build` + `swift test` on Ubuntu, on every push and PR.
- `ios.yml`: on push to `main` and manual dispatch. Runs on `macos-15`, selects Xcode 16.4 →
  `xcodegen` → `xcodebuild` with `CODE_SIGNING_ALLOWED=NO` → package
  `Payload/AppleAuto.app` into `AppleAuto.ipa` → upload as an artifact (7-day retention). No
  certificate is involved.
- Install: download the artifact → Sideloadly (free Apple ID) → re-sign weekly.
- Git: one branch per milestone (`m0-pipeline`, `m1-handshake`, …), merged to `main`
  via PR after user approval.

## 10. Milestones

| | Deliverable | Proves |
|---|---|---|
| M0 | Hello-world UIKit app built by CI, installed via Sideloadly on the iPhone 6; check that re-signing keeps app data | Toolchain, iOS 12 target, install loop, storage persistence |
| M1 | `aaprobe` completes version + TLS + auth with the Oppo. Also: does the head unit server survive the Oppo being locked for 10 min? | Cert and TLS tunnelling; daily-use workflow |
| M2 | `aaprobe` writes playable H.264 | Protocol core complete |
| M3 | Video on the iPhone; tune DPI | iOS rendering |
| M4 | Two-finger touch, 3-finger overlay, settings, cert import | Usable v1 |
| M5 | Auto-reconnect polish, night schedule, look into automating the head-unit-server start | Car-ready |

**Stop rule (M1):** if AA rejects the opencardev cert, try the other publicly available
head-unit certs (e.g. the one Headunit Reloaded uses). If all are rejected, stop the project
before any iOS UI work.

## 11. Open risks

- **Head-unit certificate rejected or revoked by Google.** Validated at M1; see the stop rule.
- **Head unit server reliability.** It may stop when the Oppo is locked, or be killed by ColorOS.
  A start-failure report was filed against open-headunit on 2026-09-26 with no recorded fix. Checked at M1; mitigated by
  background-battery whitelisting and the M5 automation investigation.
- **Routing-table gateway lookup** is not officially supported on iOS. Two fallbacks exist.
- **opencardev/aasdk compatibility with current AA** is unconfirmed. Validated at M1/M2.
- **Sideloadly re-sign may wipe app data.** Checked at M0; fall back to the Keychain.
- **Hotspot subnet**: ColorOS may randomize it, and the gateway discovery chain handles that.
