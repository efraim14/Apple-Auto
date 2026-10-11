# Apple-Auto M0 + M1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** M0 — a hello-world UIKit app built by GitHub Actions and installed on the iPhone 6. M1 — a Linux CLI (`aaprobe`) that completes version exchange, TLS and auth with the Oppo's Android Auto head unit server.

**Architecture:** A SwiftPM package (`AAProtocol` library + `aaprobe` executable) that builds and tests on Linux/WSL. The protocol core is split into pure, separately testable units (Framing, Cryptor, Session) plus a thin POSIX Transport. The iOS app is a separate XcodeGen project in `App/`; in M0 it does not use `AAProtocol` yet.

**Tech Stack:** Swift 6.1 (tools-version 5.9, Swift 5 mode), XCTest, OpenSSL via a SwiftPM `systemLibrary`, XcodeGen, GitHub Actions (`ubuntu-22.04`, `macos-15` + Xcode 16.4), Sideloadly.

**Spec:** `docs/superpowers/specs/2026-10-05-apple-auto-design.md`

**Deliberate narrowing vs. the spec (M1 only):** M1 hand-encodes the two tiny protobuf messages it needs (version request, auth-complete status), so SwiftProtobuf and the `.proto` files arrive in the M2 plan. `OpenSSL-Package` for iOS is wired in the M3 plan. M0's workflow also triggers on pull requests touching `App/**` so a branch can be built before the workflow exists on `main`.

## Global Constraints

- iOS deployment target **12.0**; no `async/await`, SwiftUI, Combine. UIKit + GCD + callbacks.
- iOS CI: runner **`macos-15`**, **Xcode 16.4** (`/Applications/Xcode_16.4.app`), unsigned build (`CODE_SIGNING_ALLOWED=NO`), artifact retention **7 days**.
- Bundle ID **`io.github.efraim14.appleauto`**, display name **Apple Auto**, landscape only (left + right).
- Project license **GPLv3**.
- **The head-unit certificate/key is never committed** and never in a CI artifact (`*.pem`, `*.key`, `*.crt` are gitignored).
- Linux: OpenSSL driven through memory BIOs; `AAProtocol` uses no Apple-only APIs.
- One branch per milestone (`m0-pipeline`, `m1-handshake`), merged to `main` by PR after user approval.
- Linux builds on this machine use `--scratch-path "$HOME/.cache/apple-auto-build"` (the repo lives on `/mnt/c`, where SwiftPM builds are slow and flaky).
- Commit messages end with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`; PR descriptions end with `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.

## Review Focus

Input classes the spec implies but nothing in it pins down (each has a test in the owning task):

1. A message split across several socket reads, or several messages in one read (Task 4: `testByteAtATime`, `testTwoMessagesInOneFeed`).
2. A garbage or hostile frame stream: orphan fragments, a huge fragmented message (Task 4: `testOrphanLastFragmentThrows`, `testOversizeThrows`).
3. A missing, malformed, or mismatched certificate/key file (Task 5: `testGarbagePEMThrows`, `testKeyMismatchThrows`).
4. The peer sending a known control message at the wrong time, or reporting a version mismatch (Task 6: `testUnexpectedMessageThrows`, `testVersionMismatchThrows`).
5. The phone never answering, or closing the socket mid-handshake (Task 7: `testReadTimesOut`, `testReadReturnsNilOnClose`; `aaprobe` exits non-zero with a message instead of hanging).

## File Structure

| File | Responsibility |
|---|---|
| `LICENSE`, `.gitignore`, `README.md` | GPLv3 text, secrets/build ignores, how to build/install/test |
| `App/project.yml` | XcodeGen spec (target, bundle ID, iOS 12.0, landscape, launch storyboard) |
| `App/Sources/AppDelegate.swift` | App entry; disables idle timer |
| `App/Sources/ViewController.swift` | M0 hello screen: iOS version, launch counter persisted in Documents |
| `App/Sources/LaunchScreen.storyboard` | Required on iOS 12 or the app runs letterboxed in 320×480 |
| `.github/workflows/ios.yml` | macOS build → unsigned `.ipa` artifact |
| `.github/workflows/linux.yml` | `swift build` + `swift test` |
| `Package.swift` | Package manifest |
| `Sources/COpenSSL/{module.modulemap,shim.h}` | System OpenSSL module (Linux) |
| `Sources/AAProtocol/Framing.swift` | `Message`, frame encode, `FrameParser` (reassembly) |
| `Sources/AAProtocol/Cryptor.swift` | OpenSSL client/server TLS over memory BIOs |
| `Sources/AAProtocol/Session.swift` | M1 state machine: version → TLS → auth → discovery request |
| `Sources/AAProtocol/TCPSocket.swift` | Blocking POSIX socket with timeouts |
| `Sources/aaprobe/main.swift` | `aaprobe connect --host --cert [--port]` |
| `Tests/AAProtocolTests/*` | `FramingTests`, `CryptorTests`, `SessionTests` (+ `TestCert.swift`, `FakePhone.swift`), `TCPSocketTests` |

---

# M0 — Build pipeline + hello world

### Task 1: Linux toolchain (manual, needs sudo)

**Files:** none (machine setup).

The agent cannot run `sudo`. Ask the user to run each command with the `!` prefix.

- [ ] **Step 1: Install system packages** — user runs:

```bash
! sudo apt-get update && sudo apt-get install -y binutils git gnupg2 libc6-dev libcurl4-openssl-dev libedit2 libgcc-s1 libpython3-dev libsqlite3-0 libstdc++-11-dev libxml2-dev libz3-dev pkg-config tzdata unzip zlib1g-dev libssl-dev ffmpeg
```

- [ ] **Step 2: Install Swift 6.1** — agent runs:

```bash
mkdir -p "$HOME/swift" && cd "$HOME/swift" \
 && curl -fLO https://download.swift.org/swift-6.1-release/ubuntu2204/swift-6.1-RELEASE/swift-6.1-RELEASE-ubuntu22.04.tar.gz \
 && tar xzf swift-6.1-RELEASE-ubuntu22.04.tar.gz \
 && echo 'export PATH="$HOME/swift/swift-6.1-RELEASE-ubuntu22.04/usr/bin:$PATH"' >> ~/.bashrc
export PATH="$HOME/swift/swift-6.1-RELEASE-ubuntu22.04/usr/bin:$PATH"
swift --version
```

Expected: `Swift version 6.1 (swift-6.1-RELEASE)`, target `x86_64-unknown-linux-gnu`.

- [ ] **Step 3: Verify OpenSSL headers and ffplay**

```bash
ls /usr/include/openssl/ssl.h && which ffplay
```

Expected: both paths print. (`ffplay` showing video from WSL needs WSLg; if it fails later in M2, copy the `.h264` to Windows and play it there with `ffplay`.)

---

### Task 2: Hello-world iOS app + CI

**Files:**
- Create: `LICENSE`, `.gitignore`, `README.md`
- Create: `App/project.yml`, `App/Sources/AppDelegate.swift`, `App/Sources/ViewController.swift`, `App/Sources/LaunchScreen.storyboard`
- Create: `.github/workflows/ios.yml`

**Interfaces:**
- Produces: CI artifact `AppleAuto-ipa` containing `AppleAuto.ipa`; app launch counter file `Documents/launches.txt` (used by Task 3's persistence check).

- [ ] **Step 1: Branch and repo hygiene**

```bash
cd /mnt/c/Users/efrai/Documents/Kerjaan/Projects/iPhoneAuto
git checkout -b m0-pipeline
curl -fL https://www.gnu.org/licenses/gpl-3.0.txt -o LICENSE
cat > .gitignore <<'EOF'
.build/
.swiftpm/
*.xcodeproj
*.ipa
build/
Payload/
# head-unit certificate/key must never be committed
*.pem
*.key
*.crt
certs/
EOF
```

- [ ] **Step 2: `App/project.yml`**

```yaml
name: AppleAuto
options:
  bundleIdPrefix: io.github.efraim14
  deploymentTarget:
    iOS: "12.0"
targets:
  AppleAuto:
    type: application
    platform: iOS
    sources: [Sources]
    info:
      path: Info.plist
      properties:
        CFBundleDisplayName: Apple Auto
        UILaunchStoryboardName: LaunchScreen
        UIRequiresFullScreen: true
        UISupportedInterfaceOrientations:
          - UIInterfaceOrientationLandscapeLeft
          - UIInterfaceOrientationLandscapeRight
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: io.github.efraim14.appleauto
        PRODUCT_NAME: AppleAuto
        SWIFT_VERSION: "5.0"
        TARGETED_DEVICE_FAMILY: "1"
```

- [ ] **Step 3: `App/Sources/AppDelegate.swift`**

```swift
import UIKit

@UIApplicationMain
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        application.isIdleTimerDisabled = true
        let w = UIWindow(frame: UIScreen.main.bounds)
        w.rootViewController = ViewController()
        w.makeKeyAndVisible()
        window = w
        return true
    }
}
```

- [ ] **Step 4: `App/Sources/ViewController.swift`**

The launch counter lives in `Documents/launches.txt`. Task 3 uses it to see whether a Sideloadly re-sign keeps app data.

```swift
import UIKit

final class ViewController: UIViewController {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("launches.txt")
        let previous = (try? String(contentsOf: url, encoding: .utf8)).flatMap { Int($0) } ?? 0
        let count = previous + 1
        try? String(count).write(to: url, atomically: true, encoding: .utf8)

        let label = UILabel(frame: view.bounds)
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .white
        label.font = .systemFont(ofSize: 28, weight: .medium)
        label.text = "Apple Auto\n\niOS \(UIDevice.current.systemVersion)\n"
            + "\(Int(view.bounds.width))×\(Int(view.bounds.height)) pt\n"
            + "launch #\(count)"
        view.addSubview(label)
    }
}
```

- [ ] **Step 5: `App/Sources/LaunchScreen.storyboard`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<document type="com.apple.InterfaceBuilder3.CocoaTouch.Storyboard.XIB" version="3.0" toolsVersion="14490.70" targetRuntime="iOS.CocoaTouch" propertyAccessControl="none" useAutolayout="YES" launchScreen="YES" useTraitCollections="YES" useSafeAreas="YES" colorMatched="YES" initialViewController="01J-lp-oVM">
    <scenes>
        <scene sceneID="EHf-IW-A2E">
            <objects>
                <viewController id="01J-lp-oVM" sceneMemberID="viewController">
                    <view key="view" contentMode="scaleToFill" id="Ze5-6b-2t3">
                        <rect key="frame" x="0.0" y="0.0" width="375" height="667"/>
                        <autoresizingMask key="autoresizingMask" widthSizable="YES" heightSizable="YES"/>
                        <color key="backgroundColor" red="0" green="0" blue="0" alpha="1" colorSpace="custom" customColorSpace="sRGB"/>
                    </view>
                </viewController>
                <placeholder placeholderIdentifier="IBFirstResponder" id="iYj-Kq-Ea1" userLabel="First Responder" sceneMemberID="firstResponder"/>
            </objects>
        </scene>
    </scenes>
</document>
```

- [ ] **Step 6: `.github/workflows/ios.yml`**

```yaml
name: ios
on:
  push:
    branches: [main]
  pull_request:
    paths: ['App/**', '.github/workflows/ios.yml']
  workflow_dispatch:
jobs:
  build:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - name: Select Xcode 16.4
        run: sudo xcode-select -s /Applications/Xcode_16.4.app
      - run: brew install xcodegen
      - name: Generate project
        run: cd App && xcodegen generate
      - name: Build unsigned
        run: |
          xcodebuild -project App/AppleAuto.xcodeproj -scheme AppleAuto \
            -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
            -derivedDataPath build \
            CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
      - name: Package ipa
        run: |
          mkdir Payload
          cp -R build/Build/Products/Release-iphoneos/AppleAuto.app Payload/
          zip -qr AppleAuto.ipa Payload
      - uses: actions/upload-artifact@v4
        with:
          name: AppleAuto-ipa
          path: AppleAuto.ipa
          retention-days: 7
```

- [ ] **Step 7: `README.md`** (short; extended in later milestones)

```markdown
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
```

- [ ] **Step 8: Commit, push, open PR, watch CI**

```bash
git add LICENSE .gitignore README.md App .github
git commit -m "feat(m0): hello-world UIKit app and unsigned ipa workflow

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
git push -u origin m0-pipeline
gh pr create --base main --title "M0: hello-world app + CI ipa" --body "Builds an unsigned iOS 12 ipa on macos-15 / Xcode 16.4.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
gh run watch --exit-status
```

Expected: the `ios` run goes green and the `AppleAuto-ipa` artifact exists (`gh run download -n AppleAuto-ipa -D "$TMPDIR/ipa"` to confirm).

If Xcode 16.4 rejects `iOS 12.0` or the build fails on the deployment target: that is the spec's key M0 risk. Stop and report the exact error. Do not silently raise the target.

---

### Task 3: Install on the iPhone 6 and check persistence (manual, user)

**Files:** Modify `docs/superpowers/specs/2026-10-05-apple-auto-design.md` (record results in §11 risks).

- [ ] **Step 1:** Download the artifact: `gh run download -n AppleAuto-ipa -D /mnt/c/Users/efrai/Downloads/AppleAuto-ipa`.
- [ ] **Step 2:** User installs Sideloadly, plugs in the iPhone, drags in `AppleAuto.ipa`, signs in with the free Apple ID, and starts the install. On the phone, they trust the developer profile and launch the app.
- [ ] **Step 3: Verify the checklist** (user reports each):
  - Fills the whole screen in landscape (not letterboxed): the label shows about `667×375 pt`.
  - Label shows `iOS 12.5.7` and `launch #1`.
  - Force-quit, relaunch: `launch #2`.
- [ ] **Step 4: Persistence check:** in Sideloadly, install the **same ipa again** over the existing app (this simulates the weekly re-sign). Launch. Expected `launch #3`. If it shows `launch #1`, re-signing wipes app data, so the certificate must go to the Keychain in M4. Record the result either way.
- [ ] **Step 5: Record and merge**

```bash
# add one line under "Sideloadly re-sign may wipe app data" in the spec: "M0 result (date): data kept / wiped"
git add docs && git commit -m "docs: record M0 install and persistence results

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>" && git push
```

Then ask the user to approve and merge the PR (`gh pr merge --squash` only after their yes).

---

# M1 — `aaprobe` handshake

### Task 4: Package skeleton, Framing, Linux CI

**Files:**
- Create: `Package.swift`, `Sources/COpenSSL/module.modulemap`, `Sources/COpenSSL/shim.h`
- Create: `Sources/AAProtocol/Framing.swift`, `Sources/aaprobe/main.swift` (stub), `Tests/AAProtocolTests/FramingTests.swift`
- Create: `.github/workflows/linux.yml`

**Interfaces:**
- Produces:
  - `public struct Message: Equatable { var channel: UInt8; var control: Bool; var encrypted: Bool; var payload: Data; init(channel:control:encrypted:payload:) }`
  - `public enum FramingError: Error, Equatable { case orphanFragment(UInt8), unexpectedStart(UInt8), oversize }`
  - `public enum Framing { static func encode(_ m: Message) -> Data }`
  - `public final class FrameParser { init(); func feed(_ d: Data) throws -> [Message] }`

Frame wire format (from aasdk; verified against the real phone in Task 8): `[channel][flags][size hi][size lo]` + (4-byte big-endian total length only when the frame is a first fragment of a multi-frame message) + payload. Flags: `0x01` first, `0x02` last, `0x04` control, `0x08` encrypted. Max 0x4000 payload bytes per frame.

- [ ] **Step 1: Branch and manifest**

```bash
git checkout main && git pull && git checkout -b m1-handshake
mkdir -p Sources/COpenSSL Sources/AAProtocol Sources/aaprobe Tests/AAProtocolTests
```

`Package.swift`:

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AppleAuto",
    platforms: [.iOS(.v12), .macOS(.v10_15)],
    products: [.library(name: "AAProtocol", targets: ["AAProtocol"])],
    targets: [
        .systemLibrary(name: "COpenSSL", pkgConfig: "openssl", providers: [.apt(["libssl-dev"])]),
        .target(name: "AAProtocol", dependencies: ["COpenSSL"]),
        .executableTarget(name: "aaprobe", dependencies: ["AAProtocol"]),
        .testTarget(name: "AAProtocolTests", dependencies: ["AAProtocol"]),
    ]
)
```

`Sources/COpenSSL/module.modulemap`:

```
module COpenSSL [system] {
    header "shim.h"
    link "ssl"
    link "crypto"
    export *
}
```

`Sources/COpenSSL/shim.h`:

```c
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/bio.h>
#include <openssl/pem.h>
```

`Sources/aaprobe/main.swift` (stub, replaced in Task 7):

```swift
print("aaprobe")
```

- [ ] **Step 2: Write the failing tests** — `Tests/AAProtocolTests/FramingTests.swift`

```swift
import XCTest
@testable import AAProtocol

final class FramingTests: XCTestCase {
    func msg(_ n: Int, ch: UInt8 = 0, control: Bool = false, encrypted: Bool = false) -> Message {
        Message(channel: ch, control: control, encrypted: encrypted,
                payload: Data((0..<n).map { UInt8($0 & 0xff) }))
    }

    func testGoldenBytes() {
        let m = Message(channel: 0, control: true, encrypted: false, payload: Data([0, 1, 0, 1, 0, 1]))
        XCTAssertEqual(Framing.encode(m), Data([0x00, 0x07, 0x00, 0x06, 0, 1, 0, 1, 0, 1]))
    }

    func testRoundTripSmall() throws {
        let m = msg(10, ch: 3, control: true, encrypted: true)
        XCTAssertEqual(try FrameParser().feed(Framing.encode(m)), [m])
    }

    func testRoundTripFragmented() throws {
        let m = msg(40_000, ch: 2, encrypted: true)
        let wire = Framing.encode(m)
        XCTAssertEqual(wire[1] & 0x03, 0x01)                 // first frame, not last
        XCTAssertEqual(Array(wire[4..<8]), [0, 0, 0x9c, 0x40]) // total length 40000
        XCTAssertEqual(try FrameParser().feed(wire), [m])
    }

    func testByteAtATime() throws {
        let m = msg(20_000, ch: 1)
        let p = FrameParser()
        var got = [Message]()
        for b in Framing.encode(m) { got += try p.feed(Data([b])) }
        XCTAssertEqual(got, [m])
    }

    func testTwoMessagesInOneFeed() throws {
        let a = msg(5, ch: 0, control: true), b = msg(30_000, ch: 1)
        XCTAssertEqual(try FrameParser().feed(Framing.encode(a) + Framing.encode(b)), [a, b])
    }

    func testEmptyPayload() throws {
        let m = msg(0, ch: 4)
        XCTAssertEqual(try FrameParser().feed(Framing.encode(m)), [m])
    }

    func testOrphanLastFragmentThrows() {
        // channel 5, flags = last only (0x02), size 1
        XCTAssertThrowsError(try FrameParser().feed(Data([5, 0x02, 0, 1, 0xaa]))) {
            XCTAssertEqual($0 as? FramingError, .orphanFragment(5))
        }
    }

    func testOversizeThrows() {
        XCTAssertThrowsError(try FrameParser().feed(Framing.encode(msg(5 * 1024 * 1024)))) {
            XCTAssertEqual($0 as? FramingError, .oversize)
        }
    }
}
```

- [ ] **Step 3: Run to verify failure**

```bash
export PATH="$HOME/swift/swift-6.1-RELEASE-ubuntu22.04/usr/bin:$PATH"
swift test --scratch-path "$HOME/.cache/apple-auto-build" 2>&1 | tail -15
```

Expected: compile error `cannot find 'Message' in scope`.

- [ ] **Step 4: Implement** — `Sources/AAProtocol/Framing.swift`

```swift
import Foundation

public struct Message: Equatable {
    public var channel: UInt8
    public var control: Bool
    public var encrypted: Bool
    public var payload: Data
    public init(channel: UInt8, control: Bool, encrypted: Bool, payload: Data) {
        self.channel = channel; self.control = control; self.encrypted = encrypted; self.payload = payload
    }
}

public enum FramingError: Error, Equatable {
    case orphanFragment(UInt8)
    case unexpectedStart(UInt8)
    case oversize
}

public enum Framing {
    static let maxChunk = 0x4000

    public static func encode(_ m: Message) -> Data {
        let base: UInt8 = (m.control ? 0x04 : 0) | (m.encrypted ? 0x08 : 0)
        let n = m.payload.count
        let starts = Array(stride(from: 0, to: max(n, 1), by: maxChunk))
        var out = Data()
        for (i, s) in starts.enumerated() {
            let chunk = m.payload.subdata(in: s..<min(s + maxChunk, n))
            var flags = base
            if i == 0 { flags |= 0x01 }
            if i == starts.count - 1 { flags |= 0x02 }
            out.append(contentsOf: [m.channel, flags, UInt8(chunk.count >> 8), UInt8(chunk.count & 0xff)])
            if i == 0 && starts.count > 1 {
                out.append(contentsOf: [UInt8(n >> 24), UInt8((n >> 16) & 0xff), UInt8((n >> 8) & 0xff), UInt8(n & 0xff)])
            }
            out.append(chunk)
        }
        return out
    }
}

public final class FrameParser {
    static let maxMessage = 4 * 1024 * 1024
    private var buf = [UInt8]()
    private var partial = [UInt8: Data]()

    public init() {}

    public func feed(_ d: Data) throws -> [Message] {
        buf.append(contentsOf: d)
        var out = [Message]()
        while buf.count >= 4 {
            let ch = buf[0], f = buf[1]
            let first = f & 0x01 != 0, last = f & 0x02 != 0
            let size = Int(buf[2]) << 8 | Int(buf[3])
            let hdr = (first && !last) ? 8 : 4
            guard buf.count >= hdr + size else { break }
            let body = Data(buf[hdr..<hdr + size])
            buf.removeFirst(hdr + size)

            func make(_ p: Data) -> Message {
                Message(channel: ch, control: f & 0x04 != 0, encrypted: f & 0x08 != 0, payload: p)
            }
            switch (first, last) {
            case (true, true):
                if partial[ch] != nil { throw FramingError.unexpectedStart(ch) }
                out.append(make(body))
            case (true, false):
                if partial[ch] != nil { throw FramingError.unexpectedStart(ch) }
                partial[ch] = body
            case (false, false):
                guard var p = partial[ch] else { throw FramingError.orphanFragment(ch) }
                p.append(body)
                if p.count > Self.maxMessage { throw FramingError.oversize }
                partial[ch] = p
            case (false, true):
                guard var p = partial.removeValue(forKey: ch) else { throw FramingError.orphanFragment(ch) }
                p.append(body)
                if p.count > Self.maxMessage { throw FramingError.oversize }
                out.append(make(p))
            }
        }
        return out
    }
}
```

- [ ] **Step 5: Run to verify pass**

```bash
swift test --scratch-path "$HOME/.cache/apple-auto-build" 2>&1 | tail -15
```

Expected: `Executed 8 tests, with 0 failures`. If `Package.swift` fails to resolve `COpenSSL`, run `pkg-config --modversion openssl` (needs `libssl-dev` from Task 1).

- [ ] **Step 6: `.github/workflows/linux.yml`**

```yaml
name: linux
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-22.04
    steps:
      - uses: actions/checkout@v4
      - uses: swift-actions/setup-swift@v2
        with:
          swift-version: "6.1"
      - run: sudo apt-get update && sudo apt-get install -y libssl-dev pkg-config
      - run: swift build
      - run: swift test
```

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources Tests .github/workflows/linux.yml
git commit -m "feat(m1): package skeleton, AA framing, linux CI

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Cryptor (OpenSSL over memory BIOs)

**Files:**
- Create: `Sources/AAProtocol/Cryptor.swift`, `Tests/AAProtocolTests/TestCert.swift`, `Tests/AAProtocolTests/CryptorTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `public enum CryptorError: Error, Equatable { case badCredentials(String), handshake(String), io(String) }`
  - `public final class Cryptor { init(pem: Data, isServer: Bool = false) throws; func handshakeStep(_ incoming: Data?) throws -> Data; var isHandshakeComplete: Bool { get }; func encrypt(_ plain: Data) throws -> Data; func decrypt(_ cipher: Data) throws -> Data }`
  - Test helper `TestCert.makePEM() throws -> Data` (cert + key, shells out to `openssl`) and `TestCert.makeMismatchedPEM() throws -> Data` (cert from one key, key from another).

`pem` holds both the certificate and the private key, in any order.

- [ ] **Step 1: Test helper** — `Tests/AAProtocolTests/TestCert.swift`

```swift
import Foundation

enum TestCert {
    private static func run(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        if p.terminationStatus != 0 { throw NSError(domain: "openssl", code: Int(p.terminationStatus)) }
    }

    /// Returns (certPEM, keyPEM) for a fresh throwaway self-signed cert.
    static func make() throws -> (cert: Data, key: Data) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = dir.appendingPathComponent("c.pem").path, k = dir.appendingPathComponent("k.pem").path
        try run(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=test", "-days", "1",
                 "-keyout", k, "-out", c])
        return (try Data(contentsOf: URL(fileURLWithPath: c)), try Data(contentsOf: URL(fileURLWithPath: k)))
    }

    static func makePEM() throws -> Data { let t = try make(); return t.cert + t.key }
    static func makeMismatchedPEM() throws -> Data { try make().cert + make().key }
}
```

- [ ] **Step 2: Failing tests** — `Tests/AAProtocolTests/CryptorTests.swift`

```swift
import XCTest
@testable import AAProtocol

final class CryptorTests: XCTestCase {
    /// Runs the TLS handshake between a client and server Cryptor in memory.
    func handshaken() throws -> (client: Cryptor, server: Cryptor) {
        let pem = try TestCert.makePEM()
        let client = try Cryptor(pem: pem), server = try Cryptor(pem: pem, isServer: true)
        var toServer: Data? = try client.handshakeStep(nil)
        for _ in 0..<10 where !(client.isHandshakeComplete && server.isHandshakeComplete) {
            let toClient = try server.handshakeStep(toServer)
            toServer = try client.handshakeStep(toClient)
            if let d = toServer, d.isEmpty { toServer = nil }
        }
        XCTAssertTrue(client.isHandshakeComplete && server.isHandshakeComplete)
        return (client, server)
    }

    func testHandshakeAndRoundTrip() throws {
        let (c, s) = try handshaken()
        let wire = try c.encrypt(Data("hello phone".utf8))
        XCTAssertNotEqual(wire, Data("hello phone".utf8))
        XCTAssertEqual(try s.decrypt(wire), Data("hello phone".utf8))
        XCTAssertEqual(try c.decrypt(try s.encrypt(Data("hi".utf8))), Data("hi".utf8))
    }

    func testLargePayloadRoundTrip() throws {
        let (c, s) = try handshaken()
        let big = Data((0..<100_000).map { UInt8($0 & 0xff) })
        XCTAssertEqual(try s.decrypt(try c.encrypt(big)), big)
    }

    func testGarbagePEMThrows() {
        XCTAssertThrowsError(try Cryptor(pem: Data("not a pem".utf8))) {
            guard case CryptorError.badCredentials = $0 else { return XCTFail("\($0)") }
        }
    }

    func testKeyMismatchThrows() throws {
        let pem = try TestCert.makeMismatchedPEM()
        XCTAssertThrowsError(try Cryptor(pem: pem)) {
            guard case CryptorError.badCredentials = $0 else { return XCTFail("\($0)") }
        }
    }

    func testGarbageHandshakeInputThrows() throws {
        let c = try Cryptor(pem: try TestCert.makePEM())
        _ = try c.handshakeStep(nil)
        XCTAssertThrowsError(try c.handshakeStep(Data(repeating: 0x41, count: 64)))
    }
}
```

- [ ] **Step 3: Run to verify failure**

```bash
swift test --scratch-path "$HOME/.cache/apple-auto-build" --filter CryptorTests 2>&1 | tail -10
```

Expected: `cannot find 'Cryptor' in scope`.

- [ ] **Step 4: Implement** — `Sources/AAProtocol/Cryptor.swift`

```swift
import Foundation
import COpenSSL

public enum CryptorError: Error, Equatable {
    case badCredentials(String)
    case handshake(String)
    case io(String)
}

private func opensslError() -> String {
    var parts = [String]()
    while true {
        let e = ERR_get_error()
        if e == 0 { break }
        var buf = [CChar](repeating: 0, count: 256)
        ERR_error_string_n(e, &buf, buf.count)
        parts.append(String(cString: buf))
    }
    return parts.isEmpty ? "unknown OpenSSL error" : parts.joined(separator: "; ")
}

/// TLS over memory BIOs. Ciphertext is moved by the caller; nothing here touches a socket.
public final class Cryptor {
    private let ctx: OpaquePointer
    private let ssl: OpaquePointer
    private let rbio: OpaquePointer   // we write incoming ciphertext here
    private let wbio: OpaquePointer   // we read outgoing ciphertext from here

    public init(pem: Data, isServer: Bool = false) throws {
        guard let c = SSL_CTX_new(isServer ? TLS_server_method() : TLS_client_method()) else {
            throw CryptorError.badCredentials(opensslError())
        }
        ctx = c
        do {
            try Cryptor.load(pem: pem, into: c)
        } catch {
            SSL_CTX_free(c); throw error
        }
        guard let s = SSL_new(c), let r = BIO_new(BIO_s_mem()), let w = BIO_new(BIO_s_mem()) else {
            SSL_CTX_free(c); throw CryptorError.io(opensslError())
        }
        ssl = s; rbio = r; wbio = w
        SSL_set_bio(s, r, w)            // SSL now owns both BIOs
        if isServer { SSL_set_accept_state(s) } else { SSL_set_connect_state(s) }
    }

    deinit { SSL_free(ssl); SSL_CTX_free(ctx) }

    private static func bio(_ pem: Data) throws -> OpaquePointer {
        guard let b = BIO_new(BIO_s_mem()) else { throw CryptorError.badCredentials(opensslError()) }
        let n = pem.withUnsafeBytes { BIO_write(b, $0.baseAddress, Int32($0.count)) }
        guard n == Int32(pem.count) else { BIO_free(b); throw CryptorError.badCredentials("PEM copy failed") }
        return b
    }

    private static func load(pem: Data, into ctx: OpaquePointer) throws {
        // Separate BIOs so the cert and key may appear in either order.
        let cb = try bio(pem), kb = try bio(pem)
        defer { BIO_free(cb); BIO_free(kb) }
        guard let cert = PEM_read_bio_X509(cb, nil, nil, nil) else {
            throw CryptorError.badCredentials("no certificate in PEM: " + opensslError())
        }
        defer { X509_free(cert) }
        guard let key = PEM_read_bio_PrivateKey(kb, nil, nil, nil) else {
            throw CryptorError.badCredentials("no private key in PEM: " + opensslError())
        }
        defer { EVP_PKEY_free(key) }
        guard SSL_CTX_use_certificate(ctx, cert) == 1, SSL_CTX_use_PrivateKey(ctx, key) == 1,
              SSL_CTX_check_private_key(ctx) == 1 else {
            throw CryptorError.badCredentials("certificate/key rejected: " + opensslError())
        }
    }

    private func feed(_ d: Data) throws {
        let n = d.withUnsafeBytes { BIO_write(rbio, $0.baseAddress, Int32($0.count)) }
        guard n == Int32(d.count) else { throw CryptorError.io("BIO_write short") }
    }

    private func drain() -> Data {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 16384)
        while BIO_ctrl_pending(wbio) > 0 {
            let n = BIO_read(wbio, &buf, Int32(buf.count))
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<Int(n)])
        }
        return out
    }

    public var isHandshakeComplete: Bool { SSL_is_init_finished(ssl) == 1 }

    /// Feed the peer's handshake bytes (nil to start); returns bytes to send to the peer (may be empty).
    public func handshakeStep(_ incoming: Data?) throws -> Data {
        if let d = incoming, !d.isEmpty { try feed(d) }
        let r = SSL_do_handshake(ssl)
        if r <= 0 {
            let e = SSL_get_error(ssl, r)
            if e != SSL_ERROR_WANT_READ && e != SSL_ERROR_WANT_WRITE {
                throw CryptorError.handshake(opensslError())
            }
        }
        return drain()
    }

    public func encrypt(_ plain: Data) throws -> Data {
        let n = plain.withUnsafeBytes { SSL_write(ssl, $0.baseAddress, Int32($0.count)) }
        guard n == Int32(plain.count) else { throw CryptorError.io("SSL_write: " + opensslError()) }
        return drain()
    }

    public func decrypt(_ cipher: Data) throws -> Data {
        try feed(cipher)
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = SSL_read(ssl, &buf, Int32(buf.count))
            if n > 0 { out.append(contentsOf: buf[0..<Int(n)]); continue }
            let e = SSL_get_error(ssl, n)
            if e == SSL_ERROR_WANT_READ || e == SSL_ERROR_ZERO_RETURN { break }
            throw CryptorError.io("SSL_read: " + opensslError())
        }
        return out
    }
}
```

If Swift cannot import an OpenSSL symbol (e.g. a macro such as `SSL_ERROR_WANT_READ`), replace it with its literal value (`2`, `3`, `6`) and add a comment. Do not change the API.

- [ ] **Step 5: Run to verify pass**

```bash
swift test --scratch-path "$HOME/.cache/apple-auto-build" 2>&1 | tail -10
```

Expected: `Executed 13 tests, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add Sources Tests
git commit -m "feat(m1): OpenSSL memory-BIO Cryptor with tests

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Session state machine + fake phone

**Files:**
- Create: `Sources/AAProtocol/Session.swift`, `Tests/AAProtocolTests/FakePhone.swift`, `Tests/AAProtocolTests/SessionTests.swift`

**Interfaces:**
- Consumes: `Framing.encode`, `FrameParser.feed`, `Message`, `Cryptor` (Tasks 4–5).
- Produces:
  - `public enum SessionError: Error, Equatable { case versionMismatch(UInt16), unexpected(id: UInt16, state: Session.State), malformed }`
  - `public final class Session { enum State: Equatable { versionSent, handshaking, authSent, discoveryRequested }; init(pem: Data, send: @escaping (Data) -> Void) throws; var log: (String) -> Void; private(set) var state: State; func start(); func receive(_ bytes: Data) throws }`

Control message ids (channel 0): `1` version request, `2` version response, `3` SSL handshake, `4` auth complete, `5` service discovery request. Payload = 2-byte big-endian id + body. Version request body = `00 01 00 01` (major 1, minor 1). Version response body = major(2) minor(2) status(2), and status `0` means OK. Auth-complete body = protobuf `08 00` (status OK). Handshake messages are plain; everything after the handshake is encrypted.

Success for M1 is `state == .discoveryRequested`: the Oppo accepted our certificate and sent an encrypted discovery request that we decrypted.

- [ ] **Step 1: Fake phone** — `Tests/AAProtocolTests/FakePhone.swift`

```swift
import Foundation
@testable import AAProtocol

/// Scripted stand-in for the Android phone (server side of the AA handshake).
final class FakePhone {
    let parser = FrameParser()
    let cryptor: Cryptor
    var versionStatus: UInt16 = 0
    var sawAuthComplete = false

    init(pem: Data) throws { cryptor = try Cryptor(pem: pem, isServer: true) }

    private func control(_ id: UInt16, _ body: Data, encrypted: Bool) throws -> Data {
        var payload = Data([UInt8(id >> 8), UInt8(id & 0xff)]) + body
        if encrypted { payload = try cryptor.encrypt(payload) }
        return Framing.encode(Message(channel: 0, control: true, encrypted: encrypted, payload: payload))
    }

    /// Bytes from the head unit in, bytes for the head unit out.
    func respond(to bytes: Data) throws -> Data {
        var out = Data()
        for m in try parser.feed(bytes) {
            if m.encrypted {
                let plain = try cryptor.decrypt(m.payload)
                if plain.prefix(2) == Data([0, 4]) {
                    sawAuthComplete = true
                    out += try control(5, Data(), encrypted: true)      // service discovery request
                }
                continue
            }
            switch (UInt16(m.payload[0]) << 8) | UInt16(m.payload[1]) {
            case 1:
                out += try control(2, Data([0, 1, 0, 1, UInt8(versionStatus >> 8), UInt8(versionStatus & 0xff)]), encrypted: false)
            case 3:
                let reply = try cryptor.handshakeStep(m.payload.dropFirst(2))
                if !reply.isEmpty { out += try control(3, reply, encrypted: false) }
            default: break
            }
        }
        return out
    }
}
```

- [ ] **Step 2: Failing tests** — `Tests/AAProtocolTests/SessionTests.swift`

```swift
import XCTest
@testable import AAProtocol

final class SessionTests: XCTestCase {
    /// Wires a Session to a FakePhone synchronously and pumps until quiet.
    func pump(_ session: Session, _ phone: FakePhone, _ box: Box) throws {
        var i = 0
        while i < box.sent.count {          // session.send appends to box.sent while we iterate
            let reply = try phone.respond(to: box.sent[i]); i += 1
            if !reply.isEmpty { try session.receive(reply) }
        }
    }

    func make(status: UInt16 = 0) throws -> (Session, FakePhone, Box) {
        let pem = try TestCert.makePEM()
        let phone = try FakePhone(pem: pem)
        phone.versionStatus = status
        let box = Box()
        let s = try Session(pem: pem, send: { box.sent.append($0) })
        return (s, phone, box)
    }
    final class Box { var sent = [Data]() }

    func testHappyPathReachesDiscoveryRequest() throws {
        let (s, phone, box) = try make()
        s.start()
        try pump(s, phone, box)
        XCTAssertEqual(s.state, .discoveryRequested)
        XCTAssertTrue(phone.sawAuthComplete)
    }

    func testVersionMismatchThrows() throws {
        let (s, phone, box) = try make(status: 1)
        s.start()
        XCTAssertThrowsError(try pump(s, phone, box)) {
            XCTAssertEqual($0 as? SessionError, .versionMismatch(1))
        }
    }

    func testUnexpectedMessageThrows() throws {
        let (s, _, _) = try make()
        s.start()
        // phone sends a plain service-discovery request before the version exchange finished
        let bad = Framing.encode(Message(channel: 0, control: true, encrypted: false, payload: Data([0, 5])))
        XCTAssertThrowsError(try s.receive(bad)) {
            XCTAssertEqual($0 as? SessionError, .unexpected(id: 5, state: .versionSent))
        }
    }

    func testUnknownMessageIsIgnored() throws {
        let (s, _, _) = try make()
        s.start()
        let unknown = Framing.encode(Message(channel: 0, control: true, encrypted: false, payload: Data([0x7f, 0x7f])))
        XCTAssertNoThrow(try s.receive(unknown))
        XCTAssertEqual(s.state, .versionSent)
    }

    func testTruncatedControlPayloadThrows() throws {
        let (s, _, _) = try make()
        s.start()
        let bad = Framing.encode(Message(channel: 0, control: true, encrypted: false, payload: Data([0])))
        XCTAssertThrowsError(try s.receive(bad)) { XCTAssertEqual($0 as? SessionError, .malformed) }
    }
}
```

- [ ] **Step 3: Run to verify failure**

```bash
swift test --scratch-path "$HOME/.cache/apple-auto-build" --filter SessionTests 2>&1 | tail -10
```

Expected: `cannot find 'Session' in scope`.

- [ ] **Step 4: Implement** — `Sources/AAProtocol/Session.swift`

```swift
import Foundation

public enum SessionError: Error, Equatable {
    case versionMismatch(UInt16)
    case unexpected(id: UInt16, state: Session.State)
    case malformed
}

/// M1 session: version → TLS handshake → auth complete → service discovery request received.
/// Not thread-safe: call from one queue. Any thrown error means: tear the session down.
public final class Session {
    public enum State: Equatable { case versionSent, handshaking, authSent, discoveryRequested }

    private enum ID {
        static let versionRequest: UInt16 = 1, versionResponse: UInt16 = 2, sslHandshake: UInt16 = 3
        static let authComplete: UInt16 = 4, serviceDiscoveryRequest: UInt16 = 5
    }

    public private(set) var state: State = .versionSent
    public var log: (String) -> Void = { _ in }

    private let parser = FrameParser()
    private let cryptor: Cryptor
    private let send: (Data) -> Void

    public init(pem: Data, send: @escaping (Data) -> Void) throws {
        cryptor = try Cryptor(pem: pem)
        self.send = send
    }

    public func start() {
        log("-> version request")
        let p = Data([0, UInt8(ID.versionRequest), 0, 1, 0, 1])
        send(Framing.encode(Message(channel: 0, control: true, encrypted: false, payload: p)))
    }

    public func receive(_ bytes: Data) throws {
        for m in try parser.feed(bytes) where m.channel == 0 {
            let plain = m.encrypted ? try cryptor.decrypt(m.payload) : m.payload
            guard plain.count >= 2 else { throw SessionError.malformed }
            try handle(id: UInt16(plain[0]) << 8 | UInt16(plain[1]), body: Data(plain.dropFirst(2)))
        }
    }

    private func handle(id: UInt16, body: Data) throws {
        switch (state, id) {
        case (.versionSent, ID.versionResponse):
            guard body.count >= 6 else { throw SessionError.malformed }
            let status = UInt16(body[4]) << 8 | UInt16(body[5])
            log("<- version response, status \(status)")
            guard status == 0 else { throw SessionError.versionMismatch(status) }
            state = .handshaking
            try handshake(nil)
        case (.handshaking, ID.sslHandshake):
            try handshake(body)
        case (.authSent, ID.serviceDiscoveryRequest):
            log("<- service discovery request (decrypted): certificate accepted")
            state = .discoveryRequested
        default:
            if (1...5).contains(id) { throw SessionError.unexpected(id: id, state: state) }
            log("<- ignoring message id \(id)")
        }
    }

    private func handshake(_ incoming: Data?) throws {
        let out = try cryptor.handshakeStep(incoming)
        if !out.isEmpty { send(try frame(ID.sslHandshake, out)) }
        if cryptor.isHandshakeComplete {
            log("TLS handshake complete; -> auth complete")
            send(try frame(ID.authComplete, Data([0x08, 0x00]), cryptor: cryptor))
            state = .authSent
        }
    }

    /// Control-channel frame: 2-byte id + body, encrypted when a cryptor is given.
    private func frame(_ id: UInt16, _ body: Data, cryptor: Cryptor? = nil) throws -> Data {
        var payload = Data([UInt8(id >> 8), UInt8(id & 0xff)]) + body
        if let c = cryptor { payload = try c.encrypt(payload) }
        return Framing.encode(Message(channel: 0, control: true, encrypted: cryptor != nil, payload: payload))
    }
}
```

- [ ] **Step 5: Run to verify pass**

```bash
swift test --scratch-path "$HOME/.cache/apple-auto-build" 2>&1 | tail -10
```

Expected: `Executed 18 tests, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add Sources Tests
git commit -m "feat(m1): handshake Session state machine with fake-phone tests

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 7: TCPSocket + `aaprobe connect`

**Files:**
- Create: `Sources/AAProtocol/TCPSocket.swift`, `Tests/AAProtocolTests/TCPSocketTests.swift`
- Modify: `Sources/aaprobe/main.swift`

**Interfaces:**
- Consumes: `Session` (Task 6).
- Produces:
  - `public enum SocketError: Error { case connect(String), io(String), timeout }`
  - `public final class TCPSocket { init(host: String, port: UInt16, timeout: TimeInterval) throws; func read(timeout: TimeInterval) throws -> Data?; func write(_ d: Data) throws; func close() }`. `read` returns `nil` when the peer closed, and throws `.timeout` when nothing arrived in time.

- [ ] **Step 1: Failing tests** — `Tests/AAProtocolTests/TCPSocketTests.swift`

The test server is a plain POSIX listener on `127.0.0.1` with an ephemeral port.

```swift
import XCTest
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
@testable import AAProtocol

final class TCPSocketTests: XCTestCase {
    /// Listener on 127.0.0.1:ephemeral; returns (listenFd, port).
    func listener() -> (Int32, UInt16) {
        #if canImport(Glibc)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        listen(fd, 1)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        return (fd, UInt16(bigEndian: addr.sin_port))
    }

    func testEchoAndClose() throws {
        let (lfd, port) = listener()
        defer { Glibc_close(lfd) }
        let s = try TCPSocket(host: "127.0.0.1", port: port, timeout: 2)
        let peer = accept(lfd, nil, nil)
        try s.write(Data("ping".utf8))
        var buf = [UInt8](repeating: 0, count: 8)
        XCTAssertEqual(recv(peer, &buf, 8, 0), 4)
        _ = send(peer, "pong", 4, 0)
        XCTAssertEqual(try s.read(timeout: 2), Data("pong".utf8))
        Glibc_close(peer)
        XCTAssertNil(try s.read(timeout: 2))   // peer closed
    }

    func testReadTimesOut() throws {
        let (lfd, port) = listener()
        defer { Glibc_close(lfd) }
        let s = try TCPSocket(host: "127.0.0.1", port: port, timeout: 2)
        _ = accept(lfd, nil, nil)
        XCTAssertThrowsError(try s.read(timeout: 0.2)) {
            guard case SocketError.timeout = $0 else { return XCTFail("\($0)") }
        }
    }

    func testConnectRefusedThrows() {
        let (lfd, port) = listener()
        Glibc_close(lfd)                        // nothing listening any more
        XCTAssertThrowsError(try TCPSocket(host: "127.0.0.1", port: port, timeout: 1))
    }

    func testBadHostThrows() {
        XCTAssertThrowsError(try TCPSocket(host: "not-an-ip", port: 5277, timeout: 1))
    }
}

private func Glibc_close(_ fd: Int32) { _ = close(fd) }
```

- [ ] **Step 2: Run to verify failure**

```bash
swift test --scratch-path "$HOME/.cache/apple-auto-build" --filter TCPSocketTests 2>&1 | tail -10
```

Expected: `cannot find 'TCPSocket' in scope`.

- [ ] **Step 3: Implement** — `Sources/AAProtocol/TCPSocket.swift`

```swift
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

public enum SocketError: Error {
    case connect(String)
    case io(String)
    case timeout
}

/// Blocking IPv4 TCP socket with timeouts. Host must be an IPv4 literal (the hotspot gateway).
public final class TCPSocket {
    private var fd: Int32

    public init(host: String, port: UInt16, timeout: TimeInterval) throws {
        #if canImport(Glibc)
        fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw SocketError.connect("socket(): \(String(cString: strerror(errno)))") }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
            sysClose(fd); throw SocketError.connect("not an IPv4 address: \(host)")
        }
        TCPSocket.setTimeout(fd, SO_SNDTIMEO, timeout)   // bounds connect()
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sysConnect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard r == 0 else {
            let msg = String(cString: strerror(errno))
            sysClose(fd); throw SocketError.connect("\(host):\(port): \(msg)")
        }
    }

    deinit { close() }

    private static func setTimeout(_ fd: Int32, _ opt: Int32, _ t: TimeInterval) {
        var tv = timeval(tv_sec: Int(t), tv_usec: Int32((t - Double(Int(t))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, opt, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// nil = peer closed. Throws `.timeout` if nothing arrives in time.
    public func read(timeout: TimeInterval) throws -> Data? {
        TCPSocket.setTimeout(fd, SO_RCVTIMEO, timeout)
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = recv(fd, &buf, buf.count, 0)
        if n > 0 { return Data(buf[0..<n]) }
        if n == 0 { return nil }
        if errno == EAGAIN || errno == EWOULDBLOCK { throw SocketError.timeout }
        throw SocketError.io(String(cString: strerror(errno)))
    }

    public func write(_ d: Data) throws {
        guard !d.isEmpty else { return }
        var sent = 0
        try d.withUnsafeBytes { p in
            while sent < d.count {
                let n = send(fd, p.baseAddress! + sent, d.count - sent, Int32(MSG_NOSIGNAL_FLAG))
                if n <= 0 { throw SocketError.io(String(cString: strerror(errno))) }
                sent += n
            }
        }
    }

    public func close() {
        if fd >= 0 { sysClose(fd); fd = -1 }
    }
}

// File-scope wrappers: inside the class, `close`/`connect` would resolve to the members.
private func sysClose(_ fd: Int32) { _ = close(fd) }
private func sysConnect(_ fd: Int32, _ a: UnsafePointer<sockaddr>, _ l: socklen_t) -> Int32 { connect(fd, a, l) }

#if canImport(Glibc)
private let MSG_NOSIGNAL_FLAG = MSG_NOSIGNAL
#else
private let MSG_NOSIGNAL_FLAG = 0   // Darwin: SIGPIPE is disabled per-socket in the iOS app (M3)
#endif
```

- [ ] **Step 4: Run to verify pass**

```bash
swift test --scratch-path "$HOME/.cache/apple-auto-build" 2>&1 | tail -10
```

Expected: `Executed 22 tests, with 0 failures`.

- [ ] **Step 5: `aaprobe connect`** — replace `Sources/aaprobe/main.swift`

```swift
import Foundation
import AAProtocol

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

let args = CommandLine.arguments
func opt(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

guard args.count > 1, args[1] == "connect", let host = opt("--host"), let certPath = opt("--cert") else {
    fail("usage: aaprobe connect --host <ipv4> --cert <headunit.pem> [--port 5277]")
}
let port = UInt16(opt("--port") ?? "5277") ?? 5277

guard let pem = FileManager.default.contents(atPath: certPath) else { fail("cannot read cert file: \(certPath)") }

do {
    var socket: TCPSocket!
    let session = try Session(pem: pem, send: { try? socket.write($0) })
    session.log = { print($0) }
    print("connecting to \(host):\(port)")
    socket = try TCPSocket(host: host, port: port, timeout: 5)
    session.start()
    while session.state != .discoveryRequested {
        guard let bytes = try socket.read(timeout: 10) else { fail("FAILED: phone closed the connection (state \(session.state))") }
        try session.receive(bytes)
    }
    print("OK: version + TLS + auth done; phone accepted the certificate")
} catch SocketError.timeout {
    fail("FAILED: no data from the phone for 10 s")
} catch {
    fail("FAILED: \(error)")
}
```

`try? socket.write` swallows write errors; the next `read` returns `nil` or throws, which already ends the run with a message. That is why it's acceptable here.

- [ ] **Step 6: Build and smoke-test the failure paths**

```bash
swift build --scratch-path "$HOME/.cache/apple-auto-build" 2>&1 | tail -3
BIN="$HOME/.cache/apple-auto-build/debug/aaprobe"
$BIN; echo "exit=$?"                                           # usage, exit 1
$BIN connect --host 127.0.0.1 --port 1 --cert /nope; echo "exit=$?"   # cannot read cert, exit 1
```

Expected: usage message with `exit=1`; then `cannot read cert file: /nope` with `exit=1`.

- [ ] **Step 7: Commit and open the PR**

```bash
git add Sources Tests
git commit -m "feat(m1): TCPSocket and aaprobe connect

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
git push -u origin m1-handshake
gh pr create --base main --title "M1: aaprobe handshake" --body "Framing, Cryptor, Session, TCPSocket, aaprobe. 22 unit tests. Real-device check is Task 8.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
gh run watch --exit-status
```

Expected: the `linux` workflow is green.

---

### Task 8: Real-device check (manual, user) — the stop-rule gate

**Files:** Modify `docs/superpowers/specs/2026-10-05-apple-auto-design.md` (record results in §11).

- [ ] **Step 1: Get the certificate (user, once).** Download `cert/headunit.crt` and `cert/headunit.key` from `https://github.com/opencardev/aasdk` and combine them into a file **outside the repo**, for example `~/headunit.pem` (`cat headunit.crt headunit.key > ~/headunit.pem`). Never commit it.
- [ ] **Step 2: Oppo setup (user).** Turn on the hotspot. Open Android Auto settings and tap the version number 10 times. Open the ⋮ menu → *Developer settings*, then ⋮ → *Start head unit server*. A notification should appear.
- [ ] **Step 3: Join the hotspot and find the gateway (user/agent).** Join the PC to the hotspot. Find the Oppo's IP: `ip route | grep default` in WSL, or `ipconfig` on Windows (the *Default Gateway*). Usually `192.168.x.1`. If WSL cannot reach the hotspot subnet, enable WSL mirrored networking (`networkingMode=mirrored` in `%UserProfile%\.wslconfig`, then `wsl --shutdown`).
- [ ] **Step 4: Run the probe**

```bash
"$HOME/.cache/apple-auto-build/debug/aaprobe" connect --host <oppo-ip> --cert ~/headunit.pem
```

Expected success: lines `-> version request`, `<- version response, status 0`, `TLS handshake complete; -> auth complete`, `<- service discovery request (decrypted): certificate accepted`, then `OK: …` and exit 0.

- [ ] **Step 5: If it fails, diagnose by where it stopped** (do not guess; use `superpowers:systematic-debugging`):
  - Connection refused/timeout: the head unit server isn't running, the IP is wrong, or the subnet is unreachable from WSL.
  - Closed after the version request: the frame format or the version bytes are wrong. Compare with `opencardev/aasdk` `Messenger` and `ControlServiceChannel`.
  - TLS handshake error: the certificate was rejected (TLS alert) or the TLS version or cipher is incompatible.
  - Handshake completes but no discovery request arrives: the auth-complete message or its ordering is wrong.
- [ ] **Step 6: Stop rule.** If the TLS handshake is rejected because of the certificate, try the other public head-unit certificates (the one Headunit Reloaded uses) before giving up. If all are rejected, stop and report to the user. The spec says to stop before any iOS UI work.
- [ ] **Step 7: Lock-screen survival check.** After one success, run `aaprobe` again immediately (does the server accept a second connection?). Then lock the Oppo, wait 10 minutes, and run it again. Record both results: server survives lock yes/no; accepts repeat connections yes/no.
- [ ] **Step 8: Record and finish**

```bash
# add results to spec §11 (cert accepted? head-unit-server survives lock? second connection ok?)
git add docs && git commit -m "docs: record M1 device-test results

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>" && git push
```

Ask the user to approve and merge the PR. Then plan M2 (service discovery, video channel, H.264 dump) as a separate plan.
