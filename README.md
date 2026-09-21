# HearPort

HearPort turns an iPad into a low-latency speaker for a Windows PC over a
local network. The v1 implementation follows the design and interoperability
documents under `plans/`:

- Windows captures shared-mode WASAPI Loopback audio;
- audio is normalized to 48 kHz, stereo, Float32LE PCM;
- 120 frames are sent in each 968-byte QUIC DATAGRAM application payload;
- iPad uses one reliable control stream plus QUIC DATAGRAM audio, a jitter
  buffer, silence concealment, a render ring, and slow buffer-fill drift
  correction;
- release connections use the v1 pairing/remembered-authentication flow.

## Repository layout

- `protocol/` — canonical protobuf schema and fixed wire constants;
- `core/` — platform-independent wire, ordering, buffering, and drift code;
- `windows/` — WASAPI and MsQuic sender;
- `ios/HearPortReceiver/` — Swift/iPad receiver package and audio lifecycle;
- `security/` — pairing and remembered credentials;
- `tests/` — deterministic reference/conformance tests;
- `docs/` — implementation plan, progress ledger, and validation matrix.

## Current build boundary

The Python reference suite can run on Windows without native audio or Apple
toolchains:

```powershell
python -m unittest discover -s tests -v
```

Native Windows builds require CMake, a C++20 compiler, Rust/Cargo for the
maintained SPAKE2 provider, and MsQuic. The iPad package requires
macOS/Xcode/iPadOS SDKs plus an Apple-platform build of that provider.
Reference tests do not
prove WASAPI capture, QUIC interoperability, iPad audio output, background
behavior, or real Wi-Fi stability; those checks are tracked separately in
`docs/validation-matrix.md`.

## Manual v1 path

The Windows sender requires both the certificate SHA-1 used by MsQuic and the
SHA-256 hash of the current leaf certificate's DER SubjectPublicKeyInfo. The
minimal local operator flow is:

```powershell
hearport_sender.exe --cert-sha1=<40 hex characters> `
  --cert-spki-sha256=<64 hex characters> --open-pairing
```

The displayed six-digit PIN is entered in the iPad's “Pair new PC” form. A
successful pair stores the receiver credential in Windows Credential Manager
protected with DPAPI and in the iPad Keychain. Later connections use the
remembered mode and require the pinned SPKI plus a fresh HMAC challenge.

Firewall and optional discovery guidance is in `windows/installer/README.md`;
the evidence boundary for native and real-device validation is in
`docs/validation-matrix.md`.
