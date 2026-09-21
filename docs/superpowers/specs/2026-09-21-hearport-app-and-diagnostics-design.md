# HearPort iOS App and Diagnostics Design

## Goal

Turn the existing `HearPortReceiver` Swift package into a minimally usable iOS app named `HearPort`, produce an unsigned standard IPA artifact from GitHub Actions for local AltServer/AltStore sideloading, and provide detailed, exportable diagnostics for connection and audio troubleshooting.

## User intent and constraints

- The app name is `HearPort`.
- The first UI is intentionally small: Windows host/IP, authentication mode, PIN when required, connect action, connection status, and a diagnostics export action.
- GitHub Actions must build the iOS target and upload an IPA-like artifact.
- Apple signing certificates and provisioning profiles are not stored in GitHub Actions for this iteration.
- AltServer on the user's Windows machine is the local sideload/signing boundary.
- Existing Swift package tests remain part of CI.
- Diagnostic logs must be detailed enough to investigate pairing, QUIC state, control messages, stream transitions, datagram rejection, jitter/rebuffer behavior, audio route changes, and failures.
- Secrets and sensitive media are never written to the log: PINs, private keys, SPAKE2 scalars/points/confirmation values, remembered pair secrets, raw credentials, raw control payloads, and PCM/audio payloads are excluded or reduced to safe metadata.

## Architecture

### App target

Keep `ios/HearPortReceiver` as the reusable Swift Package library. Add a separate iOS application target under `ios/HearPortApp` with:

- an `@main` SwiftUI application entry point;
- the existing `HearPortReceiver.HearPortApp` view as the initial screen;
- a fixed iOS 16 deployment target;
- the existing local-network and background-audio metadata carried into the app target;
- a stable bundle identifier and version/build settings suitable for an unsigned archive.

Use a committed XcodeGen specification to generate the Xcode project on the macOS runner. This keeps the project definition reviewable without hand-maintaining a large generated `project.pbxproj`, while still giving `xcodebuild` a real application target and scheme.

### Diagnostics subsystem

Add a package-level `HearPortDiagnostics` component that is usable by the package and the app target without a third-party dependency.

The component has these responsibilities:

1. Emit structured entries to Apple's unified logging system with subsystem/category separation.
2. Append human-readable entries to an on-device log file under the app's Application Support directory.
3. Rotate the active log when it exceeds a bounded size and retain a small number of previous files.
4. Maintain a bounded in-memory tail for the UI and export path.
5. Serialize writes through one synchronization boundary so transport callbacks, audio callbacks, and UI actions cannot corrupt the file.
6. Export a ZIP or plain-text bundle containing the retained diagnostic logs and a safe environment summary.

Each log entry contains a timestamp, severity, category, message, and optional safe fields such as host redaction, stream ID, sequence number, byte count, state, disposition, duration, and error domain/code. Hostnames may be retained because they are needed for troubleshooting, but PINs, credentials, and key material are always redacted.

The minimum categories are:

- `app`: launch, lifecycle, UI action, export, and configuration changes;
- `transport`: QUIC setup, TLS verification policy, control stream, datagram flow, state changes, cancellation, and transport errors;
- `pairing`: authentication mode, phase changes, vector sizes, success/failure classification, and credential-store outcomes without secret values;
- `control`: message kind, encoded/decoded byte counts, frame boundaries, malformed-message reason, and stream IDs;
- `audio`: AVAudioSession activation, route/interruption notifications, output format, engine lifecycle, and stereo/sample-rate checks;
- `realtime`: datagram validation, pending/active/old stream disposition, jitter mode, concealment, rebuffer, fill level, and drift updates;
- `security`: safe validation outcomes and error categories only.

The default level is `info`. `debug` entries are enabled in the app's Diagnostics section and included in the exported bundle. There is no logging of raw audio or authentication material even in debug mode.

### UI

Keep the current connection form and add a compact Diagnostics section:

- current logging level/status;
- retained entry count and active log size;
- `Export diagnostics` action using the system share sheet;
- `Clear diagnostics` action with confirmation;
- a short note that secrets and raw audio are excluded.

The connection screen continues to show a user-readable status. Detailed failure context is written to diagnostics and the UI shows a concise error instead of exposing protocol internals.

## GitHub Actions packaging

Keep the existing Swift package test job and add a separate unsigned packaging job on `macos-14`:

1. Check out the repository.
2. Install or use XcodeGen.
3. Generate `HearPort.xcodeproj` from the committed app specification.
4. Run `xcodebuild archive` for `generic/platform=iOS` with code signing disabled.
5. Validate that the archive contains `HearPort.app`, `Info.plist`, the expected bundle identifier, and a valid `Payload/HearPort.app` layout.
6. Create `HearPort-unsigned.ipa` from the `Payload` directory.
7. Upload the IPA and archive metadata with `actions/upload-artifact`.

The job must not require Apple certificates, provisioning profiles, or Apple account secrets. The artifact is intended for local AltServer processing; it is not claimed to be a pre-signed device-installable IPA.

## Data flow

```text
SwiftUI App
    ├── connection form ──> ReceiverControlSession
    ├── status/errors ─────> HearPortDiagnostics
    └── export action ────> diagnostics files + environment summary

QUIC transport callbacks
    ├── state/control/datagram metadata ──> HearPortDiagnostics
    └── raw payloads/audio ───────────────> never logged

Audio session callbacks
    ├── route/interruption/engine metadata ─> HearPortDiagnostics
    └── PCM samples ───────────────────────> never logged
```

## Testing and acceptance criteria

### Package tests

- Existing `swift test` remains green.
- Add focused tests for diagnostic redaction, bounded retention/rotation, export contents, and safe environment summary.
- Tests use a temporary directory or injected file location; they do not write to a developer's real Application Support directory.

### iOS build

- GitHub Actions compiles the real iOS application target with `xcodebuild archive`.
- The build reaches iOS-only conditional code that `swift test` on macOS does not type-check.
- The produced archive has a standard application bundle and the uploaded IPA has exactly one `Payload/HearPort.app` root.

### Explicit non-goals

- No Apple signing secret management in CI in this iteration.
- No device UI automation or real iPad audio/network soak test in the packaging job.
- No raw packet, PCM, PIN, private-key, or credential logging.
- No new discovery service, settings subsystem, or advanced UI beyond the connection and diagnostics controls.

