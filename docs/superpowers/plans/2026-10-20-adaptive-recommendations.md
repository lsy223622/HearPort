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

The search starts with ABBA transport baselines, then repeats each changed setting.
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
USB format preferences remain independent. Incomplete or failing verification cannot
replace the last applicable saved recommendation.

The negotiated audio format has its own UI callback, because ReceiverReady precedes
AudioSetup negotiation. Latency controls step by 5 ms to remain reachable from
recommendations that end in 5.

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
