# USB Priority Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Integrate USB into both existing apps, discover USB and network concurrently, and prefer an authenticated USB path while playing only one stream.

**Architecture:** Forward existing encrypted QUIC packets over a framed usbmux TCP connection. Keep independent Windows sender/authentication instances for the network and loopback USB entrances, with one host coordinator granting audio ownership. On iPad, authenticate a candidate without starting playback, then promote it through the existing ReceiverReady handshake.

**Tech Stack:** C++20, Winsock, XmlLite, Windows DNS-SD, MsQuic; Swift 5.9, Network.framework, SwiftUI; existing CMake and GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-10-17-usb-integration-design.md`

## Global Constraints

- Main workspace, inline execution; the user explicitly waived further plan confirmation.
- Preserve existing certificate identity, PIN authentication and remembered credentials. No new cryptography or Python production dependency.
- iOS 16 / macOS 13 package floors; Windows 10 desktop APIs.
- USB iPad TCP entrance is `127.0.0.1:52138`; Windows USB QUIC entrance binds loopback on an allocated port.
- Maximum outer payload is 65,535 bytes; pending payload bytes per direction are bounded to 64 KiB. Account for in-flight writes and expire excessive queue age within the existing maximum latency budget.
- Audio, personal paths, device identifiers and raw logs remain local.
- Network tests/calibration stay on network; music tests retain their starting path through report recovery.
- Reuse the current playback budgets. Switching rebuilds streams and clock mapping and may pause playback briefly.

## Review Focus

1. An untrusted USB candidate must not stop an authenticated network stream (Task 2/3).
2. Old close callbacks must not clear a newly promoted stream (Task 2/3).
3. User stop and successful test completion must suppress automatic fallback/restart (Task 4).
4. Simultaneous first pairing must share the PIN window and failure limit without rotating credentials twice (Task 2).
5. Partial TCP writes, unavailable Apple services and USB reconnects must be cancellable and memory bounded (Task 1).

### Task 1: Bounded USB packet tunnel

**Files:** Create `windows/include/hearport/windows/usb_tunnel.h`, `windows/src/usb_tunnel.cpp`, `windows/tests/usb_tunnel_tests.cpp`, `ios/HearPortReceiver/Sources/HearPortReceiver/USBPacketTunnel.swift`, `ios/HearPortReceiver/Tests/HearPortReceiverTests/USBPacketTunnelTests.swift`; modify `windows/CMakeLists.txt`.

**Interfaces:** `UsbPacketDecoder::Push(span<byte>, vector<vector<byte>>&) -> bool`; `EncodeUsbPacket(span<byte>) -> vector<byte>`; `UsbTunnel::Start(uint16_t quic_port, StatusHandler, LogHandler)`, `SetMaximumLatency(milliseconds)`, `Stop()`. Swift equivalents `USBPacketDecoder.append(_:) throws -> [Data]`, `USBPacketTunnel.start()`, `stop()`, `onAvailable(UInt16)`, `onUnavailable(String)`.

- [x] Add decoder tests for fragmented/coalesced frames, zero length, bad version, excessive bytes and EOF, plus backpressure tests proving pending payload never exceeds 65,536 bytes.
- [x] Observe the new tests fail before implementation; group the Windows build with the first working tunnel deliverable.
- [x] Implement an eight-byte per-packet header: ASCII `HPUQ`, version 1, reserved 0, uint16 big-endian payload length. Payload length must be 1...65,535. Cap pending packets at 128 as well as the byte cap.
- [x] Implement native usbmux plist request/response framing (16-byte little-endian header, maximum response 1 MiB), XML parsing with no external entity resolution, ListDevices and Listen events. Filter actual USB devices; try candidates sequentially, with cancellable 1/2/4/8/10-second retries.
- [x] Bridge only to the host's fixed loopback QUIC port. Use nonblocking sockets and partial-write offsets; never discard a partly written frame. Close on malformed input, queue overflow or excessive age.
- [x] Implement iPad loopback TCP listener plus per-tunnel loopback UDP listener with Network.framework. Only one TCP tunnel is admitted; UDP return packets go only to the local QUIC peer.
- [x] Run the focused C++ tests; run Swift tests through the existing Actions workflow in the final batch. Commit the coherent tunnel deliverable after verification.

### Task 2: Windows discovery and single audio ownership

**Files:** Create `windows/include/hearport/windows/sender_host.h`, `windows/src/sender_host.cpp`, `windows/include/hearport/windows/service_discovery.h`, `windows/src/service_discovery.cpp`, `windows/tests/connection_selection_tests.cpp`; modify sender service/authentication, QUIC server, GUI and CLI entry points, and CMake.

**Interfaces:** `SenderHost` owns two existing `SenderService`/`SenderAuthentication` pairs and one shared `SenderPairingState`. It exposes `Start()`, `Stop()`, `OpenPairingWindow()`, `pairing_pin()`, active-service diagnostic access and route-aware status callbacks. `SenderService::SetActivationHandler(function<bool()>)` gates BeginStream; `SuspendForHandover()` stops old audio and closes its connection. `QuicServer::LocalPort()` exposes the allocated port; `QuicServerOptions::loopback_only` restricts USB binding.

- [x] Add arbitration tests: USB preferred for the same remembered peer; untrusted/different peer cannot preempt; only one owner; stale connection generations cannot release the new owner; test mode prevents route changes.
- [x] Add shared pairing-window tests for the common PIN, accumulated failed attempts and reopening; inspect confirmation consumption and epoch checks under the shared mutex.
- [x] Implement shared PIN/window state while keeping each endpoint's SPAKE/HMAC, frame decoder and session state isolated. Move active-media configuration behind ownership acquisition.
- [x] Start WASAPI capture only when an owned stream begins, and stop it on handover. Avoid joining worker threads from their own callbacks; serialize ownership changes separately from QUIC callback locks.
- [x] Bind USB MsQuic to loopback with port zero and query its actual port; retain the network listener on the configured port. Route bridge availability and budget changes to the correct instance.
- [x] Publish `_hearport._udp` using `DnsServiceRegister`/`DnsServiceDeRegister`. Publish protocol version and public certificate-hash hint; actual TLS authentication remains authoritative. Cancel registration safely at stop.
- [x] Replace duplicated GUI/CLI service/auth wiring with SenderHost while keeping existing diagnostics controls and output paths. Show active physical route and actionable USB errors.
- [x] Run focused arbitration/authentication tests plus the Windows build; commit verified changes.

### Task 3: iPad parallel discovery and authenticated promotion

**Files:** Create `ios/HearPortReceiver/Sources/HearPortReceiver/ReceiverConnectionCoordinator.swift` and corresponding tests; modify `ReceiverControlSession.swift`, `HearPortApp.swift`, `ConnectionPreferences.swift`, app Info.plist and localized strings.

**Interfaces:** `ConnectionEndpoint` identifies network/USB plus endpoint; coordinator supplies connection IDs and request/cancel callbacks, tracks connection intent and retry timing, and accepts authenticated/closed events. `ReceiverControlSession.connect(..., deferActivation: Bool = false)` and `activate()` expose the existing SessionReady/ReceiverReady boundary; `onAuthenticated` reports authenticated identity/features before playback.

- [x] Add policy tests for network-first/USB-first, failed candidate, unplug fallback, stale callbacks, manual stop, retries and pinned diagnostics; assert an unknown USB candidate cannot replace the active session.
- [x] Defer pending report upload, ReceiverReady, clock negotiation and output startup until candidate activation. Keep candidate receiver/control state separate from the current receiver.
- [x] Browse `_hearport._udp` with NWBrowser and declare NSBonjourServices. Prefer matching remembered certificate hints, verify the actual TLS identity, and preserve manual address input.
- [x] Start the USB listener alongside network browsing. On connection intent, try available USB first and keep network discovery active. Authenticate USB in the background while network plays; only then stop the old output and activate USB.
- [x] Preserve the real network address in preferences; never save 127.0.0.1 as the remembered PC. A one-time session must not silently acquire persistent credentials or bypass an expired pairing window.
- [x] Gate every asynchronous UI update by connection ID. Show the physical route independently from Datagram/Reliable mode and retain current styles.
- [x] Run coordinator/codec tests in Actions with the final integrated changes; commit after verification.

### Task 4: Explicit stop, diagnostics and report lifecycle

**Files:** Modify `protocol/hearport-v1.proto`, core/Swift control codecs and tests, `SenderHost`, `SenderService`, `ReceiverControlSession`, coordinator, debug diagnostics and UI status handling.

**Interfaces:** Add `SessionEnd(reason)` and `SessionEndAck` at ControlEnvelope fields 45/46. Reasons distinguish user stop (1) and handover (2). A bounded acknowledgment wait precedes deliberate close; abrupt cable loss remains a transport failure. Existing diagnostic end/report acknowledgment remains authoritative for normal test completion.

- [x] Add cross-language golden codec vectors, invalid-reason tests, stop-during-handover tests and completed-test suppression tests.
- [x] Notify the peer on intentional stop and preserve connection intent only for handover; close after acknowledgment or a bounded timeout. Application exit must not hang waiting for an absent peer.
- [x] Prevent USB takeover during network tests/calibration and pin music tests through report recovery; mark failures as interrupted and record physical route and connection generation in local reports.
- [x] Propagate active playout maximum to tunnel queue guards. Log bridge queue age/bytes, overflow, route changes and failure reasons without raw audio or secrets.
- [x] Verify existing report recovery, normal-end text and calibration behavior remain intact; commit verified changes.

### Task 5: Integration verification and delivery

**Files:** Extend `tests/integration/` tunnel/QUIC checks and `.github/workflows/ios-receiver.yml`; update existing onboarding docs and this checklist.

- [x] Exercise actual QUIC through the framed tunnel: control stream and both audio modes, certificate pin rejection, fragmented framing and cancellation. Use existing aioquic test infrastructure; production remains native.
- [x] Build Windows Debug with the existing VS2022 MsQuic build directory, normalizing environment key casing for MSBuild. Run CTest with `--output-on-failure`; inspect all failures.
- [x] Run GitHub Actions Swift package tests, interoperability tests and the normal unsigned iPad app build. Verify artifact build identity and download the resulting IPA locally.
- [x] Review the final diff for scope, lifecycle races, unintended buffering and security changes. Use one final reviewer with the current model or cheaper only; no Astra or per-task reviewers.
- [x] Start the updated Windows app after clean shutdown of the old instance, and provide the exact IPA/build and concise real-device validation sequence. Build/local verification and actual iPad playback results must be reported separately.

## Execution record

The user approved the written design and USB packet forwarding on 2026-10-17, then explicitly requested development to start directly after planning without another confirmation. Work continues inline in the main checkout.


## Verified delivery

- Windows Debug full build and all **22 CTest tests** passed.
- Three real Windows QUIC fragmented-control / SPAKE challenge / shutdown integration runs passed; no pairing credential was saved by these probes.
- GitHub Actions [38963093107](https://github.com/lsy223622/HearPort/actions/runs/38963093107) passed **136 Swift tests**, including encrypted QUIC control and both audio modes through the USB packet tunnel, plus certificate-pin rejection.
- The normal iPad app archived successfully as **build 143**, source `99a82249f21df9311160b6f50b14d6ad517e19c8`. Downloaded IPA build identity, Bonjour declaration, arm64 executable and SHA256 were verified locally.
- Independent review findings were fixed in one combined pass. The updated Windows GUI was launched; both QUIC listeners were observed, and a paired destination check accepted loopback and rejected the LAN address at the USB entrance.
- Actual iPad installation, music playback, cable switching and lockscreen behavior still require device validation; local/CI results do not establish those outcomes.
