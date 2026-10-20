# Adaptive client recommendations

## Scope and design

Work in the main checkout. Keep Windows full diagnostic calibration on protocol
version 4. Client quick testing uses negotiated capability 1024 and version 5,
chooses one profile before starting, and retains its result locally. No client
diagnostic recording or report upload is started for that test. A small completion
acknowledgement lets Windows return to ordinary playback service.

Version 5 adds the selected goal and PCM/Opus bitrate/frame duration. Both codecs
use the same timed records and logical 120-frame source units. Random CBR-shaped
traffic matches existing live packet load; Opus collection and 120-frame lookahead
are reflected in capture timestamps, with a 2 ms conversion/decode allowance.
This tests transport suitability, not codec throughput or acoustic latency.

Every load/budget receives four ABBA observations, two per transport. When neither
transport meets the goal, the better measured candidate from the latest block guides
the next adjustment. Valid candidates are compared using worst repeated measurements;
indifference bands use the larger of a fixed tolerance (5 ms age/longest gap,
0.0001 gap ratio) and the sum of observed repeat ranges. Within the band, retain the
configured network transport preference and disclose that the modes performed similarly.
These bands are conservative selection rules, not statistical confidence intervals.
Exploration remains bounded to twelve windows, followed by two longer verification
windows. Detailed local logs retain measurement JSON, parameter JSON, decision
outcome and tolerance policy; normal logs keep completion status.
Large target misses reduce load and increase budget in coarse steps; near the goal,
budget steps shrink toward 5 ms. Successful candidates can challenge with shorter
packets and PCM. No fixed Cartesian matrix is run. Revisited settings or the bounded
exploration count end the search; two longer observations verify one selected
candidate. There is no fixed overall wall-clock cutoff for the quick test.
Repeated observations and independent verification reduce transient selection bias;
sequential network observations do not prove causation or future rare-loss rates.

Show current settings, live gap measurements, previous observation, packet count,
per-window countdown, verification stage and a revised remaining-window range.
Application writes network format, bitrate, packet duration, transport and budget;
USB encoding and transport preferences remain independent. The existing
`hearport.audioTransportMode` preference belongs to the network route; USB uses
`hearport.usbAudio.transport`, defaulting to reliable stream. Incomplete or failing verification cannot
replace the last applicable saved recommendation.

The negotiated audio format has its own UI callback, because ReceiverReady precedes
AudioSetup negotiation. Latency controls combine 5 ms decrement/increment buttons with direct numeric input;
committed values are clamped to the supported range.

## Implementation and validation

1. Add paired native/Swift wire fixtures, adaptive exchange and search regressions.
2. Integrate the existing paced sender and local receiver replay/feedback.
3. Replace the client quick-test entry with one-goal setup and one-result application.
4. Verify native build/CTest; run Swift tests and both release builds in Actions.
5. Check artifacts and document remaining physical-device acceptance separately.

Local Release build and 24 CTest checks passed, including adaptive protocol fixtures,
format/phase preservation, dynamic exchange, and old full-test compatibility.
Actions and physical-device acceptance are recorded in the validation matrix after
their actual results are available.


## Final delivery

- Source `4de8694f96a76537d518556dccff93f849acd149`; Windows Actions 39399070518
  passed 24 CTest and 28 Python checks; iPad Actions 39399056345 passed 194 Swift
  checks and archived unsigned build 170. CodeQL 39399055960 passed.
- Both downloaded source identities, checksums and all 100 packaged Windows file
  hashes verified; the Actions Windows package was started and bound UDP 52137.
- Stability-first application accepts the best valid observed continuity; the two
  threshold profiles require their targets in both final repeats. Failed runs do
  not overwrite an applicable stored result.
- Initial iOS archive caught a Section initializer mismatch, fixed before final
  packaging. Physical-device acceptance remains explicitly pending in the matrix.
