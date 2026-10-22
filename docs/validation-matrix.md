# HearPort 0.1.0 validation matrix

## Portable runtime loading regression (2026-10-22)

- Reproduced the portable package failure in a fresh Windows Sandbox without a System32 `vcruntime140.dll`: the application-local file existed, but the old GUI exited with `0xC0000135`. A CRT-free probe failed to load MsQuic with error 126; preloading the same local runtime made the probe succeed.
- The pinned `msquic.dll` has `DependentLoadFlags=0x0800`, restricting its imports to System32. Both sender executables now delay-load MsQuic after their own VC runtime initializes; no system runtime installation or third-party DLL modification is involved.
- The rebuilt GUI remained responsive in the same Sandbox, loaded MsQuic and all three VC runtime DLLs from its own directory and bound UDP 52137. System32 still contained no VC runtime. This validates loading/startup, not end-to-end audio in Sandbox.
- Packaging rejects an executable whose PE delay-import table does not contain MsQuic. CI startup verification checks the actual loaded path of every bundled DLL, preventing system-installed runtime files from silently satisfying the check. Local checks: 25 CTest and 33 combined Python tests passed.

## Connection automation verification (2026-10-22)

- Source `8ba6d9ab9e7335f72a5122b166d66d320f1e0493`: Windows Actions [39748549052](https://github.com/lsy223622/HearPort/actions/runs/39748549052), iPad Actions [39748549005](https://github.com/lsy223622/HearPort/actions/runs/39748549005), CodeQL [39748548777](https://github.com/lsy223622/HearPort/actions/runs/39748548777) passed. Windows: 25 CTest, 28 package checks and GUI startup/paint verification. Swift: 221 tests including recovery intent, fixed-route exclusion and stale-session stop rejection; four Python shortcut/trace-analysis checks also passed in iPad CI.
- Unsigned iPad build 191 contains ten distinct intent/shortcut entry points. Archive checks validate route parameters, foreground flags, AudioStarting conformance, URL registration and the audio background mode. Audio entry points require iPadOS 17.2 in this SDK's metadata; ordinary intents retain iPadOS 16 compatibility.
- Downloaded archive hashes, all 100 Windows runtime files, embedded source/build IDs and unsigned packaging verified; the matching Actions Windows package responded and bound UDP 52137 locally. These checks do not exercise iPad OS scheduling or physical audio output.
- Five foreground URL shortcut sources were generated. Actual macOS signing attempts failed for missing iCloud login. Ten built-in App Shortcuts supply usable native entry points without requiring file import; on-device indexing and execution remain pending.
- Physical matrix and local analyzer: [connection-automation.md](connection-automation.md). Background, lock-screen, force-quit, Wi-Fi/charger trigger behavior and final audible output are **pending device execution**, not inferred from compilation, metadata or desktop timing.


Automated tests and successful builds do not establish real-device playback,
background behavior, or long-session reliability. User-observed runs are listed
separately from repeatable test evidence; signed installation and soak results
are not inferred from an unsigned archive or short playback.

**User-observed manual runs:** playback on an iPad Pro 11-inch (2020) over USB,
including cable disconnect and reconnect; repeated playback/tests on weak
2.4 GHz Wi-Fi. These observations do not establish a timed soak, lock-screen
behavior across all output routes, a clean-machine install, or final Release acceptance.

**Additional user observation (2026-10-21):** the installed app was left idle
with the iPad locked for several hours. Later Windows audio still played through
the iPad without lighting its screen. The exact build, physical path and elapsed
time were not supplied for this observation. It records successful locked-idle
continuation/resumption; it is not a monitored continuous-music soak.

## Pairing safety and interaction recovery (2026-10-21)

- Matching source `e59628ab0f34fd6a8f9a8293d5c5d20e4ed03078`: Windows Actions [39593250742](https://github.com/lsy223622/HearPort/actions/runs/39593250742) passed 24 CTest, 28 Python checks and packaged startup/paint checks; iPad Actions [39593250802](https://github.com/lsy223622/HearPort/actions/runs/39593250802) passed 216 Swift tests and archived unsigned build 184; CodeQL [39593251795](https://github.com/lsy223622/HearPort/actions/runs/39593251795) passed. Downloaded hashes, all 100 Windows files, matching embedded build identities and unsigned IPA packaging verified. The Actions Windows executable was launched locally, responded and listened on UDP 52137.
- An explicit remembered-authentication rejection received through pinned TLS stops receiver retries and offers pairing recovery, while retaining the saved credential. Transport errors, timeouts and ordinary session ends cannot delete credentials.
- SessionEnd reason 3 is an authenticated unpair notice. Both endpoints compare the session credential against the currently saved peer ID, secret and server identity before deletion, preserving newer pairings. Offline cancellation remains local; the next explicit authentication rejection stops the other endpoint's retries.
- Deliberate iPad disconnects keep the closing session alive until ACK or 500 ms. Connection-generation guards prevent its completion from stopping a new attempt. Windows local unpair closes the old host on a worker, retains logging through shutdown and joins before restart or exit.
- Manual address edits clear the old endpoint selection. Numeric delay edits update their binding before test startup. The recommendation page can select a discovered network-capable PC without losing goal/duration/delay choices. Audio engine interruption/recovery/failure is reflected in the main canvas; failed playback offers retry.
- Local Windows Release build, all 24 CTest cases and 28 Python checks passed. A focused codec check first rejected the unpair vector, then passed after the protocol change. Cross-language vectors cover reason 3 and reject unknown reasons. Swift pairing-policy checks include unauthenticated notices, normal ends, missing credentials and changed peer/secret/server identity.
- Device acceptance pending: both directions of connected unpair and re-pair; one-sided offline unpair followed by explicit rejection with credential retention; ordinary USB/network interruption without lost pairing; edited manual address; typed delay followed immediately by Start; in-page PC selection; output-recovery failure/retry feedback when reproducible.

## Independent network and USB latency settings (2026-10-21)

- Menu summary follow-up: source `1e15f44e2d502afb27a9374a24ba5fc29c41bbb2`, iPad Actions [39586833423](https://github.com/lsy223622/HearPort/actions/runs/39586833423), 214 Swift tests and unsigned build 183 passed; CodeQL [39586833653](https://github.com/lsy223622/HearPort/actions/runs/39586833653) passed. IPA hash, embedded identity and unsigned packaging verified. Each route menu row now shows encoding plus its own target/maximum in a second, localized line. Device appearance remains to be checked.
- Source `3370ee2c55083328c1d0d3c66ebc111a674e7af1`: iPad Actions [39583024058](https://github.com/lsy223622/HearPort/actions/runs/39583024058) passed 214 Swift tests and archived unsigned build 182. CodeQL [39583022167](https://github.com/lsy223622/HearPort/actions/runs/39583022167) passed. Downloaded IPA SHA-256, embedded source/build identity and unsigned packaging were verified.
- Network audio and USB audio each contain their own normal target and maximum total delay. Connections and route changes read the actual route's saved budget; USB tunnel queue expiry follows its USB maximum. Active playback continues using its negotiated snapshot until the next connection.
- Upgrade migration preserves the previous shared delay values for network playback; USB starts at the original 50/100 ms defaults. Existing separate route values are preserved on repeated migration.
- Both adaptive quick recommendations and full diagnostic calibration application update network latency only. Regression coverage checks factory defaults, migration persistence and preservation of custom USB budgets in both application paths.
- Physical acceptance pending: install the new IPA, confirm the existing network recommendation is retained, edit both route budgets independently, and check the active values after USB insertion/removal and after applying a network recommendation.

## iPad row actions, launch layout and connection address (2026-10-21)

- iPad executable source `2bebb701a278d94fbbc6876b6397777021e18c50`: Actions [39544315416](https://github.com/lsy223622/HearPort/actions/runs/39544315416) passed 211 Swift tests and archived unsigned IPA build 181. CodeQL [39544315151](https://github.com/lsy223622/HearPort/actions/runs/39544315151) passed. Downloaded IPA SHA-256, source/build identity and unsigned packaging were verified.
- Blue Connect, Start automatic test and Apply parameters actions use native Form/List row buttons with expanded hit shapes. With no active or selected connection, the disabled start action reads No connection selected.
- Initial canvas transactions disable animations until the first UIKit appearance completes. Subsequent presentation-stage changes keep their existing animation; reduced-motion handling remains in effect.
- Connection details read the connected QUIC control stream's numeric remote endpoint and port, including path updates. Pre-authentication address callbacks are retained until that session is promoted; stale-session callbacks cannot replace the active address. Tests cover IPv4/IPv6 formatting and an actual loopback QUIC connection's address.
- User acceptance update (2026-10-21): the user confirmed startup layout now appears in place. Five supplied dark-mode screenshots show the compact remembered/pairing forms, recommendation label/value rows, the disabled No connection selected action, settings and network-audio controls without visible clipping. The screenshots are retained locally. Full-row tap behavior, numeric LAN endpoint display and light-mode appearance remain separate acceptance items; static screenshots do not establish touch behavior.

## Automatic-test startup and diagnostic size display (2026-10-21)

- Matching executable source `ea1683110ccd80181d6205716bc35b163c8e95c4`: Windows Actions [39478078837](https://github.com/lsy223622/HearPort/actions/runs/39478078837) passed 24 CTest, 28 Python checks and packaged GUI checks. iPad Actions [39478078798](https://github.com/lsy223622/HearPort/actions/runs/39478078798) passed 209 Swift tests and archived unsigned build 180. CodeQL [39478077872](https://github.com/lsy223622/HearPort/actions/runs/39478077872) passed.
- Downloaded archive/IPA hashes, both source identities, IPA build/unsigned status and all 100 Windows packaged-file hashes verified. The downloaded Windows package passed the local startup/window checks and was launched for use.
- The supplied build 179 device export contains over 500,000 records. Its 2,000-entry count describes the bounded in-memory preview, not file retention. The diagnostics page now labels that count explicitly, sums active and rotated file sizes and refreshes while open. Retention limits remain approximately 4 MiB normally and 128 MiB with detailed logging.
- Normal audio readiness previously notified the UI after writing `ReceiverReady`, before an accepted `StartStreamAck` established the active stream ID required by a calibration request. Readiness now waits for both writes, in either order, and notifies once. Probe sessions do not require an audio stream acknowledgement. New gate tests cover both completion orders, probe readiness and reset for another connection; request outcomes are recorded in runtime logs.
- Pairing uses the same narrow form presenter as settings/details, with a blue text Connect action. Windows uses one pairing action in the original right-hand position, selecting pair or unpair according to its saved credential.
- Local Windows Release build, 24 CTest, 28 Python checks and real-window startup/clipping/order/unchanged-status checks passed. Physical acceptance remains pending installation of build 180: home-started tests, ordinary music startup, retained-report recovery, pairing form width/color and live diagnostic totals. The readiness tests exercise the shared gate; the iOS control-session path is archive-compiled, not a device handshake test.

## Connection actions and Windows painting (2026-10-21)

- Windows executable source `3e8543a8bcea881d7bfb066a5080c6f9932af8c0`: Actions [39473183485](https://github.com/lsy223622/HearPort/actions/runs/39473183485), 24 CTest and 28 Python checks passed. The extracted release package also passed GUI startup, clipping, background order and unchanged-status invalidation checks.
- Final iPad source `9f45c551e44456996aaf242d425d32f28a11e1f2`: Actions [39473786709](https://github.com/lsy223622/HearPort/actions/runs/39473786709), 205 Swift tests and unsigned IPA build 179 passed. CodeQL [39473788094](https://github.com/lsy223622/HearPort/actions/runs/39473788094) passed. The downloaded IPA hash, source/build identity and unsigned packaging were verified; the follow-up commit only changes iPad pending-test cleanup.
- The same window check fails on the previous package: the parent can erase child pixels, and overlapping group/tab backgrounds have incorrect sibling clipping/order. Backgrounds now own their regions, groups fill their background, unchanged status text does not invalidate controls, and selecting the current page does not repeat visibility changes. Timer-driven full-window invalidation is absent.
- Downloaded archive hashes, source identity and all 100 Windows packaged-file hashes verified. The Actions executable passed the local GUI check, remained responsive and listened on UDP 52137. Its connected status displayed the negotiated PCM/Opus format rather than a preset name.
- The iPad changes add available-computer context actions for testing and local unpairing, PIN-first test startup, foreground keep-awake control, automatic ordinary reconnection after quick testing, and preservation of results across that reconnection. A policy regression checks reconnect intent, USB promotion, stale test closure and explicit stop. Terminal pairing errors and ordinary connection selection discard a pending test.
- Physical acceptance remains pending installation of build 179: long-press actions, incorrect-PIN recovery without a stale test, unpair/re-pair on both endpoints, test completion followed by ordinary playback, keep-awake behavior, and light/dark layout/colors. Runtime window checks do not establish every device interaction or prolonged visual behavior during calibration.

## iPad menu presentation (2026-10-20)

- iPad executable source `d8977fa9d6b3bb9946baa1f1724cac3b1cbc28ec`.
- Actions [39440168724](https://github.com/lsy223622/HearPort/actions/runs/39440168724): 204 Swift tests passed and unsigned IPA build 177 archived. CodeQL [39440168151](https://github.com/lsy223622/HearPort/actions/runs/39440168151) passed.
- Downloaded IPA SHA-256, source identity, build number and unsigned packaging verified.
- Recommendation rows use label/value pairs with a visible test timestamp. Test ceiling and segment duration are visible together; action rows use blue text. The native segmented control uses a 44-point height and body-size titles. Settings/details use a form presentation with a preferred 600-point width.
- Stable network status uses the icon asset's RGB (30,210,167); stable USB status uses system blue across the connection symbol, status text and details. Other stability levels keep their existing colors.
- Physical acceptance remains pending installation: compact sheet width, presentation/dismissal, navigation and confirmation dialogs, enlarged segments, blue action rows and system light/dark appearance. A successful archive does not establish screenshot appearance or touch interaction.
- Current Windows Actions package remains the validated `2571b1b` server; this revision changes iPad presentation.

## Transport comparison and route settings (2026-10-20)

- Executable source `2571b1b29a160617d71a087b8c48018687269c3a`.
- Windows Actions [39425040006](https://github.com/lsy223622/HearPort/actions/runs/39425040006): Release package, 24 CTest and 28 Python checks passed. The extracted distribution also passed a four-second GUI startup check before upload.
- iPad Actions [39425055397](https://github.com/lsy223622/HearPort/actions/runs/39425055397): 204 Swift checks passed and unsigned IPA build 176 archived. CodeQL [39425038251](https://github.com/lsy223622/HearPort/actions/runs/39425038251) passed.
- Regression Actions [39422781309](https://github.com/lsy223622/HearPort/actions/runs/39422781309) reproduced the last-round adjustment bias, missing transport comparisons at changed settings and sensitivity to small latency differences. Passing coverage includes two observations per transport at every load/budget, either configured preference retained on close results, a material difference overriding preference, independent route preferences, detailed measurement export and retention downgrade.
- Each candidate uses an ABBA block. Comparison tolerances include observed repeat variation and a fixed floor; they are selection heuristics, not confidence intervals. Similar transport results are disclosed. Final longer repeats verify the selected candidate; this does not establish a causal transport advantage or future rare-loss rate.
- Logs retain approximately 4 MiB normally or 128 MiB with detailed logging enabled. Disabling detailed logging prunes excess files and oversized retained files. The Windows detailed-event filter preserves failures; iPad detailed logs include per-round parameter/measurement JSON and selection outcome. Quick tests do not automatically upload a report.
- Download hashes, all 100 Windows packaged-file hashes, matching Windows/IPA source identities and unsigned IPA packaging verified. The final Actions Windows executable remained running and bound UDP 52137. Its ordinary runtime files were each at most 1 MiB with only three backups retained.
- Physical acceptance remains pending installation of build 176: independent USB/network transport changes and handover, direct delay input, light/dark action buttons, and a fresh recommendation with detailed logs. Build/automated evidence does not establish device UI appearance or comparative network performance.

## USB recovery and extended diagnostics (2026-10-20)

- Matching executable source `82bdaee35a7d32a72a6edfabc3abe56491e40bd8`.
- Windows Actions [39417771470](https://github.com/lsy223622/HearPort/actions/runs/39417771470): Release package, 24 CTest and 28 Python checks passed.
- iPad Actions [39417768450](https://github.com/lsy223622/HearPort/actions/runs/39417768450): 197 Swift checks passed and unsigned IPA build 173 archived. Coverage includes listener recreation, USB cooldown retry while LAN is active, preservation of an accepted tunnel, larger default log retention and Unicode streaming export.
- CodeQL [39417768290](https://github.com/lsy223622/HearPort/actions/runs/39417768290) passed. Both archive hashes/source identities and all 100 Windows packaged-file hashes verified. The Actions Windows package started and bound UDP 52137.
- Build 170 physical evidence showed continued LAN playback and usbmux Connect result 3 on the USB entrance. Startup listener events had rotated out; the original lifecycle transition remains unproven. Old-behavior regressions reproduced two recovery gaps; final fixtures use isolated ports to avoid the live CI QUIC bridge.
- That candidate used 16 MiB per file plus seven backups on each endpoint (approximately 128 MiB). iPad export copies a fixed-length descriptor snapshot outside the writer lock on a background queue and records current USB states.
- Physical long-running acceptance remains pending installation of build 173; automated lifecycle simulations do not prove the cause or recovery of the original device failure.

## Adaptive client recommendations (2026-10-20)

- Final executable source: `4de8694f96a76537d518556dccff93f849acd149`.
- Windows Actions [39399070518](https://github.com/lsy223622/HearPort/actions/runs/39399070518): Release package, 24 CTest and 28 Python checks passed.
- iPad Actions [39399056345](https://github.com/lsy223622/HearPort/actions/runs/39399056345): 194 Swift checks passed, including adaptive search, shared v5 fixtures, dynamic frame sizes, invalid-clock rejection, preference application and progress estimates; unsigned IPA build 170 archived.
- CodeQL [39399055960](https://github.com/lsy223622/HearPort/actions/runs/39399055960) passed.
- Download checksums, all 100 packaged Windows file hashes, matching Windows/IPA source identities, IPA build 170 and unsigned packaging verified. Downloaded Windows Actions executable started and listened on UDP 52137.
- Quick tests choose one goal, repeat settings, adjust network format/bitrate/frame duration and budget, and verify one candidate with two longer windows. Results are local; the completion acknowledgement contains no report. Full Windows diagnostic calibration retains the existing v4 path.
- Stability first selects the best observed continuity within the budget; nonzero gaps remain visible. Low latency and Balanced require their selection targets in both verification windows before application. These are finite observations, not established future loss rates or causal proof against network variation.
- Physical acceptance remains pending: USB unplug/insert with authoritative negotiated-format display; 5 ms latency controls; quick-test progress, local completion and application; normal audio after reconnection. Random CBR-shaped traffic reserves codec preparation time but does not verify decoder throughput or acoustic latency.

## Live compression development (2026-10-20)

### Capture-silence recovery regression

- Build 165 can keep advancing the coordinated playback cursor after capture stops,
  causing resumed source packets to be classified late indefinitely.
- Regression Actions [39391950466](https://github.com/lsy223622/HearPort/actions/runs/39391950466)
  reproduced it: 20 resumed packets rejected as late and no resumed audio on the
  same stream. The other 186 tests passed. Decoder-only silence coverage had not
  exercised the playback pump interaction.
- The pump now advances source gaps only while a buffered packet establishes the
  future timeline; staged audio drains into the existing silent-rebuffer path.
- Fixed Actions [39392343378](https://github.com/lsy223622/HearPort/actions/runs/39392343378): all 187 Swift tests passed, including resumed playback on the original stream; unsigned IPA archived. CodeQL [39392343011](https://github.com/lsy223622/HearPort/actions/runs/39392343011) passed. Physical switching-track acceptance remains pending installation.

- Network/USB encoding preferences, negotiated live Opus and PCM, bitrate/frame duration settings implemented.
- Local Release build: 24/24 CTest checks; focused Python: 17 analyzer and 4 package checks passed.
- Matching source `21b3848312e16aa652c55704991839502698feee`: Windows Actions [39386364549](https://github.com/lsy223622/HearPort/actions/runs/39386364549) passed 24 CTest and 28 Python checks; iPad Actions [39386215008](https://github.com/lsy223622/HearPort/actions/runs/39386215008) passed 186 Swift tests and archived unsigned IPA build 165; CodeQL [39386214238](https://github.com/lsy223622/HearPort/actions/runs/39386214238) passed.
- Download hashes, all 100 Windows file hashes, IPA build identity and bundled Opus notices verified. Downloaded Windows Release started, loaded its runtime DLLs locally, and listened on network and tunnel endpoints.
- New live-path iPad listening, silence/resume and route-switch acceptance remain pending installation on the device.

## Compression test candidate evidence (2026-10-20)

- Source commit: `53de0cd7eefa0afd9e63f549b50439c023172b51`, product version 0.1.0.
- Windows Actions [39360465692](https://github.com/lsy223622/HearPort/actions/runs/39360465692): Release build, 23 CTest checks and 28 Python checks passed; portable ZIP, matching source ZIP and SHA-256 manifest uploaded.
- iPad Actions [39360464729](https://github.com/lsy223622/HearPort/actions/runs/39360464729): 179 Swift tests passed, including real QUIC framing/mode-switch integration; unsigned Release IPA build 162 archived with Opus and Rust license notices.
- CodeQL [39360464054](https://github.com/lsy223622/HearPort/actions/runs/39360464054) passed.
- Download hashes, Windows per-file manifest, IPA commit/build metadata and bundled Opus license checked. The downloaded Windows package started, loaded its four runtime DLLs locally and listened on UDP 52137 plus the USB tunnel's loopback endpoint.
- Physical build 162 tests completed: 32 USB music rounds and 32 network music rounds at target 225 ms / maximum 300 ms, 60 seconds per round. All music rounds have complete durable summaries and zero decode failures. Network results vary across repeats; startup trimming and transport pressure prevent declaring a universal winning profile. iPad Opus per-group decode p99 stayed below 0.50 ms. Raw reports and music remain local. Procedure: [compression-tests.md](compression-tests.md).

## Previous release candidate evidence (2026-10-18)

- Source commit: `35f00d8c5adfdb6e27d724daaff6677b0172abfb`, product version 0.1.0.
- Windows Actions [39052133439](https://github.com/lsy223622/HearPort/actions/runs/39052133439): Release build, 22 CTest checks and 6 package/document checks passed; portable ZIP, source ZIP and SHA-256 manifest uploaded.
- iPad Actions [39052135647](https://github.com/lsy223622/HearPort/actions/runs/39052135647): 156 Swift tests passed; unsigned Release IPA build 158 archived with bundled license notices.
- Download hashes, Windows per-file manifest and IPA commit/version metadata checked. The extracted Windows package started on the development PC and loaded all four runtime DLLs from its own folder.
- Clean-PC playback and final signed-on-device lifecycle/soak acceptance remain pending. Existing LAN/USB observations remain valid evidence, distinct from acceptance of this package.

| ID | Requirement | Evidence type | Evidence | Status |
|---|---|---|---|---|
| protocol-control | Control framing and canonical ControlEnvelope field layout | automated | `python -m unittest tests.reference.test_wire_codec tests.reference.test_control_messages -v` | passed |
| protocol-audio | 968-byte AUDIO payload, big-endian header, non-zero stream id | automated | `python -m unittest tests.reference.test_wire_codec -v` | passed |
| session-gating | Pending stream, matching ACK, old stream and reset behavior | automated | `python -m unittest tests.reference.test_session_state -v` | passed |
| windows-capture | Shared-mode WASAPI Loopback and endpoint reset | native-build | Windows Release Actions [39052133439](https://github.com/lsy223622/HearPort/actions/runs/39052133439) passed all 22 CTest checks; ordinary playback was observed on the user's iPad; endpoint-reset runtime remains unverified | 22 Release CI tests passed; endpoint-reset check pending |
| windows-quic | MsQuic TLS/ALPN/DATAGRAM transport and 968-byte send capability | native-build | VS 2022 x64 MsQuic build/startup smoke initialized the configured certificate and bound UDP 52137; Windows Release Actions [39052133439](https://github.com/lsy223622/HearPort/actions/runs/39052133439) passed all 22 CTest checks; the extracted Actions package started with app-local runtime DLLs; USB playback/reconnect was user-observed; LAN playback and complete diagnostics were also observed in repeated weak-Wi-Fi sessions | build/startup, local tests and user-observed LAN/USB sessions passed; clean Release install pending |
| ios-quic | Network.framework QUIC client, one control stream and one DATAGRAM flow | automated | GitHub Actions [run 39052135647](https://github.com/lsy223622/HearPort/actions/runs/39052135647) on macOS 14: all 156 Swift package tests passed; iPad-device and live Windows/LAN interoperability remain separate | Swift package tests passed; LAN/USB sessions user-observed; final package acceptance pending |
| ios-audio | AVAudioSession stereo playback, local silence and render callback | native-build | GitHub Actions [run 39052135647](https://github.com/lsy223622/HearPort/actions/runs/39052135647) archived the iOS app unsigned; Swift package tests passed; USB playback and cable reconnect were user-observed on an iPad Pro 11-inch (2020) | unsigned archive and short playback observed; route, interruption, and soak checks pending |
| ios-app-archive | HearPort app target and standard unsigned IPA packaging | native-build | GitHub Actions [run 39052135647](https://github.com/lsy223622/HearPort/actions/runs/39052135647) generated the Xcode project, archived the app with signing disabled, validated app metadata, and uploaded unsigned Release IPA build 158 with license resources | CI artifact created; user signing and install from release bundle pending |
| security-pairing | PIN scalar, SPKI identity, SPAKE2 point/key/confirmation and failure handling | automated | Python vectors, Rust provider tests, and native `hearport_security_tests` under VS 2022; included in the 22-test Windows Release Actions run | automated checks passed |
| security-remembered | One-shot nonce, HMAC, peer-id and SPKI pinning | automated | Python vectors and native `hearport_security_tests` under VS 2022; included in the 22-test Windows Release Actions run | automated checks passed |
| diagnostics | Local sender/receiver event schema and export behavior | automated | JSON Schemas under `diagnostics/schemas/`, bounded asynchronous diagnostics, receiver and render metrics, and tests for export, redaction, rotation, and clearing | automated checks passed; review an exported report before sharing because it may contain network details such as a hostname, IP address, or port |
| network-impairment | Jitter, reorder, burst loss and outage recovery | real-device | Repeated weak 2.4 GHz Wi-Fi playback/tests were user-observed; paired offline replay and real-session reports exist; these are not a controlled validation of every impairment scenario | real Wi-Fi and paired offline evidence recorded; final Release soak pending |
| clock-drift | Bounded slow correction for +/- ppm producer/consumer mismatch | automated | `python -m unittest tests.reference.test_realtime_core -v` | passed for reference |
| foreground-soak | Two-hour foreground active-playback stability | real-device | Short playback and USB reconnect were user-observed on iPad Pro 11-inch (2020); no timed two-hour result is recorded | observed playback; two-hour soak pending |
| silent-playback | Windows capture idle, local zero output, then rebuffer and resume | real-device | Requires a foreground run that observes capture idle, silence, and recovery on a signed or otherwise launchable iPad | pending device run |
| background-lock-screen | Audio session behavior after lock/background transition | real-device | No signed-release lock-screen or background result is recorded | pending device run |
| route-interruption | Route change and audio interruption return to live rebuffer | real-device | No measured headphones/Bluetooth route-change or interruption result is recorded | pending device run |
| capture-reset | WASAPI endpoint reset starts a new stream without replaying stale audio | real-device | No connected-iPad endpoint-reset result is recorded | pending device run |
