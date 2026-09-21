# Windows onboarding and firewall guidance

The v1 core path uses a manually entered hostname or IP address and UDP port.
Bonjour/DNS-SD is optional product onboarding and is not required for
interoperability.

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
