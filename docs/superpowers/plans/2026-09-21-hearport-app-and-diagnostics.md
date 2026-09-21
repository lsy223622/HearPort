# HearPort iOS App and Diagnostics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a minimal `HearPort` iOS application around the existing receiver package, add detailed exportable diagnostics, and produce an unsigned standard IPA artifact through GitHub Actions for local AltServer/AltStore sideloading.

**Architecture:** Keep protocol, transport, receiver state, and audio implementation in the existing `HearPortReceiver` Swift Package. Add a separate `ios/HearPortApp` XcodeGen-described application target that depends on the package and wraps the existing SwiftUI view. Add a synchronized package-level diagnostics store used by transport, control, receiver, audio, and UI boundaries; the app exports a redacted text bundle through the system share sheet.

**Tech Stack:** Swift 5.9, SwiftUI, Foundation, `os.Logger`, Network.framework, AVFAudio, XcodeGen, `xcodebuild`, GitHub Actions `macos-14`, Swift Package XCTest.

**Spec:** `docs/superpowers/specs/2026-09-21-hearport-app-and-diagnostics-design.md`

## Global Constraints

- The app name is `HearPort`.
- The iOS deployment target is iOS 16.0.
- The existing `HearPortReceiver` package remains reusable and its current tests remain green.
- GitHub Actions does not receive Apple certificates, provisioning profiles, Apple IDs, or private signing secrets.
- The unsigned artifact must contain exactly one `Payload/HearPort.app` root and be suitable for local AltServer processing.
- Logs must never contain PINs, private keys, SPAKE2 scalars/points/confirmation values, remembered pair secrets, raw credentials, raw control payloads, or PCM/audio data.
- Detailed logging uses safe metadata: timestamps, category, severity, state, stream ID, sequence, byte counts, durations, error domain/code, and redacted host information.
- No discovery service, advanced settings system, raw packet dump, raw audio dump, or device UI automation is added.

## Review Focus

- Secret leakage through diagnostic messages or exported files: the redaction test must prove PIN-like, key-like, credential-like, and payload-like fields are absent from exports.
- Concurrent transport/audio/UI logging corrupting the log file: the store must serialize append, rotation, export, and clear operations under one synchronization boundary.
- Unbounded logging during an audio stream: the active file, rotated files, and in-memory tail must remain bounded while retaining the newest entries.
- iOS-only conditional compilation hidden by macOS `swift test`: the GitHub Actions archive job must compile the real iOS application target with `xcodebuild`.
- Invalid IPA packaging: the archive validation step must fail unless the generated artifact contains the expected bundle identifier and exactly `Payload/HearPort.app`.

---

### Task 1: Add the diagnostics core with regression tests

**Files:**
- Create: `ios/HearPortReceiver/Sources/HearPortReceiver/Diagnostics.swift`
- Create: `ios/HearPortReceiver/Tests/HearPortReceiverTests/DiagnosticsTests.swift`

**Interfaces:**
- Produces `DiagnosticsLevel`, `DiagnosticsCategory`, `DiagnosticsSnapshot`, and `HearPortDiagnostics`.
- `HearPortDiagnostics` exposes `shared`, `level`, `log(_:category:message:fields:)`, `snapshot()`, `recentLines(limit:)`, `export()`, and `clear()`.
- The initializer accepts an injected directory, maximum active-file bytes, maximum rotated-file count, and clock so tests never write to the real Application Support directory.

- [ ] **Step 1: Write the failing diagnostic tests**

Add tests with these behaviors:

```swift
func testLogRedactsSensitiveFieldsAndKeepsSafeMetadata() throws {
    let diagnostics = try makeDiagnostics()
    diagnostics.log(.debug,
                    category: .pairing,
                    message: "pair attempt",
                    fields: [
                        "pin": "123456",
                        "spake_scalar": "scalar-value",
                        "bytes": "65",
                        "stream_id": "7"
                    ])

    let exported = try String(contentsOf: diagnostics.export(), encoding: .utf8)

    XCTAssertFalse(exported.contains("123456"))
    XCTAssertFalse(exported.contains("scalar-value"))
    XCTAssertTrue(exported.contains("bytes=65"))
    XCTAssertTrue(exported.contains("stream_id=7"))
}

func testRotationAndRecentTailStayBounded() throws {
    let diagnostics = try makeDiagnostics(maxFileBytes: 180, maxRotatedFiles: 2)
    for index in 0..<40 {
        diagnostics.log(.info, category: .realtime, message: "packet", fields: ["sequence": "\(index)"])
    }

    let snapshot = diagnostics.snapshot()
    XCTAssertLessThanOrEqual(snapshot.activeBytes, 180)
    XCTAssertLessThanOrEqual(snapshot.rotatedFileCount, 2)
    XCTAssertEqual(diagnostics.recentLines(limit: 1).count, 1)
}

func testClearRemovesRetainedDiagnostics() throws {
    let diagnostics = try makeDiagnostics()
    diagnostics.log(.error, category: .app, message: "failure")
    XCTAssertGreaterThan(diagnostics.snapshot().entryCount, 0)

    try diagnostics.clear()

    XCTAssertEqual(diagnostics.snapshot().entryCount, 0)
    XCTAssertEqual(diagnostics.snapshot().activeBytes, 0)
}
```

- [ ] **Step 2: Run the focused tests and verify the expected RED state**

Run:

```powershell
swift test --package-path ios/HearPortReceiver --filter DiagnosticsTests
```

Expected result before implementation: compilation fails because the diagnostics types and test helper do not exist.

- [ ] **Step 3: Implement the minimal diagnostics store**

Implement:

```swift
public enum DiagnosticsLevel: Int, CaseIterable, Comparable, Sendable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3
}

public enum DiagnosticsCategory: String, CaseIterable, Sendable {
    case app, transport, pairing, control, audio, realtime, security
}

public struct DiagnosticsSnapshot: Equatable, Sendable {
    public let entryCount: Int
    public let activeBytes: Int
    public let rotatedFileCount: Int
    public let level: DiagnosticsLevel
}

public final class HearPortDiagnostics: @unchecked Sendable {
    public static let shared = HearPortDiagnostics()

    public init(directory: URL? = nil,
                maxFileBytes: Int = 1_048_576,
                maxRotatedFiles: Int = 3,
                clock: @escaping () -> Date = Date.init)

    public var level: DiagnosticsLevel { get set }
    public func log(_ level: DiagnosticsLevel,
                    category: DiagnosticsCategory,
                    message: String,
                    fields: [String: String] = [:])
    public func snapshot() -> DiagnosticsSnapshot
    public func recentLines(limit: Int = 200) -> [String]
    public func export() throws -> URL
    public func clear() throws
}
```

The implementation uses `NSLock` for all state and file operations, writes one newline-delimited human-readable entry per call, emits the same redacted entry to `os.Logger`, rotates before exceeding the active limit, retains only the configured number of rotated files, and writes a plain-text export containing all retained files plus a safe summary. Keys matching `pin`, `password`, `secret`, `key`, `credential`, `scalar`, `point`, `mac`, `payload`, or `pcm` are replaced with `<redacted>`.

- [ ] **Step 4: Run the focused and complete package tests**

Run:

```powershell
swift test --package-path ios/HearPortReceiver --filter DiagnosticsTests
swift test --package-path ios/HearPortReceiver
```

Expected result: the new diagnostics tests and all existing package tests pass.

- [ ] **Step 5: Commit the diagnostics core**

```powershell
git add ios/HearPortReceiver/Sources/HearPortReceiver/Diagnostics.swift ios/HearPortReceiver/Tests/HearPortReceiverTests/DiagnosticsTests.swift
git commit -m "feat: add redacted exportable diagnostics"
```

### Task 2: Instrument receiver, transport, control, and audio boundaries

**Files:**
- Modify: `ios/HearPortReceiver/Sources/HearPortReceiver/QuicReceiver.swift`
- Modify: `ios/HearPortReceiver/Sources/HearPortReceiver/ReceiverControlSession.swift`
- Modify: `ios/HearPortReceiver/Sources/HearPortReceiver/AudioSessionController.swift`
- Modify: `ios/HearPortReceiver/Sources/HearPortReceiver/ControlMessages.swift`
- Modify: `ios/HearPortReceiver/Sources/HearPortReceiver/KeychainStore.swift` only where safe outcome context is needed
- Modify: `ios/HearPortReceiver/Tests/HearPortReceiverTests/ReceiverCoreTests.swift` only if an injected diagnostics assertion is needed

**Interfaces:**
- `HearPortReceiver` and `HearPortQuicTransport` accept an optional `HearPortDiagnostics` dependency defaulting to `.shared`.
- `ReceiverControlSession` accepts the same dependency and passes it only to log safe lifecycle metadata.
- Add an internal/public `ControlMessage.debugName` computed property for message names without payload contents.

- [ ] **Step 1: Add failing instrumentation assertions**

Add a receiver test that injects a temporary diagnostics store, performs connect/authenticated/pending-stream/ACK/audio-disposition transitions already covered by `ReceiverCoreTests`, and asserts the exported log contains category/state/stream metadata but not the PCM bytes. Add a transport/session test only where an existing fake transport boundary can be used without introducing mocks for production behavior.

- [ ] **Step 2: Run the focused test and verify it fails for missing instrumentation**

Run:

```powershell
swift test --package-path ios/HearPortReceiver --filter ReceiverCoreTests
```

Expected result: the behavioral assertions remain green, while the new log-presence assertion fails because no instrumentation has been added.

- [ ] **Step 3: Add safe structured log calls**

Log at `info` for lifecycle/state transitions and at `debug` for high-volume metadata:

- receiver initialization, authentication, stream begin/ACK, datagram length/stream/sequence/disposition, invalid datagram reason, jitter mode changes, rebuffer, render fill/underrun, and lifecycle events;
- transport connect host/port, pairing versus remembered TLS policy, control/datagram readiness, state changes, send/receive byte counts, cancellation, and error domain/code;
- control message debug name, encoded/decoded length, frame count, stream ID, pairing phase, credential-store success/failure classification, and error category;
- audio session activation/deactivation, route/interruption notifications, output channel count, sample rate, engine start/stop, and callback failure conditions.

Never pass PIN strings, `Data` payloads, key material, credentials, or PCM buffers to the logger. Use only byte counts, lengths, hashes already explicitly intended for diagnostics, and stream/sequence metadata.

- [ ] **Step 4: Run all package tests and inspect the exported test log**

Run:

```powershell
swift test --package-path ios/HearPortReceiver
```

Expected result: all tests pass and the injected log assertions confirm redaction and safe metadata.

- [ ] **Step 5: Commit instrumentation**

```powershell
git add ios/HearPortReceiver/Sources/HearPortReceiver ios/HearPortReceiver/Tests/HearPortReceiverTests
git commit -m "feat: instrument receiver diagnostics"
```

### Task 3: Extend the SwiftUI UI and add the iOS App target

**Files:**
- Modify: `ios/HearPortReceiver/Sources/HearPortReceiver/HearPortApp.swift`
- Create: `ios/HearPortApp/Sources/App.swift`
- Create: `ios/HearPortApp/Resources/Info.plist`
- Create: `ios/HearPortApp/Resources/HearPort.entitlements`
- Create: `ios/HearPortApp/project.yml`

**Interfaces:**
- The app target is named `HearPort` and depends on the local package product `HearPortReceiver`.
- `App.swift` defines `@main struct HearPortApp: App` and presents `HearPortReceiver.HearPortApp()`.
- The package view exposes the existing connection form plus diagnostics summary/export/clear controls.

- [ ] **Step 1: Add the iOS app entrypoint and target description**

Use this app entrypoint:

```swift
import SwiftUI
import HearPortReceiver

@main
struct HearPortApp: App {
    var body: some Scene {
        WindowGroup {
            HearPortReceiver.HearPortApp()
        }
    }
}
```

Use a XcodeGen spec with iOS 16, local package path `../HearPortReceiver`, bundle identifier `com.lsy223622.HearPort`, `MARKETING_VERSION=0.1.0`, `CURRENT_PROJECT_VERSION=1`, the app Info.plist, and the app entitlements file.

- [ ] **Step 2: Add the Diagnostics UI**

Add a `Form` section that shows current level, retained entries, active log size, an `Export diagnostics` button backed by `ShareLink`, a destructive `Clear diagnostics` action, and a privacy note. Refresh the summary on appearance and after connect/export/clear actions. Log UI actions without logging the PIN value.

- [ ] **Step 3: Generate the project on a macOS runner**

The local Windows host cannot run XcodeGen or Xcode, so do not commit generated derived data or an unverified hand-written `project.pbxproj`. The committed `project.yml` is the source of truth; the workflow generates `HearPort.xcodeproj` in CI.

- [ ] **Step 4: Run package tests and commit the app target**

Run the available local package tests. On Windows, record that the iOS target itself requires the macOS Actions job.

```powershell
python -m unittest discover -s tests -p "test_*.py" -v
```

Then commit:

```powershell
git add ios/HearPortReceiver/Sources/HearPortReceiver/HearPortApp.swift ios/HearPortApp
git commit -m "feat: add HearPort iOS app target"
```

### Task 4: Add unsigned IPA generation to GitHub Actions

**Files:**
- Modify: `.github/workflows/ios-receiver.yml`

**Interfaces:**
- Existing `swift-package` job continues to run `swift test`.
- New `ios-unsigned-ipa` job depends on `swift-package`, runs on `macos-14`, and uploads `HearPort-unsigned.ipa`.

- [ ] **Step 1: Extend workflow triggers and add the archive job**

Add `ios/HearPortApp/**` to push and pull-request paths. The archive job runs:

```yaml
- name: Install XcodeGen
  run: brew install xcodegen

- name: Generate Xcode project
  working-directory: ios/HearPortApp
  run: xcodegen generate

- name: Archive unsigned iOS app
  run: >-
    xcodebuild
    -project ios/HearPortApp/HearPort.xcodeproj
    -scheme HearPort
    -configuration Release
    -destination 'generic/platform=iOS'
    -archivePath "$RUNNER_TEMP/HearPort.xcarchive"
    -derivedDataPath "$RUNNER_TEMP/HearPortDerivedData"
    CODE_SIGNING_ALLOWED=NO
    CODE_SIGNING_REQUIRED=NO
    archive
```

- [ ] **Step 2: Validate and package the archive**

The shell step must fail if the application bundle or bundle identifier is missing, then create the standard IPA layout:

```bash
APP="$RUNNER_TEMP/HearPort.xcarchive/Products/Applications/HearPort.app"
test -d "$APP"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")" = "com.lsy223622.HearPort"
mkdir -p "$RUNNER_TEMP/Payload"
cp -R "$APP" "$RUNNER_TEMP/Payload/HearPort.app"
ditto -c -k --sequesterRsrc --keepParent "$RUNNER_TEMP/Payload" "$RUNNER_TEMP/HearPort-unsigned.ipa"
unzip -l "$RUNNER_TEMP/HearPort-unsigned.ipa" | grep -F "Payload/HearPort.app/Info.plist"
```

- [ ] **Step 3: Upload the IPA artifact**

Use `actions/upload-artifact@v4` with artifact name `HearPort-unsigned-ipa`, upload the IPA and a small archive metadata file, and set `if-no-files-found: error`.

- [ ] **Step 4: Commit and push the workflow**

```powershell
git add .github/workflows/ios-receiver.yml
git commit -m "ci: build unsigned HearPort IPA on macOS"
git push origin main
```

### Task 5: Iterate on the macOS build and record evidence

**Files:**
- Modify: any source or workflow file directly implicated by Actions output
- Modify: `docs/validation-matrix.md`
- Modify: `docs/superpowers/sdd/hearport-v1/progress.md`

- [ ] **Step 1: Trigger and watch the workflow**

Run:

```powershell
gh run list --workflow ios-receiver.yml --branch main --limit 3 --json databaseId,status,conclusion,url,headSha
gh run watch <run-id> --exit-status --interval 10
```

Do not claim IPA generation until both the package test job and archive job are successful.

- [ ] **Step 2: Inspect failed logs if needed**

Run:

```powershell
gh run view <run-id> --log-failed
```

Fix only the diagnosed source/project/workflow issue, commit it, push it, and rerun the workflow. Do not add signing secrets as a workaround.

- [ ] **Step 3: Verify the artifact metadata**

Use the Actions artifact download or job output to verify the file name, IPA ZIP layout, bundle identifier, and that no provisioning profile or signing identity was required.

- [ ] **Step 4: Run final local regressions**

Run:

```powershell
python -m unittest discover -s tests -p "test_*.py" -v
cargo fmt --manifest-path security/spake2-provider/Cargo.toml -- --check
cargo test --manifest-path security/spake2-provider/Cargo.toml --all-targets
cmd.exe /d /s /c '"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\Tools\VsDevCmd.bat" -arch=x64 -host_arch=x64 && "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe" --build out/build/vs2022-x64-native --parallel 4 && "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\ctest.exe" --test-dir out/build/vs2022-x64-native --output-on-failure'
```

- [ ] **Step 5: Record the final evidence and inspect the diff**

Update the matrix to distinguish Swift package tests, iOS archive build, unsigned artifact generation, and still-pending device/network runtime validation. Run `git diff --check`, inspect `git status --short`, and confirm the final remote `main` SHA before reporting completion.

