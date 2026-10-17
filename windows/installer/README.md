# Windows onboarding and firewall guidance

HearPort for Windows is distributed as a portable Release ZIP. Unpack it and
start `HearPort.exe`; first-use and iPad distribution steps are in the root
[`README.md`](../../README.md).

HearPort advertises its network endpoint through Windows DNS-SD; iPad browses
`_hearport._udp`. Select the discovered PC in the iPad app. If discovery or
Local Network access is unavailable, enter the PC hostname or IP address
manually.

For first pairing, choose **Pair new iPad** in the Windows app and enter the
shown temporary PIN on iPad using **Pair and remember**. Pairing over LAN or
USB uses the same certificate pinning and authentication. A one-time
connection does not create a remembered credential.

## USB connection

Install Apple's Windows device support, connect a data cable, unlock the iPad,
and accept the iPad's trust prompt if shown. Open the ordinary HearPort app on
iPad. It listens only on loopback TCP `52138` for usbmux; no inbound LAN TCP
firewall rule is needed. USB forwards encrypted QUIC packets to a separate
loopback sender entrance and does not bypass certificate pinning or pairing.

For a remembered PC, an authenticated USB connection takes priority over
network playback. Switching rebuilds the audio stream and clock mapping and may
pause briefly. When USB disconnects, the iPad reconnects to the known network
endpoint; stopping playback manually suppresses automatic playback. Both apps
show the physical path separately from the audio transport mode. If Apple
device support or system trust is unavailable, playback and pairing can use
the LAN route.

## Network and firewall

The sender listens on UDP `52137` by default, or the explicitly configured
port. If Windows Firewall blocks the connection, allow the HearPort executable
on that UDP port for the applicable local network profile. Do not open a broad
TCP range, and do not treat a firewall rule as authentication.

Network tests and automatic parameter recommendations use the network path only. Music
tests and timed diagnostics keep their starting path while reports are
collected; a lost route interrupts the run. Ordinary playback considers both
paths and prefers authenticated USB when it is available.

The GUI creates and reuses its local connection certificate automatically.
Replacing its certificate changes its identity and requires pairing again.

Diagnostics are stored locally. Logs and exported reports can include network
details such as a hostname, IP address, or port. Review an export before
sharing it.

Ordinary Windows logs retain at most 4 MiB per file plus three backups.
Explicit diagnostic sessions retain separate local reports; remove reports you
no longer need from the report folder. The ZIP includes the required VC runtime
DLLs; Apple device support remains a separate prerequisite for USB.
