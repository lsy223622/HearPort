# HearPort v1 validation matrix

This matrix deliberately separates deterministic/reference evidence from native
platform and real-network evidence. A green Python test proves only the
specified model or byte-level behavior; it does not prove WASAPI, MsQuic,
Network.framework, AVAudioSession, background execution, or Wi-Fi stability.

| ID | Requirement | Evidence type | Evidence | Status |
|---|---|---|---|---|
| protocol-control | Control framing and canonical ControlEnvelope field layout | automated | `python -m unittest tests.reference.test_wire_codec tests.reference.test_control_messages -v` | passed |
| protocol-audio | 968-byte AUDIO payload, big-endian header, non-zero stream id | automated | `python -m unittest tests.reference.test_wire_codec -v` | passed |
| session-gating | Pending stream, matching ACK, old stream and reset behavior | automated | `python -m unittest tests.reference.test_session_state -v` | passed |
| windows-capture | Shared-mode WASAPI Loopback and endpoint reset | native-build | VS 2022 MSVC/CMake/Ninja build and CTest 7/7 passed; isolated WASAPI endpoint runtime is still required; implementation is in `windows/src/wasapi_capture.cpp` | native build passed; runtime pending |
| windows-quic | MsQuic TLS/ALPN/DATAGRAM transport and 968-byte send capability | native-build | Windows sender compiled with `HEARPORT_HAS_MSQUIC=0`; MsQuic headers/libs and live transport runtime were not available; implementation is in `windows/src/quic_server_msquic.cpp` | sender build passed; MsQuic pending |
| ios-quic | Network.framework QUIC client, one control stream and one DATAGRAM flow | automated | GitHub Actions [run 35597785827](https://github.com/lsy223622/HearPort/actions/runs/35597785827) on `macos-14`: Swift package tests passed 18/18 and the iOS archive compiled the Network.framework path; implementation is in `ios/HearPortReceiver/Sources/HearPortReceiver/QuicReceiver.swift` | CI passed; iPad simulator/device and live Windows transport pending |
| ios-audio | AVAudioSession stereo playback, local silence and render callback | native-build | GitHub Actions [run 35597785827](https://github.com/lsy223622/HearPort/actions/runs/35597785827) archived the iOS target with Xcode 15.4/iOS 17.5 SDK and signing disabled; implementation is in `ios/HearPortReceiver/Sources/HearPortReceiver/AudioSessionController.swift` | compile passed; device route/interruption runtime pending |
| ios-app-archive | HearPort app target and standard unsigned IPA packaging | native-build | GitHub Actions [run 35597785827](https://github.com/lsy223622/HearPort/actions/runs/35597785827): XcodeGen generated the Xcode 15-compatible project, `xcodebuild archive` succeeded, bundle ID `com.lsy223622.HearPort` and `Payload/HearPort.app/Info.plist` were validated, and artifact `HearPort-unsigned-ipa` (ID `10637134436`, 143912 bytes) was uploaded | unsigned artifact passed; local AltStore signing/device install pending |
| security-pairing | PIN scalar, SPKI identity, SPAKE2 point/key/confirmation and failure handling | automated | Python vectors, Rust provider tests, and native `hearport_security_tests` under VS 2022 | passed for reference/provider/native C++ |
| security-remembered | One-shot nonce, HMAC, peer-id and SPKI pinning | automated | Python vectors plus native `hearport_security_tests` under VS 2022 | passed for reference/native C++ |
| diagnostics | Local sender/receiver event schema with no telemetry stream | automated | JSON Schemas under `diagnostics/schemas/`, Swift `HearPortDiagnostics` tests in GitHub Actions run 35597785827 (18/18 package tests), redacted export/environment-summary/rotation/clear coverage, and this matrix checker | passed for local redacted diagnostics; real-device log review pending |
| network-impairment | Jitter, reorder, burst loss and outage recovery | network-soak | No network impairment or Wi-Fi test harness is available; execute the scenarios in the real-device runbook before release | pending network run |
| clock-drift | Bounded slow correction for +/- ppm producer/consumer mismatch | automated | `python -m unittest tests.reference.test_realtime_core -v` | passed for reference |
| foreground-soak | Two-hour foreground active-playback stability | real-device | Requires a signed iPad and a Windows sender on 5/6 GHz Wi-Fi; no device result is claimed here | pending device run |
| silent-playback | Windows capture idle, local zero output, then rebuffer and resume | real-device | Requires foreground, lock-screen and background runs without a debugger; no device result is claimed here | pending device run |
| background-lock-screen | Audio session behavior after lock/background transition | real-device | Requires target iPadOS devices and an unsigned-debugger-free run; no platform-duration guarantee is claimed here | pending device run |
| route-interruption | Route change and audio interruption return to live rebuffer | real-device | Requires headphones/Bluetooth route changes and phone/interruption scenarios on a signed iPad | pending device run |
| capture-reset | WASAPI endpoint reset starts a new stream without replaying stale audio | real-device | Requires an isolated Windows endpoint reset plus a connected iPad; no end-to-end result is claimed here | pending device run |
