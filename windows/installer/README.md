# Windows onboarding and firewall guidance

HearPort advertises its network endpoint through the Windows DNS-SD API; iPad
browses `_hearport._udp`. Manual hostname or IP address entry remains available
when local network discovery is blocked or unavailable.

The Windows sender also discovers physically attached iPads through the Apple
Mobile Device service. Install Apple's Windows device support, connect a data
cable, unlock iPad and accept the system trust prompt when needed. Open the
ordinary HearPort app on iPad. The app listens only on loopback TCP `52138` for
usbmux; no inbound LAN TCP firewall rule is needed.

USB forwards encrypted QUIC packets to a separate loopback sender entrance.
Existing certificate pinning and PIN/remembered authentication remain required.
For a remembered PC, an authenticated USB connection takes priority over network
playback. Switching rebuilds the audio stream and clock mapping and can pause
briefly. USB loss reconnects the known network endpoint; manual stop suppresses
automatic playback. Both apps show the physical path separately from the audio
protocol mode. A one-time pairing does not silently become a remembered pairing.

Network tests and environment calibration admit the network path only. Music
and timed diagnostics retain their starting path through report recovery; a
lost path interrupts the run. Ordinary playback considers both paths.

The sender listens on UDP `52137` by default (or the explicitly configured
port). An installer or an administrator onboarding screen may add a narrowly
scoped inbound Windows Firewall rule for the signed HearPort sender executable
and that UDP port. Do not open a broad TCP range, and do not treat a firewall
allow rule as authentication.

The sender must also be provisioned with a certificate usable by MsQuic and
the SHA-256 hash of its current leaf SubjectPublicKeyInfo. The release host
must not start with a missing certificate identity, a global trust-all mode, or
an unauthenticated audio path. `--open-pairing` is an explicit local operation;
it creates a short-lived six-digit PIN and displays it only to the local
operator.

If automatic discovery or Local Network onboarding is unavailable, direct
endpoint entry remains supported. The endpoint, PIN, pair secret, and private
key are never written to the diagnostic log.
