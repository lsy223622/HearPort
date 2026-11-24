# HearPort v1 Security Architecture

HearPort keeps its cryptographic surface compact by separating platform-independent policy from a single maintained RFC 9382 SPAKE2 provider:

| Layer | Location | Responsibility |
| --- | --- | --- |
| **SPAKE2 Provider** | `security/spake2-provider/` | Rust FFI library (`pakery-crypto` / `pakery-spake2` `0.4.0`) handling all P-256 group arithmetic, SHA-256, HKDF, and HMAC. Neither C++ nor Swift implements elliptic-curve formulas. |
| **Pairing Policy** | `security/include/hearport/security/pairing.h` | PIN format validation, SPKI identity construction, constant-time comparison, 2-minute pairing window, and SPAKE2 wrapper. |
| **Remembered Auth** | `security/include/hearport/security/remembered_auth.h` | Nonce-based HMAC challenge state and staged trust material. |
| **Windows Storage** | `windows/src/credential_store.cpp` | Stores the fixed credential record as a DPAPI-protected blob in Windows Credential Manager (never in plain config files). |
| **iPad Storage** | `ios/HearPortReceiver/Sources/HearPortReceiver/KeychainStore.swift` | Stores `{windows_spki_sha256, peer_id, pair_secret}` as a single Keychain item with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. |

> [!IMPORTANT]
> **Fail-closed build rule:** `security/CMakeLists.txt` compiles the Rust provider whenever `cargo` is available; if missing, the C++ security API fails closed (verified by `hearport_security_tests`). On Swift, the default is `UnavailableSpake2Provider` — release iPad builds must link the Rust provider static library and compile with `HEARPORT_SPAKE2_PROVIDER` enabled. There is **no** plain-PIN, hash-only, or "trust all certificates" fallback.

---

## Cryptographic Profile (v1)

```text
digest = SHA256(ASCII("HearPort-SPAKE2-v1") || 0x00 || ASCII(PIN))
w      = (OS2IP(digest) mod (P256_order - 1)) + 1

idA = ASCII("HearPort-Windows-v1") || 0x00 || SHA256(DER SubjectPublicKeyInfo)
idB = ASCII("HearPort-Receiver-v1")

HMAC-SHA256(pair_secret,
            ASCII("HearPort-Auth-v1") || nonce32 || windows_spki_sha256)
```

- Points are exchanged as **65-byte SEC1 uncompressed P-256 points**, rejecting invalid or identity points.
- Ephemeral scalars come from the OS-backed RNG, and **both RFC 9382 confirmation MACs** are verified before treating pairing as authenticated.
- Rust unit tests cover the RFC 9382 P-256 Appendix B vector and malformed-point rejection.

---

## TLS & Session Gating Policy

- **Explicit TLS identity policy**: The iPad QUIC transport requires `TLSIdentityPolicy` at connect time:
  - `.pairing` — User-initiated provisional flow. Extracts the leaf certificate's DER SPKI SHA-256 for that explicit PAKE attempt only; never persists the hash by itself.
  - `.remembered` — Compares the peer's SPKI SHA-256 against the Keychain-pinned hash and aborts the TLS handshake on mismatch.
- **No 0-RTT or resumption**: Both iPad and Windows MsQuic disable TLS session resumption and session tickets.
- **Stream boundaries & audio gating**: The MsQuic server allows only one client-initiated bidirectional control stream plus QUIC `DATAGRAM` frames. Audio remains gated behind `SessionState::MarkAuthenticated()` and a matching `StartStreamAck` — a successful TLS handshake alone never unlocks audio.

---

## Rate Limiting, Replay & Persistence Rules

- **PIN format**: Exactly 6 ASCII decimal digits (leading zeroes are valid).
- **Pairing window**: A single shared `PairingWindow` remains open for ~2 minutes and allows at most **5 failed attempts** — the 5th failure closes the window immediately until the user explicitly opens a new one.
- **One-shot challenges**: Remembered nonces are consumed on **every** verification attempt, including failures. Peer-ID mismatches, wrong secrets, bad MACs, and replays all fail authentication without falling back into pairing.
- **Staged trust**: Credentials stay staged in memory until PAKE confirmation succeeds. Failed pairing wipes staged material; one-time connections never persist trust.
- **Key-pinned identity**: Trust is pinned to the TLS certificate's SPKI SHA-256 — not display name, Bonjour name, serial number, or IP address. Changing the PC certificate requires re-pairing.

---

## Dependency security and reproducible builds

- **2026-10-26 advisory patch**: Updated `crypto-bigint` (`0.7.5` → `0.7.9`, addressing [RUSTSEC-2026-0387](https://rustsec.org/advisories/RUSTSEC-2026-0387.html)) and `ctutils` (`0.4.2` → `0.4.5`, addressing [RUSTSEC-2026-0385](https://rustsec.org/advisories/RUSTSEC-2026-0385.html)) in the 47-package `Cargo.lock` (`0.7.6` was yanked; the patched releases set the provider MSRV to **Rust 1.87**). No curve, protocol, KDF, or FFI signatures changed.
- **Reachability & scope**: `cargo tree --locked -e features -i crypto-bigint` confirms production reachability via `pakery-crypto` (`0.4.0`), `p256` (`0.14.0`), `elliptic-curve` (`0.14.1`), and `primefield` (with `hybrid-array`, `rand_core`, `subtle`, `zeroize` enabled on `crypto-bigint`, and `subtle` on `ctutils`). Neither x64 Windows nor arm64 iOS exercises the advisory's 32-bit-only `u128` case, and functional tests do not claim machine-code constant-time proof.
- **Reproducible CI builds**: CMake invokes `cargo build --locked --release` tracking both `Cargo.toml` and `Cargo.lock`. The iOS workflow builds `--locked --release --target aarch64-apple-ios` and `-force_load`s the resulting static archive. Neither workflow caches or commits prebuilt Rust artifacts (Windows caches vcpkg only), and third-party dependency notices are generated directly from the locked target graph.
