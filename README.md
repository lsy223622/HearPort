# HearPort 0.1.0

HearPort sends Windows PC audio to an iPad over your local network. A USB data
cable is also supported when Apple's Windows device support is installed. In
Automatic connection mode, a paired iPad prefers USB when available and returns
to the remembered network connection when USB disconnects.

The portable WinUI 3 app requires Windows 11 and
[Windows App Runtime 2.6.5 (x64)](https://aka.ms/windowsappsdk/2.6/2.6.5/windowsappruntimeinstall-x64.exe)
or later. Keep all files in the Windows ZIP together. The iPad app is distributed
as an unsigned IPA. Sign and install the IPA with an Apple-compatible signing
tool before iPadOS can run it. Signing options have different account, device,
and renewal limits.

## First use

1. Unpack the Windows ZIP and start `HearPort.exe`.
2. Open HearPort on iPad and select the discovered PC. If discovery is
   unavailable, enter its hostname or IP address in connection setup.
3. On the Windows **Overview** page, choose **Pair new iPad** to show a temporary
   PIN. On iPad, choose **Pair and remember** and enter that PIN. The PC
   credential is stored in Windows Credential Manager and the iPad credential
   in Keychain.
4. For USB, install Apple's Windows device support, connect a data cable,
   unlock the iPad, and accept the system trust prompt if shown. Pairing can
   also be completed over USB. If Apple device support or trust is unavailable,
   use the LAN connection instead.

Windows discovery and audio use the local network; the sender listens on UDP
52137 by default. An administrator may need to allow that UDP port through
Windows Firewall. USB uses Apple's device service and loopback forwarding, so
it does not require an inbound LAN TCP rule. See `INSTALL.md` in the Windows ZIP
or the [Windows onboarding guide](https://github.com/lsy223622/HearPort/blob/main/windows/installer/README.md)
for connection and firewall details.

Daily reconnect behavior, iPad App Shortcuts, the foreground URL shortcut kit
and the on-device automation verification matrix are documented in
the [connection automation guide](https://github.com/lsy223622/HearPort/blob/main/docs/connection-automation.md).

## Windows tray

Click the tray icon for connection status, sender controls and shortcuts to
**Overview** and **Settings**. Double-click it to go straight to **Overview**.
When the connected iPad reports its system volume, the tray and **Overview**
show a volume slider. In the tray, click the speaker to toggle mute or scroll
over the slider to adjust the volume by 5 percentage points per notch.

## Playback settings and tests

The iPad's **Playback** settings contain separate **Network audio** and **USB audio**
pages for transport, encoding, normal target and maximum total delay. Each route
keeps its own settings and uses them when connecting or switching routes.
Both routes initially use a 50 ms target and 100 ms maximum; upgrading preserves
the previous shared budget for the network route. These are playback budget values,
not measured speaker latency. They include transport, processing, and output;
the maximum controls how long an interruption can be tolerated. Changes apply
on the next connection.

**Automatic test and recommendations** first selects one goal: Low latency,
Balanced, or Stability first. Long-press an available PC on the iPad homepage to
start; an unpaired PC asks for its pairing PIN first. It pauses playback and tests random traffic over
LAN, adapting transport, PCM/Opus encoding, bitrate, packet duration and playback
budget. Each load/budget compares both transports twice in ABBA order; differences
within a conservative repeat-variation band retain the existing transport preference.
The final settings receive two longer
verification windows before one-click application. Progress includes current
parameters, live gaps, countdown and a changing estimate of remaining steps.
Normal playback reconnects automatically when testing finishes. Results remain on iPad;
full diagnostic tests and report collection are available
from Windows. Random traffic matches the current constant-bitrate packet load,
reserving codec preparation time; it does not benchmark decoder speed or audio
quality. Applying a recommendation updates network settings only. Recommendations
describe the observed network, not future guarantees.

The same long-press menu can remove the iPad's saved pairing. Windows provides
**Unpair iPad** on **Overview**. This removes its saved credential and ends
the connection. When connected, either action also sends an authenticated,
best-effort unpair notice to the other endpoint. An offline peer cannot receive
that notice. Explicit remembered-authentication rejection stops automatic retries
without deleting saved credentials; timeouts and ordinary connection failures
also preserve them. The iPad's
**Keep screen awake** setting applies while HearPort is in the foreground;
automatic tests also keep the screen awake while running.

HearPort uses WASAPI Process Loopback by default and excludes its own process
tree. This captures app audio across output devices before their master volume
or mute settings. Individual app volume settings still affect the mix. If
Process Loopback cannot start, HearPort uses the Windows default output device.
Choose **Settings → Audio capture → Default output device** to use that source
explicitly. Its captured level can follow Windows output volume, depending on
the device. Changing the selection restarts the sender. The command-line sender
accepts `--capture=process` (default) or `--capture=endpoint`.

In Windows **Settings**, the **PCM sample rate limit (Hz)** and **PCM bit depth
limit** fields show the default output device's format as placeholders. Leave a
field empty to follow the system value within HearPort's supported range. Enter
a value to cap that setting. For example, with Windows at 48 kHz and 24 bit, a
16-bit limit sends 48 kHz / 16-bit stereo PCM. These limits apply to ordinary PCM
playback with a receiver that supports variable PCM. Opus keeps its own settings,
and receivers without variable PCM support use the 48 kHz / Float32 format.

The receiver uses QUIC, local buffering, and audio
output timing to keep playback responsive through ordinary network variation.

## Diagnostics and evidence

Both endpoints retain approximately 4 MiB of ordinary runtime logs (1 MiB per
file, three backups). Detailed logging increases this to approximately 128 MiB
(16 MiB per file, seven backups); switching it off prunes older and oversized files.
Detailed iPad logs include each recommendation observation, parameters and selection
outcome for manual export. iPad export streams a fixed-length file snapshot
in the background and includes current USB listener/forwarder status.
The diagnostics page shows the recent in-memory preview count and the total
size of retained log files. The 2,000-entry preview does not limit file logging
or export; its displayed statistics refresh while the page is open.

Diagnostics are stored locally. A log or exported report can contain network
details such as a hostname, IP address, or port; review it before sharing.

The validation matrix records automated, build, and observed device evidence
separately. The [release checklist](https://github.com/lsy223622/HearPort/blob/main/docs/release-checklist.md)
tracks distribution checks. See the [validation matrix](https://github.com/lsy223622/HearPort/blob/main/docs/validation-matrix.md)
for the underlying results.

The diagnostic panel also provides synthetic compression-load comparisons and
real PCM/Opus music comparisons. The matrices, timings and paired analysis are
documented in the [compression test guide](https://github.com/lsy223622/HearPort/blob/main/docs/compression-tests.md).

## Release builds in GitHub Actions

The `Windows Release package` workflow builds and tests Release on Windows,
collects dependency notices and produces `HearPort-windows-release` containing
the portable ZIP, matching source ZIP and SHA-256 manifest. Its vcpkg revision
is pinned. The `iOS receiver package tests` workflow builds and tests the iPad
app and uploads `HearPort-unsigned-ipa`. Run both workflows at the same commit
when preparing a release; download these artifacts as the distribution files.
Both workflows also support manual runs from the Actions page.

## Local development verification

For implementation details, see the [wire protocol](https://github.com/lsy223622/HearPort/blob/main/protocol/README.md),
[pairing and authentication](https://github.com/lsy223622/HearPort/blob/main/docs/security-implementation.md), and
[validation matrix](https://github.com/lsy223622/HearPort/blob/main/docs/validation-matrix.md).

Use Python 3.11+, Rust/Cargo 1.87+, CMake and a VS 2022 x64 developer shell.
Install `msquic:x64-windows` in vcpkg and set `VCPKG_ROOT` to that checkout.
Install the Windows App Runtime linked above and the Windows SDK C++/WinRT
tools. With `nuget.exe` available, generate the WinUI projection before
configuring the Release build.

```powershell
nuget install Microsoft.Web.WebView2 -Version 1.0.3719.77 -OutputDirectory out/winui -NonInteractive
$webViewMetadata = Get-ChildItem out/winui -Recurse -Filter Microsoft.Web.WebView2.Core.winmd | Select-Object -First 1
./scripts/generate_winui_projection.ps1 -OutputDir "$PWD/out/winui/projection" -WebViewMetadata $webViewMetadata.FullName
python scripts/fetch_opus.py
cmake -S . -B out/build/windows-release -G "Visual Studio 17 2022" -A x64 `
  "-DHEARPORT_WINUI_PROJECTION_DIR=$PWD/out/winui/projection" `
  "-DCMAKE_TOOLCHAIN_FILE=$env:VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake" `
  "-DHEARPORT_MSQUIC_LIBRARY=$env:VCPKG_ROOT/installed/x64-windows/lib/msquic.lib" `
  "-DHEARPORT_MSQUIC_DLL=$env:VCPKG_ROOT/installed/x64-windows/bin/msquic.dll"
cmake --build out/build/windows-release --config Release --parallel 4
ctest --test-dir out/build/windows-release -C Release --output-on-failure
python scripts/collect_notices.py --output-dir out/release-notices `
  --msquic-copyright "$env:VCPKG_ROOT/installed/x64-windows/share/msquic/copyright"
python scripts/package_release.py --build-dir out/build/windows-release --output-dir out/release `
  --notices-dir out/release-notices --runtime-dir "$env:VCToolsRedistDir/x64/Microsoft.VC143.CRT"
```

Local packages are for development verification. Commit the sources before packaging. Run the existing `iOS receiver
package tests` GitHub Actions workflow at that commit to create the unsigned
IPA with its bundled license notices. Add `--ipa <path-to-ipa>` to the package
command to include that exact commit's IPA in the release output. The script
creates a portable ZIP, matching source ZIP and `SHA256SUMS.txt`; it rejects
Debug runtime dependencies, missing runtime DLLs, mismatched versions and
existing output files. The app-local VC runtime DLLs come from the developer
shell's redistributable directory, not from the developer machine's System32.
