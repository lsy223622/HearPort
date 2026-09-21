# HearPort v1 security implementation

The security boundary is split into a small platform-independent policy layer
and one maintained RFC 9382 provider:

- `security/spake2-provider/` is a Rust FFI library built from
  `pakery-crypto`/`pakery-spake2` 0.4.0 with the P-256, SHA-256, HKDF and HMAC
  suite enabled. It is the only implementation in this repository that does
  P-256 group arithmetic. The C++ and Swift layers do not contain curve
  formulas.
- `security/include/hearport/security/pairing.h` contains PIN validation,
  SPKI identity construction, constant-time comparison, the explicit two-minute
  pairing window and the SPAKE2 provider wrapper.
- `security/include/hearport/security/remembered_auth.h` contains the
  remembered-authentication HMAC challenge state and staged trust material.
- `windows/src/credential_store.cpp` stores the fixed credential record as a
  DPAPI-protected Windows Credential Manager blob. The pair secret is never
  written as a normal configuration value.
- `ios/HearPortReceiver/Sources/HearPortReceiver/KeychainStore.swift` stores
  `{windows_spki_sha256, peer_id, pair_secret}` as one Keychain item using
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.

The provider build is added by `security/CMakeLists.txt` when `cargo` is
available. If it is unavailable, the C++ security API returns failure and the
native security test verifies that behavior. There is no hash-only, plain-PIN,
or “trust all certificates” fallback. The Swift default is
`UnavailableSpake2Provider`; a release iPad application must link the same
Rust provider as an Apple-platform static library/XCFramework and compile the
`HEARPORT_SPAKE2_PROVIDER` bridge before enabling pairing.

## Profile details

The provider and the Python/Swift vectors implement the exact v1 profile:

```text
digest = SHA256(ASCII("HearPort-SPAKE2-v1") || 0x00 || ASCII(PIN))
w      = (OS2IP(digest) mod (P256_order - 1)) + 1

idA = ASCII("HearPort-Windows-v1") || 0x00 || SHA256(DER SubjectPublicKeyInfo)
idB = ASCII("HearPort-Receiver-v1")

HMAC-SHA256(pair_secret,
            ASCII("HearPort-Auth-v1") || nonce32 || windows_spki_sha256)
```

The provider sends and validates 65-byte SEC1 uncompressed points, rejects
invalid/identity points, generates fresh ephemeral scalars from the OS-backed
RNG, and verifies both RFC 9382 confirmation MACs before the caller can treat
the exchange as authenticated. The Rust tests include the RFC 9382 P-256
Appendix B vector and a malformed-point failure case.

## TLS policy

The iPad QUIC transport requires an explicit `TLSIdentityPolicy` at connect
time. `.pairing` is a user-selected provisional flow: it extracts the leaf
certificate's DER SubjectPublicKeyInfo, reports its SHA-256 to the pairing
state, and allows the TLS channel only for that explicit PAKE attempt. It does
not persist the hash by itself. `.remembered` compares the current SPKI hash
to the Keychain pin and fails the TLS handshake on mismatch. TLS resumption and
TLS tickets are disabled for this v1 transport, so application authentication
never relies on 0-RTT data.

The Windows MsQuic server disables server resumption and only exposes the one
client-initiated bidirectional control stream plus QUIC DATAGRAM capability.
Audio remains gated by `SessionState::MarkAuthenticated()` and a matching
`StartStreamAck`; no authenticated state is inferred from a successful TLS
handshake alone.

## Failure and persistence rules

- A PIN is six ASCII decimal bytes; leading zeroes are valid.
- One shared `PairingWindow` allows five failures. The fifth failure closes the
  window immediately, so a sixth attempt is rejected until the user opens a
  new window.
- A remembered nonce is consumed on every verification attempt, including a
  failed attempt. Peer-id mismatch, wrong secret, wrong MAC and replay all
  return authentication failure and do not start a new pairing flow.
- Credentials are staged in memory until PAKE confirmation succeeds. A failed
  pairing clears staged material; a one-time flow never commits it.
- The TLS SPKI is a pin, not a display name, mDNS name, certificate serial, or
  IP address. A changed SPKI requires explicit re-pairing.
