# Connection Automation & iPad Shortcuts Guide

This guide covers HearPort's daily auto-reconnect behavior, built-in iPadOS App Shortcuts, recommended Personal Automations, and on-device troubleshooting.

---

## Daily Auto-Connection Behavior

- **Windows auto-start at sign-in**: Enabling auto-start in Windows **Settings** launches HearPort silently to the system tray and starts the sender. If you move the portable folder while auto-start is enabled, manually launching `HearPort.exe` once from the new location repairs HearPort's own startup path (an item disabled in Windows Task Manager stays OS-managed).
- **iPad automatic reconnect**: With **Automatically reconnect** enabled in iPad **Settings**, HearPort reconnects to your paired PC when Wi-Fi or USB comes back, when the app returns to the foreground, or when the PC restarts. Manually disconnecting pauses auto-reconnect for the current app process until you tap connect or run a connection shortcut again.
- **Background recovery & media controls**:
  - During ordinary playback, an eligible transport disconnect requests a single, non-renewing background recovery window of up to **20 seconds** (the OS may revoke it early; it ends on recovery, manual disconnect, auth rejection, or diagnostics/calibration, and only starting playback again grants another window).
  - Lock-screen, Control Center, and headphone media controls (**PC audio**) support play, pause, and stop: play uses the saved route mode and paired PC; pause/stop acts as a manual disconnect and pauses auto-reconnect. Media controls are disabled during diagnostics/calibration, and scrubbing/track-skipping do not apply to a live stream.
  - Audio interruptions resume only when iPadOS permits (`shouldResume`) and playback intent is still active. If media services reset, HearPort rebuilds its audio objects and waits for an explicit play tap, shortcut trigger, or in-app retry (foregrounding or route changes alone will not bypass that wait).
- **Credential protection on rejection**: If an authenticated PC explicitly rejects saved credentials, automatic retries stop without deleting stored credentials so you can retry or re-pair manually.

> [!NOTE]
> An idle iPad app that isn't playing audio can be suspended by iPadOS at any time. Shortcuts provide an entry point to request execution time when an event happens — not an unlimited background daemon. First unlock after reboot, Local Network permission, and USB accessory trust still apply.

---

## Built-in App Shortcuts

After installing a new build, open HearPort once and pair your PC. You will find **7 built-in App Shortcuts** under **Shortcuts → Apps → HearPort** (or via **Settings → Shortcuts and automation** inside the app) — covering automatic, network-only, and USB-only audio playback plus foreground connect, disconnect, status, and trigger logging. Because they ship inside the app bundle, no `.shortcut` file import or iCloud signing is needed.

| Shortcut | Execution Mode | Purpose |
| --- | --- | --- |
| **Play PC audio** | `AudioPlaybackIntent` (metadata marks iPadOS 17.2+) | Primary headless playback entry point; accepts route parameter (**Automatic**, **Network only**, **USB only**) |
| **Play via network** / **Play via USB** | `AudioPlaybackIntent` (iPadOS 17.2+) | Dedicated route-locked audio playback shortcuts |
| **Open and connect** | Foreground `AppIntent` | Explicit entry point when unlocking and opening the app is acceptable |
| **Disconnect PC audio** | Audio intent (iPadOS 17.2+) | Stops playback and pauses auto-reconnect for the current process |
| **Read connection status** | Background intent | Returns a JSON status payload and logs a diagnostic event |
| **Record automation trigger** | Background intent | Writes an automation marker (`automation_stage` / `trigger_marker`) at the start of a chained shortcut |

### Route Selection & Non-Preemption Rules

- **Settings → Playback → Connection mode** persists **Automatic (USB preferred)**, **Network only**, or **USB only**, shared across manual connects, auto-reconnect, and accepted connection shortcuts.
- **Strict route locks**: **USB only** never falls back to Wi-Fi; **Network only** never upgrades to USB. Changing the mode in Settings while connected or connecting re-routes the active session (causing a brief audio pause); changing it while idle only saves the preference. Network calibration always samples LAN without overwriting your playback mode.
- **Reuse without preemption**: Re-triggering the same route reuses an active or pending connection without rebuilding the audio engine. If an incompatible route is active or a diagnostic test is running, the shortcut returns a reason code instead of interrupting.

---

## Recommended Personal Automations

Create two reusable shortcuts in the **Shortcuts** app (or invoke the built-in route actions directly):

1. **HearPort Wi-Fi**: `Play PC audio` with route set to **Network only**
2. **HearPort USB**: `Play PC audio` with route set to **USB only**

Then wire them under **Shortcuts → Automation** (enable **Run Immediately** when supported by your iPadOS version):
- **Wi-Fi** (joining your home/office SSID) → run **HearPort Wi-Fi**
- **Charger** (when connected) → run **HearPort USB** *(note that regular wall chargers also trigger this event, and USB data enumeration can lag a few seconds behind power connection, so an initial `waiting` return does not mean failure)*

If your PC's USB data handshake consistently trails charger power, keep a separate **HearPort USB Delayed Retry** shortcut for comparison:

```text
Repeat 6 times
  ├─ Play via USB
  └─ Wait 5 seconds
```

Because repeated calls reuse an already-established connection, it will not restart the audio engine once connected. Each attempt waits up to ~8 seconds, giving ~78 seconds worst-case. Test the direct USB shortcut first so you know whether retries are actually needed; iOS automation scheduling limits still apply.

> [!TIP]
> **Cold-start testing tip:** When verifying cold-start execution, do **not** put **Record automation trigger** ahead of **Play PC audio** — the marker action wakes the process first and skews cold-start conditions. Keep audible audio playing on your PC during testing so silence isn't mistaken for startup failure.

---

## URL Scheme Foreground Kit

HearPort also registers foreground URLs (succeeding on an unlocked device does not prove background audio shortcuts will succeed; URLs reject host, PIN, credential, and callback parameters):

| URL | Action |
| --- | --- |
| `hearport://connect` | Connect using Automatic route |
| `hearport://connect?route=network` | Connect over Network only |
| `hearport://connect?route=usb` | Connect over USB only |
| `hearport://disconnect` | Disconnect and pause auto-reconnect |
| `hearport://status` | Open connection details |

> [!NOTE]
> The `HearPort-shortcuts` CI artifact includes 5 generated URL shortcut sources (`sources/`) and `signing-results.json`. In the 2026-10-22 macOS CI run, Apple's signing step rejected all 5 because the runner isn't signed into iCloud, so those generated files aren't directly importable. Use the built-in **App Shortcuts** for daily automation, or build a 2-step `URL → Open URLs` shortcut directly on iPad if you want a foreground URL baseline.

---

## On-Device Verification & Log Analysis

After running your test scenarios, export diagnostics once from iPad and summarize stages and timings locally (never commit raw logs containing local network info):

```powershell
python diagnostics/analyze_automation.py <exported-log-path>
```

> [!IMPORTANT]
> An empty summary simply means no automation records were captured — it cannot distinguish whether iPadOS failed to trigger vs. denied scheduling. `received_audio_rendered` means received audio entered the render path (valid PC silence also counts), so always confirm `audible_sound` on the actual device.

<details>
<summary><strong>13-Scenario On-Device Verification Matrix</strong></summary>

Disconnect before each case and test **AudioPlaybackIntent**, **Open and connect**, and **URL** separately, recording trigger method, foreground/lock state, OS prompts, audible sound, and approximate elapsed time:

| Scenario | What to Verify |
| --- | --- |
| App in foreground, PC ready | All entry points connect and produce audio |
| Backgrounded (not force-quit), then locked | Audio intents connect and play without unlocking |
| Triggered after manual force-quit | Whether iPadOS launches the process and runs the action (cannot be inferred from non-quit runs) |
| After iPad reboot & first unlock | Cold start and Keychain credential access |
| After reboot before first unlock | System/Keychain restriction is handled without deleting saved pairing |
| Wi-Fi automation fires before PC turns on | Waiting state recovers while the execution window remains active |
| PC USB cable vs. plain wall charger | Separate data-route behavior from power-only triggers |
| Re-triggering while already connected | Reuses connection with no drop-out or duplicate audio engine |
| Network fluctuation after manual disconnect | No unsolicited auto-reconnect; explicit shortcut restores playback |
| Temporary PC stop / restart | Reconnects once PC returns; normal diagnostic completion does not auto-reopen |
| Brief network drop or USB unplug while locked | Recovers within the 20 s background window on allowed routes; log shows allowance & end reason |
| Lock screen / Control Center / headset controls | Play uses saved mode; stop suppresses auto-recovery; repeated Play doesn't recreate connection |
| Audio interruption & media-services reset | Follows OS `shouldResume`; reset requires explicit playback action and never preempts diagnostics |

</details>

<details>
<summary><strong>Shortcut JSON Results & Log Stage Reference</strong></summary>

- **Shortcut JSON output**: Read via **Quick Look** / **Show Result** or **Get Dictionary from Input** (`result` & `route`). Possible `result` values: `received_audio_rendered`, `engine_started`, `waiting`, `pair_in_app`, `credential_unavailable`, `authentication_rejected`, `audio_failed`, `another_route_active`, `another_request_active`, `test_running`, `cancelled`, `disconnected`.
- **`automation_stage` log events**: Include request ID, PID, OS/build, UI appearance flag, app state, and elapsed durations across `action_entered` → `connection_attempt` → `peer_authenticated` → `session_ready` → `audio_engine_started` → `received_audio_rendered` → `action_returned`.

</details>

### Apple Documentation

- [App Shortcuts](https://developer.apple.com/documentation/appintents/app-shortcuts) · [AudioPlaybackIntent](https://developer.apple.com/documentation/appintents/audioplaybackintent)
- [Personal automations on iPhone or iPad](https://support.apple.com/guide/shortcuts/apde31e9638b/ios) · [Enable or disable a personal automation without asking](https://support.apple.com/guide/shortcuts/apd602971e63/ios)
- [Sign a shortcut on Mac](https://support.apple.com/guide/shortcuts-mac/apd455c82f02/mac) · [Allow USB accessories on iPad](https://support.apple.com/en-us/111806)
