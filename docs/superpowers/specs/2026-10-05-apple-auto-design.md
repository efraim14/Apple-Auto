# Apple-Auto — Design Spec

**Date:** 2026-10-05
**Status:** Draft, awaiting review

## 1. Goal

Turn an iPhone 6 (iOS 12.5.7, max supported) into an Android Auto head unit for an
Oppo Find N3, connected over the Oppo's personal hotspot. Personal use only; never
distributed via the App Store.

### Success criteria (v1)

- The Android Auto UI from the Oppo renders on the iPhone 6 in landscape.
- Touch on the iPhone controls Android Auto.
- The app reconnects on its own after the connection drops, reliably enough to use while driving.

### Out of scope (v1)

- Audio. Media and navigation sound stay on the Oppo (its speaker or its Bluetooth link to
  the car). The iPhone advertises no audio sinks.
- Microphone, Google Assistant, calls.
- USB connection, Bluetooth-based wireless AA handshake.
- App Store distribution.

Audio (iPhone as media/nav audio sink) is the planned v2 follow-up.

## 2. Constraints

| Constraint | Consequence |
|---|---|
| iPhone 6 tops out at iOS 12.5.7 | Deployment target iOS 12.0. No Swift concurrency (`async/await` needs iOS 13), no SwiftUI, no Combine. UIKit + GCD + callbacks. |
| Developer works on Windows/WSL, no Mac | iOS builds run on GitHub Actions macOS runners; the Xcode project is generated (XcodeGen), never hand-edited. Protocol work is developed and tested on Linux. |
| AA only accepts a Google-signed head-unit cert | We use a head-unit certificate+key extracted from existing software (as open-source head units do). It is never committed; it lives in a gitignored local file and a GitHub Actions secret. |
| AA TLS is tunnelled inside AA messages | Network.framework TLS is unusable. OpenSSL is driven through memory BIOs. |
| Free Apple ID signing | App expires every 7 days; re-sign with Sideloadly/AltStore. CI produces an **unsigned** `.ipa`. |
| aasdk `.proto` files are GPLv3 | Project license: GPLv3. |
| Pinned Xcode | CI pins an Xcode version that still supports an iOS 12.0 deployment target. Verified during M0. |

## 3. Connection model

The Oppo runs Android Auto's developer-mode **head unit server**, which listens on TCP
port 5277. The iPhone joins the Oppo's hotspot and connects to `<hotspot gateway>:5277`.
This is the same mechanism Google's Desktop Head Unit and Headunit Reloaded's Wi-Fi mode
use. No Bluetooth involved.

## 4. Architecture

```
Apple-Auto/
├─ Package.swift              SwiftPM package; builds on Linux and iOS
├─ Sources/AAProtocol/        protocol core, no UI, no platform-specific APIs
│   ├─ Transport              POSIX TCP socket (shared Linux/iOS)
│   ├─ Framing                AA frame encode/decode, fragment reassembly
│   ├─ Cryptor                OpenSSL client-mode TLS over memory BIOs
│   ├─ Session                state machine: version → TLS → auth → discovery → running
│   └─ Channels               control, video, input, sensor
├─ Sources/aaprobe/           Linux CLI (connect + dump H.264; log receiver)
├─ Proto/                     AA .proto definitions → SwiftProtobuf generated code
├─ App/                       iOS app (UIKit)
│   ├─ project.yml            XcodeGen spec
│   ├─ VideoView              AVSampleBufferDisplayLayer H.264 rendering
│   ├─ TouchMapper            view points → 1280×720 AA touch coordinates
│   └─ StatusView             "Waiting for phone…", manual IP entry, errors
├─ Tests/AAProtocolTests/
└─ .github/workflows/         linux.yml (build+test), ios.yml (OpenSSL, xcodegen, unsigned .ipa)
```

### Unit responsibilities

- **Transport**: connect, read bytes, write bytes, close. Reports bytes and disconnects
  through callbacks. Knows nothing about AA.
- **Framing**: converts byte stream ↔ frames (channel id, flags: first/last fragment,
  control/data, encrypted; length; total length for fragmented first frames). Reassembles
  fragments into whole messages. Pure, fully unit-testable.
- **Cryptor**: wraps OpenSSL `SSL` with a read/write memory-BIO pair. API: feed incoming
  handshake bytes, get outgoing handshake bytes, `isHandshakeComplete`, `encrypt(Data)`,
  `decrypt(Data)`. Loads cert+key from PEM supplied by the caller.
- **Session**: owns Transport, Framing, Cryptor, and channels. Drives the state machine,
  routes messages to channels by channel id, and tears everything down on any error.
  Runs on one serial `DispatchQueue`.
- **Channels**: one type per AA service. Control (version, ping, audio focus replies,
  service discovery, channel open), Video (setup, focus, frames → delegate, media acks),
  Input (touch events out), Sensor (driving status, night mode).
- **iOS app**: thin. Hosts the Session, renders video frames, maps touches, shows
  status, forwards logs.

### Platform split

`AAProtocol` uses no Apple-only APIs. OpenSSL is linked as a system library on Linux and
as a prebuilt OpenSSL xcframework on iOS; CI builds it once and caches it.

## 5. Data flow

1. **Discover gateway**: read the default route from the routing table (`sysctl`
   `NET_RT_FLAGS`). Fallback: manual IP entry, persisted in `UserDefaults`.
2. **TCP connect** to `<gateway>:5277`.
3. **Version exchange**: the iPhone sends a version request on control channel 0 and the
   Oppo replies.
4. **TLS handshake**: the iPhone is the TLS client and presents the head-unit certificate.
   Handshake records are carried in AA SSL-handshake messages until complete. The iPhone
   then sends *auth complete* (OK). All later messages are encrypted.
5. **Service discovery**: the iPhone answers the Oppo's request with:
   - Video sink: H.264 baseline, **1280×720 @ 30fps**, with margins so the stream fits the
     1334×750 display at its 16:9 aspect ratio.
   - Input source: touchscreen 1280×720.
   - Sensor source: driving status, night mode.
   - No audio sinks, no microphone.
6. **Channel open**: the iPhone accepts each channel-open request.
7. **Sensors**: on sensor start requests, the iPhone sends driving status = unrestricted
   and the night-mode state (v1: day; M5: follows ambient/time).
8. **Video**: setup request → config response (max unacked frames) → video focus
   granted → frames arrive. The first frame is codec config (SPS/PPS). The iPhone acks
   every frame; unacked frames throttle the sender.
9. **Touch**: UIKit touches → scaled to 1280×720 → AA input event (action, pointer id,
   x, y, timestamp).
10. **Housekeeping**: reply to pings. Reply to audio-focus requests (granted/loss as
    appropriate) so AA does not stall waiting for an answer.

## 6. Error handling & reliability

- **Any error** (socket closed, read/write failure, framing error, TLS failure,
  a known message arriving out of order for the current session state, ping timeout) → full session teardown → status
  screen → retry every 3 s with a brand-new Session. Never patch a half-broken session.
- **Foreground only**: iOS suspends backgrounded apps' sockets. The app sets
  `isIdleTimerDisabled = true`. The README recommends Guided Access in the car.
- **Logging**: a single logger writes to a rotating local file and, optionally, sends UDP
  to a configured PC address. `aaprobe logs` listens and prints. This substitutes for the
  Xcode console.
- **Unknown messages** on a known channel are logged and ignored. They are not treated as
  errors.

## 7. Testing

- **Unit tests (Linux, CI)**:
  - Framing: encode/decode, every flag combination, fragmentation and reassembly, partial reads.
  - Cryptor: client↔server round trip over memory BIOs using a throwaway self-signed
    cert generated in the test.
  - Session: state machine driven by a scripted fake phone (sequence of messages in →
    expected messages out), including error paths leading to teardown.
  - TouchMapper: coordinate scaling including margins.
- **Manual integration (PC)**: the PC joins the Oppo hotspot and runs `aaprobe connect --out out.h264`;
  `ffplay out.h264` shows the AA UI.
- **iOS**: CI build verifies compilation; a manual on-device checklist ships in the README.

## 8. Build & install pipeline

- `linux.yml`: `swift build` + `swift test` on Ubuntu.
- `ios.yml` (macOS runner, pinned Xcode): build/cache the OpenSSL xcframework → inject the cert
  from a secret into the app bundle → `xcodegen` → `xcodebuild` with
  `CODE_SIGNING_ALLOWED=NO` → package `Payload/AppleAuto.app` into `AppleAuto.ipa` → upload
  as an artifact.
- Install: download the artifact → Sideloadly (Windows, free Apple ID) → re-sign weekly.

## 9. Milestones

| | Deliverable | Proves |
|---|---|---|
| M0 | Hello-world UIKit app built by CI, installed via Sideloadly on the iPhone 6 | Toolchain, iOS 12 target, install loop |
| M1 | `aaprobe` completes version + TLS + auth with the Oppo | Cert and TLS tunnelling |
| M2 | `aaprobe` writes playable H.264 | Protocol core complete |
| M3 | Video on the iPhone | iOS rendering |
| M4 | Touch works | Usable v1 |
| M5 | Auto-reconnect polish, night mode | Car-ready |

## 10. Open risks

- **Head-unit certificate**: one must be obtained, and Google could revoke or reject it.
  Validated at M1, before any iOS UI work.
- **Oppo/ColorOS**: may kill the head unit server in the background, or randomize the hotspot
  subnet. Mitigated by background-battery whitelisting and gateway discovery.
- **Xcode iOS 12 support**: newer Xcode releases may drop the iOS 12.0 deployment target.
  Validated at M0 by pinning a compatible Xcode on the runner.
- **SwiftProtobuf / OpenSSL minimum iOS**: library versions must be pinned to ones that
  support iOS 12.
- **Protocol version drift**: newer Android Auto versions may require newer protocol
  fields. aasdk forks and OpenAuto are the reference for updates.
