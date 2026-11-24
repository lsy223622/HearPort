# HearPort 0.1.0 Release Checklist

## Distribution Artifacts

Generate both release packages in GitHub Actions from the **same source commit** — local builds are for development verification only, not public distribution:

- **Windows**: `Windows Release package` → `HearPort-windows-release` (`HearPort-*-windows-x64.zip`, `HearPort-*-source.zip`, `SHA256SUMS.txt`)
- **iPad**: `iOS receiver package tests` → `HearPort-unsigned-ipa` (`HearPort-unsigned.ipa`, archive metadata)

*(Public `v0.1.0` tag points to `9927991a5b5987c53ec14b9162a4bc5a6b2c011e`, iPad build **203**.)*

---

## Pre-Distribution Checks

Follow the evidence boundaries in [`validation-matrix.md`](validation-matrix.md) when logging results — CI builds and short spot tests do not substitute for clean-PC or soak verification:

- [ ] **Clean Windows run**: Verify the portable Release ZIP starts and streams audio on a clean Windows 11 PC without development tools installed (requires Windows App Runtime 2.6.5 x64+).
- [ ] **Signed IPA install & LAN flow**: Sign and sideload the unsigned IPA; verify first-run permissions, discovery/manual host entry, LAN pairing, and remembered reconnect.
- [ ] **USB handover**: With Apple Windows device support installed and the iPad trusted, confirm USB pairing, playback, unplug/replug recovery, and fallback to the remembered LAN endpoint.
- [ ] **Finite soak & edge transitions**: Complete a 1–2 hour continuous foreground run and verify silence/recovery, background/lock behavior, route interruptions, and Windows audio-device resets.
- [ ] **Diagnostics privacy check**: Inspect an exported diagnostic report to confirm no private hostnames, IP addresses, or ports are shared unintentionally.

---

## Current Milestone — WinUI 3 Merge (2026-11-16)

- [x] Windows Release and iOS receiver workflows passed on the same merged source. See [`validation-matrix.md`](validation-matrix.md#winui-3-desktop-and-variable-pcm-2026-11-16).
- [ ] Verify downloaded artifact SHA-256 hashes, extract the Windows ZIP on a clean Windows 11 environment with Windows App Runtime 2.6.5 (x64)+, and sign the matching IPA for device installation.

---

<details>
<summary><strong>Historical candidate checklists (2026-10-18 – 2026-10-25)</strong></summary>

*Historical candidate records kept for audit traceability; these are not recurring per-release tasks.*

### Chinese UI font fix (2026-10-25)

- [x] Confirmed missing Segoe UI GDI font-linking in the user's Sandbox with Microsoft YaHei UI installed; direct Chinese glyph queries passed with the corrected font selection.
- [x] Source `caf35c4fd39efdf994e4e198a4688d18b983e8ec`: Windows Actions [40196291192](https://github.com/lsy223622/HearPort/actions/runs/40196291192) passed 26 CTest (Chinese glyph coverage passed without skipping), 29 Python checks, app-local DLL checks, and GUI startup/paint checks; CodeQL [40196290928](https://github.com/lsy223622/HearPort/actions/runs/40196290928) passed. Download hashes and 100 runtime files verified; passed window checks in the same user Sandbox.

### Portable runtime loading fix (2026-10-22)

- [x] Reproduced `0xC0000135` startup failure in a fresh Windows Sandbox with local VC runtime files and no System32 CRT; confirmed MsQuic's System32-only import flag and delay-load fix.
- [x] Source `5a1e5a2fe763ef2a52fafc2e5413649636a1e788`: Windows Actions [39788168226](https://github.com/lsy223622/HearPort/actions/runs/39788168226) and CodeQL [39788187759](https://github.com/lsy223622/HearPort/actions/runs/39788187759) passed; verified hashes, 100 runtime files, app-local module paths, and UDP `52137` startup in Sandbox.
- [ ] iPad build 191 installation and automation device acceptance awaited user AltStore recovery (Windows loader fix requires no iPad update).

### Connection automation candidate (2026-10-22)

- [x] Source `8ba6d9ab9e7335f72a5122b166d66d320f1e0493`: Windows Actions [39748549052](https://github.com/lsy223622/HearPort/actions/runs/39748549052) passed 25 CTest, 28 Python checks, and packaged GUI checks; iPad Actions [39748549005](https://github.com/lsy223622/HearPort/actions/runs/39748549005) passed 221 Swift tests, 4 shortcut/analysis checks, and archived unsigned build 191; CodeQL [39748548777](https://github.com/lsy223622/HearPort/actions/runs/39748548777) passed.
- [x] Verified archive hashes, 100 Windows runtime files, embedded identities, 10 intent/shortcut entry points, and local UDP `52137` startup.
- [x] Addressed delayed old-session stop handling via active session ID/identity gating and path-promotion regression (32 local Python checks passed).
- [x] Generated 5 URL shortcut sources; macOS CI signing was rejected for missing iCloud login (built-in App Shortcuts work without importing `.shortcut` files).
- [ ] On-device shortcut discovery, background/locked/force-quit triggers, Wi-Fi/charger automation, delayed USB recognition, and audible confirmation ([connection-automation.md](connection-automation.md)).
- [ ] Normal PC stop/restart recovery, manual-disconnect pause, credential refusal retention, and re-pairing.

### Pairing safety & interaction recovery candidate (2026-10-21)

- [x] Source `e59628ab0f34fd6a8f9a8293d5c5d20e4ed03078`: Windows Actions [39593250742](https://github.com/lsy223622/HearPort/actions/runs/39593250742) (24 CTest, 28 Python, GUI smoke), iPad Actions [39593250802](https://github.com/lsy223622/HearPort/actions/runs/39593250802) (216 Swift, build 184), CodeQL [39593251795](https://github.com/lsy223622/HearPort/actions/runs/39593251795) passed.
- [ ] Bidirectional connected unpair, offline unpair rejection, credential retention across interruptions, manual address/delay edits, in-page PC selection, and audio retry feedback.

### Independent route latency candidate (2026-10-21)

- [x] Menu summary follow-up: Actions [39586833423](https://github.com/lsy223622/HearPort/actions/runs/39586833423) (214 Swift, build 183) & CodeQL passed.
- [x] Source `3370ee2c55083328c1d0d3c66ebc111a674e7af1`: iPad Actions [39583024058](https://github.com/lsy223622/HearPort/actions/runs/39583024058) (214 Swift, build 182) & CodeQL [39583022167](https://github.com/lsy223622/HearPort/actions/runs/39583022167) passed.
- [ ] Verify encoding/delay summaries (light & dark), network budget upgrade migration, independent route budgets, USB handover, and network-only recommendation updates.

### iPad row actions & launch layout candidate (2026-10-21)

- [x] Source `2bebb701a278d94fbbc6876b6397777021e18c50`: iPad Actions [39544315416](https://github.com/lsy223622/HearPort/actions/runs/39544315416) (211 Swift, build 181) & CodeQL passed; dark-mode startup layout screenshots confirmed by user; recorded several-hour locked-idle continuation observation.
- [ ] Full-row tap target whitespace, numeric connected IP/port on LAN, and light-mode appearance.

### Automatic-test startup candidate (2026-10-21)

- [x] Source `ea1683110ccd80181d6205716bc35b163c8e95c4`: Windows Actions [39478078837](https://github.com/lsy223622/HearPort/actions/runs/39478078837) (24 CTest, 28 Python, GUI), iPad Actions [39478078798](https://github.com/lsy223622/HearPort/actions/runs/39478078798) (209 Swift, build 180), CodeQL passed.
- [ ] Quick test startup with/without USB, ordinary music startup, retained-report recovery, compact pairing form, and >2,000-entry log totals.

### Connection actions & repaint candidate (2026-10-21)

- [x] Windows `3e8543a8bcea881d7bfb066a5080c6f9932af8c0` ([39473183485](https://github.com/lsy223622/HearPort/actions/runs/39473183485)) & iPad `9f45c551e44456996aaf242d425d32f28a11e1f2` ([39473786709](https://github.com/lsy223622/HearPort/actions/runs/39473786709), 205 Swift, build 179) & CodeQL passed.
- [ ] Context-menu testing with/without pairing, wrong-PIN recovery, local unpair, keep-awake, and Windows theme/DPI changes.

### Earlier October 2026 candidates (2026-10-18 – 2026-10-20)

- **iPad menu presentation (`d8977fa9d6b3bb9946baa1f1724cac3b1cbc28ec`)**: Actions [39440168724](https://github.com/lsy223622/HearPort/actions/runs/39440168724) (204 Swift, build 177) & CodeQL passed.
- **Transport comparison & settings (`2571b1b29a160617d71a087b8c48018687269c3a`)**: Windows [39425040006](https://github.com/lsy223622/HearPort/actions/runs/39425040006) & iPad [39425055397](https://github.com/lsy223622/HearPort/actions/runs/39425055397) (24 CTest, 28 Python, 204 Swift, build 176) & CodeQL passed; ~4 MiB / ~128 MiB log pruning verified.
- **USB recovery & runtime log (`82bdaee35a7d32a72a6edfabc3abe56491e40bd8`)**: Windows [39417771470](https://github.com/lsy223622/HearPort/actions/runs/39417771470) & iPad [39417768450](https://github.com/lsy223622/HearPort/actions/runs/39417768450) (197 Swift, build 173) & CodeQL passed.
- **Adaptive client recommendations (`4de8694f96a76537d518556dccff93f849acd149`)**: Windows [39399070518](https://github.com/lsy223622/HearPort/actions/runs/39399070518) & iPad [39399056345](https://github.com/lsy223622/HearPort/actions/runs/39399056345) (194 Swift, build 170) & CodeQL passed.
- **Capture-silence recovery fix**: Actions [39392343378](https://github.com/lsy223622/HearPort/actions/runs/39392343378) (187 Swift) & CodeQL passed.
- **Configurable live compression (`21b3848312e16aa652c55704991839502698feee`)**: Windows [39386364549](https://github.com/lsy223622/HearPort/actions/runs/39386364549) & iPad [39386215008](https://github.com/lsy223622/HearPort/actions/runs/39386215008) (186 Swift, build 165) & CodeQL passed.
- **Compression test candidate (`53de0cd7eefa0afd9e63f549b50439c023172b51`)**: Windows [39360465692](https://github.com/lsy223622/HearPort/actions/runs/39360465692) & iPad [39360464729](https://github.com/lsy223622/HearPort/actions/runs/39360464729) (23 CTest, 28 Python, 179 Swift, build 162) & CodeQL passed; 32 USB & 32 LAN physical music rounds completed on build 162.
- **Baseline (`35f00d8c5adfdb6e27d724daaff6677b0172abfb`, 2026-10-18)**: Windows [39052133439](https://github.com/lsy223622/HearPort/actions/runs/39052133439) (22/22 CTest, 6/6 package checks) & iPad [39052135647](https://github.com/lsy223622/HearPort/actions/runs/39052135647) (156 Swift, build 158) passed; USB & weak 2.4 GHz Wi-Fi playback observed on iPad Pro 11-inch (2020).

</details>
