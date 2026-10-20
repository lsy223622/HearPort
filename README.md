# HearPort 0.1.0

HearPort sends Windows PC audio to an iPad over your local network. A USB data
cable is also supported when Apple's Windows device support is installed. For
a paired iPad, USB is preferred when available; disconnecting USB returns
playback to the remembered network connection.

The Windows app is a portable GUI. The iPad app is distributed as an unsigned
IPA. Sign and install the IPA with an Apple-compatible signing tool of your
choice before iPadOS can run it. Signing options have different account,
device, and renewal limits. Keep all files in the Windows ZIP together.

## First use

1. Unpack the Windows ZIP and start `HearPort.exe`.
2. Open HearPort on iPad and select the discovered PC. If discovery is
   unavailable, enter its hostname or IP address in connection setup.
3. On Windows, choose **Pair new iPad** to show a temporary PIN. On iPad, choose
   **Pair and remember** and enter that PIN. The PC credential is stored in
   Windows Credential Manager and the iPad credential in Keychain.
4. For USB, install Apple's Windows device support, connect a data cable,
   unlock the iPad, and accept the system trust prompt if shown. Pairing can
   also be completed over USB. If Apple device support or trust is unavailable,
   use the LAN connection instead.

Windows discovery and audio use the local network; the sender listens on UDP
52137 by default. An administrator may need to allow that UDP port through
Windows Firewall. USB uses Apple's device service and loopback forwarding, so
it does not require an inbound LAN TCP rule. See
[`windows/installer/README.md`](windows/installer/README.md) for connection and
firewall details.

## Playback settings and tests

The iPad's **Playback** settings select Datagram or Reliable stream audio and
set a normal target and maximum total delay. These are playback budget values,
not measured speaker latency. They include transport, processing, and output;
the maximum controls how long an interruption can be tolerated. Changes apply
on the next connection.

**Automatic test and recommendations** first selects one goal: Low latency,
Balanced, or Stability first. It pauses playback and tests random traffic over
LAN, adapting transport, PCM/Opus encoding, bitrate, packet duration and playback
budget. Candidates are repeated and the final settings receive two longer
verification windows before one-click application. Progress includes current
parameters, live gaps, countdown and a changing estimate of remaining steps.
Results remain on iPad; full diagnostic tests and report collection are available
from Windows. Random traffic matches the current constant-bitrate packet load,
reserving codec preparation time; it does not benchmark decoder speed or audio
quality. Recommendations describe the observed network, not future guarantees.

HearPort captures the Windows default output using shared-mode WASAPI Loopback
and sends audio to the iPad. The receiver uses QUIC, local buffering, and audio
output timing to keep playback responsive through ordinary network variation.

## Diagnostics and evidence

Both endpoints retain up to approximately 128 MiB of rotating runtime logs
(16 MiB per file, seven backups). iPad export streams a fixed-length file snapshot
in the background and includes current USB listener/forwarder status.

Diagnostics are stored locally. A log or exported report can contain network
details such as a hostname, IP address, or port; review it before sharing.

The validation matrix records automated, build, and observed device evidence
separately. The short release checklist records distribution checks still to
complete: [`docs/validation-matrix.md`](docs/validation-matrix.md) and
[`docs/release-checklist.md`](docs/release-checklist.md).

The diagnostic panel also provides synthetic compression-load comparisons and
real PCM/Opus music comparisons. The matrices, timings and paired analysis are
documented in [`docs/compression-tests.md`](docs/compression-tests.md).

## Release builds in GitHub Actions

The `Windows Release package` workflow builds and tests Release on Windows,
collects dependency notices and produces `HearPort-windows-release` containing
the portable ZIP, matching source ZIP and SHA-256 manifest. Its vcpkg revision
is pinned. The `iOS receiver package tests` workflow builds and tests the iPad
app and uploads `HearPort-unsigned-ipa`. Run both workflows at the same commit
when preparing a release; download these artifacts as the distribution files.
Both workflows also support manual runs from the Actions page.

## Local development verification

Use Python 3.11+, Rust/Cargo, CMake and a VS 2022 x64 developer shell.
Install `msquic:x64-windows` in vcpkg and set `VCPKG_ROOT` to that checkout.
The separate build directory selects Release MsQuic explicitly:

```powershell
python scripts/fetch_opus.py
cmake -S . -B out/build/windows-release -G "Visual Studio 17 2022" -A x64 `
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
