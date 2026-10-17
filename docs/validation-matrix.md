# HearPort 0.1.0 validation matrix

Automated tests and successful builds do not establish real-device playback,
background behavior, or long-session reliability. User-observed runs are listed
separately from repeatable test evidence; signed installation and soak results
are not inferred from an unsigned archive or short playback.

**User-observed manual runs:** playback on an iPad Pro 11-inch (2020) over USB,
including cable disconnect and reconnect; repeated playback/tests on weak
2.4 GHz Wi-Fi. These observations do not establish a timed soak, lock-screen
behavior, a clean-machine install, or quantified packet-loss recovery.

| ID | Requirement | Evidence type | Evidence | Status |
|---|---|---|---|---|
| protocol-control | Control framing and canonical ControlEnvelope field layout | automated | `python -m unittest tests.reference.test_wire_codec tests.reference.test_control_messages -v` | passed |
| protocol-audio | 968-byte AUDIO payload, big-endian header, non-zero stream id | automated | `python -m unittest tests.reference.test_wire_codec -v` | passed |
| session-gating | Pending stream, matching ACK, old stream and reset behavior | automated | `python -m unittest tests.reference.test_session_state -v` | passed |
| windows-capture | Shared-mode WASAPI Loopback and endpoint reset | native-build | Local VS 2022 x64 Release CTest record `out/build/windows-release/Testing/Temporary/LastTest.log` lists 22/22 passing tests; ordinary playback was observed on the user's iPad; endpoint-reset runtime remains unverified | 22 local tests passed; endpoint-reset check pending |
| windows-quic | MsQuic TLS/ALPN/DATAGRAM transport and 968-byte send capability | native-build | VS 2022 x64 MsQuic build/startup smoke initialized the configured certificate and bound UDP 52137; the latest local CTest record lists 22/22 passing tests; USB playback/reconnect was user-observed; LAN playback and complete diagnostics were also observed in repeated weak-Wi-Fi sessions | build/startup, local tests and user-observed LAN/USB sessions passed; clean Release install pending |
| ios-quic | Network.framework QUIC client, one control stream and one DATAGRAM flow | automated | GitHub Actions [run 39042423876](https://github.com/lsy223622/HearPort/actions/runs/39042423876) on macOS 14: all 156 Swift package tests passed; iPad-device and live Windows/LAN interoperability remain separate | Swift package tests passed; LAN/USB sessions user-observed; final package acceptance pending |
| ios-audio | AVAudioSession stereo playback, local silence and render callback | native-build | GitHub Actions [run 39042423876](https://github.com/lsy223622/HearPort/actions/runs/39042423876) archived the iOS app unsigned; Swift package tests passed; USB playback and cable reconnect were user-observed on an iPad Pro 11-inch (2020) | unsigned archive and short playback observed; route, interruption, and soak checks pending |
| ios-app-archive | HearPort app target and standard unsigned IPA packaging | native-build | GitHub Actions [run 39042423876](https://github.com/lsy223622/HearPort/actions/runs/39042423876) generated the Xcode project, archived the app with signing disabled, validated app metadata, and uploaded the unsigned IPA | CI artifact created; user signing and install from release bundle pending |
| security-pairing | PIN scalar, SPKI identity, SPAKE2 point/key/confirmation and failure handling | automated | Python vectors, Rust provider tests, and native `hearport_security_tests` under VS 2022; included in the latest 22-test local CTest record | automated checks passed |
| security-remembered | One-shot nonce, HMAC, peer-id and SPKI pinning | automated | Python vectors and native `hearport_security_tests` under VS 2022; included in the latest 22-test local CTest record | automated checks passed |
| diagnostics | Local sender/receiver event schema and export behavior | automated | JSON Schemas under `diagnostics/schemas/`, bounded asynchronous diagnostics, receiver and render metrics, and tests for export, redaction, rotation, and clearing | automated checks passed; review an exported report before sharing because it may contain network details such as a hostname, IP address, or port |
| network-impairment | Jitter, reorder, burst loss and outage recovery | real-device | Repeated weak 2.4 GHz Wi-Fi playback/tests were user-observed; paired offline replay and real-session reports exist; these are not a controlled validation of every impairment scenario | real Wi-Fi and paired offline evidence recorded; final Release soak pending |
| clock-drift | Bounded slow correction for +/- ppm producer/consumer mismatch | automated | `python -m unittest tests.reference.test_realtime_core -v` | passed for reference |
| foreground-soak | Two-hour foreground active-playback stability | real-device | Short playback and USB reconnect were user-observed on iPad Pro 11-inch (2020); no timed two-hour result is recorded | observed playback; two-hour soak pending |
| silent-playback | Windows capture idle, local zero output, then rebuffer and resume | real-device | Requires a foreground run that observes capture idle, silence, and recovery on a signed or otherwise launchable iPad | pending device run |
| background-lock-screen | Audio session behavior after lock/background transition | real-device | No signed-release lock-screen or background result is recorded | pending device run |
| route-interruption | Route change and audio interruption return to live rebuffer | real-device | No measured headphones/Bluetooth route-change or interruption result is recorded | pending device run |
| capture-reset | WASAPI endpoint reset starts a new stream without replaying stale audio | real-device | No connected-iPad endpoint-reset result is recorded | pending device run |
