"""Run the receiver's production playback path with a virtual clock in a temporary package."""
import shutil
import sys
import os
from pathlib import Path


def replace_once(text, before, after):
    if text.count(before) != 1:
        raise ValueError(f'playback insertion point changed: {before}')
    return text.replace(before, after)


def empty_function(text, signature):
    start = text.index(signature) + len(signature)
    end, depth = start, 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[:start] + '}' + text[end:]


def prepare(source, destination):
    if destination.exists():
        raise ValueError('offline destination must be new')
    shutil.copytree(source, destination, ignore=shutil.ignore_patterns('.build', '.swiftpm'))
    directory = destination / 'Sources/HearPortReceiver'
    path = directory / 'QuicReceiver.swift'
    text = path.read_text(encoding='utf-8').replace('DispatchTime.now().uptimeNanoseconds', 'offlineNow')
    for name in ['startPumpTimerLocked', 'startRealtimeReporter']:
        text = empty_function(text, f'    private func {name}() {{')
    text = replace_once(text, '    private func pumpLocked() {', '''    func offlinePump() {
        lock.lock(); defer { lock.unlock() }
        pumpLocked()
    }

    func offlineConfigure(_ budget: PlayoutBudget, adaptive: Bool) {
        playoutAdaptive = adaptive
        playoutMaximumCorrection = adaptive ? 0.05 : 0
        configurePlayout(budget)
    }

    var offlineExpired: UInt64 { renderRing.expiredFrames }
    var offlineSourceCursor: UInt64? { renderRing.lastSourceFrame }
    var offlineTargetMilliseconds: Double { playoutController?.targetMilliseconds ?? 0 }
    var offlineStretchCounts: (UInt64, UInt64) { (timeStretch.inputFrames, timeStretch.outputFrames) }

    private func pumpLocked() {''')
    if text.count('                realtimeMetrics.recordConcealment()') != 2:
        raise ValueError('concealment insertion points changed')
    text = text.replace('                realtimeMetrics.recordConcealment()',
        '                offlineConcealedFrames += 120\n                realtimeMetrics.recordConcealment()')
    text = replace_once(text, '                jitter?.skip(to: SequenceNumber.next(sequence))',
        '                offlineSkippedFrames += 120\n                jitter?.skip(to: SequenceNumber.next(sequence))')
    text = replace_once(text, '                samples = timeStretch.process(samples, correction: decision.correction)', '''                let inputFrames = samples.count / 2
                samples = timeStretch.process(samples, correction: decision.correction)
                offlineMaximumShift = max(offlineMaximumShift, abs(inputFrames - samples.count / 2))''')
    text = replace_once(text, '                renderRing.pushTimed(concealment.conceal(frames: 120),',
        '                hearport_offline_set_concealing(1)\n                renderRing.pushTimed(concealment.conceal(frames: 120),')
    text = replace_once(text, 'sourceEnd: position + 120, capturedAt: captured, deadline: .max)',
        'sourceEnd: position + 120, capturedAt: captured, deadline: .max)\n                hearport_offline_set_concealing(0)')
    text = replace_once(text, 'import Foundation', 'import Foundation\nimport HearPortAtomics')
    if os.environ.get('HEARPORT_PLAYBACK_REFERENCE') == 'working':
        text = replace_once(text, '        if !preserveOutput { renderActiveAtomic.store(0) }',
            '        if preserveOutput { jitter?.offlineResume() }\n        if !preserveOutput { renderActiveAtomic.store(0) }')
        jitter = directory / 'JitterBuffer.swift'
        code = jitter.read_text(encoding='utf-8')
        code = replace_once(code, '    public mutating func setTargetPackets(',
            '    mutating func offlineResume() { mode = .running }\n\n    public mutating func setTargetPackets(')
        jitter.write_text(code, encoding='utf-8')
    path.write_text(text, encoding='utf-8')
    path = directory / 'RenderRingBuffer.swift'
    text = path.read_text(encoding='utf-8').replace('DispatchTime.now().uptimeNanoseconds', 'offlineNow')
    text = replace_once(text, '        return (output, rendered)',
        '        offlineLastRendered = rendered\n        return (output, rendered)')
    path.write_text(text, encoding='utf-8')
    (directory / 'OfflineClock.swift').write_text('''import Foundation
var offlineNow: UInt64 = 1_000_000_000
var offlineLastRendered = 0
var offlineConcealedFrames = 0
var offlineSkippedFrames = 0
var offlineMaximumShift = 0
''', encoding='utf-8')
    c = destination / 'Sources/HearPortAtomics/AudioRing.c'
    text = c.read_text(encoding='utf-8')
    text = replace_once(text, 'struct HearPortAudioRing {', '''static uint64_t offline_maximum_age;
static uint64_t offline_original_source = UINT64_MAX;
static uint64_t offline_original_span, offline_concealed_span, offline_expired_span;
static uint8_t offline_concealing;
void hearport_offline_set_concealing(uint8_t value) { offline_concealing = value; }
void hearport_offline_reset_age(void) {
    offline_maximum_age = offline_original_span = offline_concealed_span = offline_expired_span = 0;
    offline_original_source = UINT64_MAX;
    offline_concealing = 0;
}
uint64_t hearport_offline_maximum_age(void) { return offline_maximum_age; }
uint64_t hearport_offline_original_source(void) { return offline_original_source; }
uint64_t hearport_offline_original_span(void) { return offline_original_span; }
uint64_t hearport_offline_concealed_span(void) { return offline_concealed_span; }
uint64_t hearport_offline_expired_span(void) { return offline_expired_span; }

struct HearPortAudioRing {
    uint8_t *offline_kind;''')
    text = replace_once(text, '    ring->samples = calloc(capacity_frames * 2, sizeof(float));',
        '    ring->offline_kind = calloc(capacity_frames, 1);\n    ring->samples = calloc(capacity_frames * 2, sizeof(float));')
    text = text.replace('free(ring->samples);', 'free(ring->offline_kind);\n    free(ring->samples);')
    text = replace_once(text, '        const size_t slot = offset / 2;',
        '        const size_t slot = offset / 2;\n        ring->offline_kind[slot] = offline_concealing;')
    text = replace_once(text, '    size_t count = 0;\n    uint64_t cursor = read;',
        '    offline_original_source = UINT64_MAX;\n    size_t count = 0;\n    uint64_t cursor = read;')
    text = replace_once(text, '            atomic_fetch_add_explicit(&ring->expired_frames, 1, memory_order_relaxed);',
        '            offline_expired_span += atomic_load(&ring->source_end[slot]) - atomic_load(&ring->source_begin[slot]);\n            atomic_fetch_add_explicit(&ring->expired_frames, 1, memory_order_relaxed);')
    text = replace_once(text, '        stereo[count * 2] = ring->samples[slot * 2];', '''        if (captured != UINT64_MAX && presentation >= captured && presentation - captured > offline_maximum_age) {
            offline_maximum_age = presentation - captured;
        }
        uint64_t source_end = atomic_load(&ring->source_end[slot]);
        uint64_t span = source_end - atomic_load(&ring->source_begin[slot]);
        if (ring->offline_kind[slot]) offline_concealed_span += span;
        else { offline_original_span += span; offline_original_source = source_end; }
        stereo[count * 2] = ring->samples[slot * 2];''')
    c.write_text(text, encoding='utf-8')
    header = destination / 'Sources/HearPortAtomics/include/HearPortAtomics.h'
    text = header.read_text(encoding='utf-8')
    text = replace_once(text, 'uint64_t hearport_audio_ring_expired_frames',
        '''void hearport_offline_reset_age(void);
void hearport_offline_set_concealing(uint8_t value);
uint64_t hearport_offline_maximum_age(void);
uint64_t hearport_offline_original_source(void);
uint64_t hearport_offline_original_span(void);
uint64_t hearport_offline_concealed_span(void);
uint64_t hearport_offline_expired_span(void);

uint64_t hearport_audio_ring_expired_frames''')
    header.write_text(text, encoding='utf-8')
    shutil.copyfile(Path(__file__).with_name('offline_playback.swift'),
        destination / 'Tests/HearPortReceiverTests/OfflinePlaybackTests.swift')


if __name__ == '__main__':
    prepare(Path(sys.argv[1]), Path(sys.argv[2]))
