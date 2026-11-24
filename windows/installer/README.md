# Windows Setup & Troubleshooting

> [!IMPORTANT]
> **Prerequisites:** HearPort requires **Windows 11 (x64)** and [Windows App Runtime 2.6.5 (x64)](https://aka.ms/windowsappsdk/2.6/2.6.5/windowsappruntimeinstall-x64.exe) or later. When extracting the portable Release ZIP, keep `HearPort.exe` and all bundled DLLs (including `msquic.dll` and the VC++ runtime DLLs) in the **same folder**.

For iPad installation, quick start, and source build instructions, see the [Main README](https://github.com/lsy223622/HearPort/blob/main/README.md) or [Building from Source](https://github.com/lsy223622/HearPort/blob/main/README.md#local-development-verification).

---

## Discovery & First-Time Pairing

1. **Discover your PC**  
   HearPort advertises itself on the local network over Windows DNS-SD (`_hearport._udp`). Open HearPort on your iPad and pick your PC from the list. If discovery or Local Network permission is unavailable, enter the PC's hostname or IP address manually.

2. **Pair with a PIN**  
   On the Windows **Overview** tab, click **Pair new iPad** to show a temporary 6-digit PIN. On your iPad, choose **Pair and remember** and enter the PIN.
   - Pairing works identically over **LAN** or **USB** and enforces the same certificate pinning and SPAKE2 authentication.
   - Choosing a one-time connection does not save credentials on either device.

3. **Identity & Certificate Reuse**  
   The GUI automatically generates and reuses a local TLS certificate. Replacing or deleting that certificate changes the PC's cryptographic identity and requires re-pairing your iPad.

---

## System Tray Controls

- **Left-click**: Open quick status, sender controls, and the iPad volume slider (shown whenever the connected iPad reports its system volume; scroll to step by 5%, or click the speaker icon to mute).
- **Double-click**: Jump straight to the **Overview** window.
- **Right-click**: Open the context menu (**Open HearPort** / **Exit**).

---

## USB Audio Setup

To stream over a USB cable:

1. Install **Apple's Windows device support** (bundled with iTunes or the Apple Devices app — installed separately from HearPort).
2. Connect a data-capable USB cable, unlock your iPad, and accept the **Trust This Computer** prompt if shown.
3. Open the normal **HearPort** app on your iPad.

### How USB Mode Behaves

- **Loopback forwarding**: The iPad app listens only on `127.0.0.1:52138` for `usbmux` traffic and forwards encrypted QUIC packets to a dedicated loopback sender entrance on Windows. No inbound LAN TCP firewall rule is required, and USB does not bypass certificate pinning or pairing.
- **Automatic route switching**: In **Automatic** connection mode, an authenticated USB connection to a remembered PC automatically takes priority over LAN. Switching routes rebuilds the audio stream and clock mapping, so a brief pause is normal.
- **Fallback & manual stop**: Unplugging USB automatically falls back to your remembered LAN endpoint. Manually stopping playback pauses automatic reconnect until you start again.
- **If Apple device support isn't available**: Pairing and daily playback work fine over LAN without installing Apple's drivers.

> [!NOTE]
> Network benchmarks and automatic parameter recommendations always run over LAN only. Music tests and timed diagnostics stay pinned to whichever route they started on (losing that route interrupts the test).

---

## Network & Firewall

- **Default port**: HearPort listens on **UDP `52137`** by default (or whichever custom port you configure in **Settings**).
- **Firewall rule**: If Windows Firewall blocks discovery or streaming, allow `HearPort.exe` on that UDP port for your local network profile (Private). Do **not** open a broad TCP port range, and remember that a firewall rule is never a substitute for authentication.

---

## Logs & Privacy

- **Retention limits**: Ordinary logs keep ~4 MiB on disk (1 MiB active + 3 backups). Turning on detailed logging expands this to ~128 MiB (16 MiB active + 7 backups).
- **Diagnostic exports**: Explicit diagnostic sessions write separate reports to the local report folder — clean up old report folders manually when you no longer need them.
- **Before sharing**: Logs and reports stay local, but they can contain local hostnames, IP addresses, and port numbers. Review them before posting publicly.
