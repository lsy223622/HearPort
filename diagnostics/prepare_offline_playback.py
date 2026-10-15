"""Run the receiver's production playback path with a virtual clock in a temporary package."""
import shutil
import sys
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
    text = replace_once(text, 'insertResult == .inserted || insertResult == .late,',
        'insertResult == .inserted || (offlineObserveLate && insertResult == .late),')
    text = replace_once(text, '\n            if abs(decision.correction) > 0.001,',
        '\n            if offlineBatchMode == 2, abs(decision.correction) > 0.001,')
    text = replace_once(text, 'renderRing.fillFrames + 840 <= renderRing.capacityFrames,',
        'renderRing.fillFrames + 840 <= (offlineBatchMode > 0 ? renderRing.capacityFrames : ringReserveFrames),')
    text = replace_once(text, 'minimumBufferMilliseconds: Double(request) / 48 + 6)',
        'minimumBufferMilliseconds: offlineScheduledConceal ? Double(request) / 48 + 6 : 0)')
    text = replace_once(text, '            if deadline <= presentation {',
        '            if offlineScheduledConceal ? deadline <= presentation : (stored != nil && deadline <= now) {')
    text = replace_once(text, '                jitter?.skip(to: SequenceNumber.next(sequence))',
        '                offlineSkippedFrames += 120\n                jitter?.skip(to: SequenceNumber.next(sequence))')
    text = replace_once(text, '(deadline <= now || renderRing.fillFrames < demand)',
        '(deadline <= now || (offlineScheduledConceal ? renderRing.fillFrames < demand : renderRing.fillFrames <= Int(renderRequestFramesAtomic.load()) + 240))')
    text = replace_once(text, '                samples = timeStretch.process(samples, correction: decision.correction)', '''                let inputFrames = samples.count / 2
                samples = timeStretch.process(samples, correction: decision.correction)
                offlineMaximumShift = max(offlineMaximumShift, abs(inputFrames - samples.count / 2))''')
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
var offlineBatchMode = 0
var offlineObserveLate = false
var offlineMaximumShift = 0
var offlineScheduledConceal = false
''', encoding='utf-8')
    c = destination / 'Sources/HearPortAtomics/AudioRing.c'
    text = c.read_text(encoding='utf-8')
    text = replace_once(text, 'struct HearPortAudioRing {', '''static uint64_t offline_maximum_age;
void hearport_offline_reset_age(void) { offline_maximum_age = 0; }
uint64_t hearport_offline_maximum_age(void) { return offline_maximum_age; }

struct HearPortAudioRing {''')
    text = replace_once(text, '        stereo[count * 2] = ring->samples[slot * 2];', '''        if (captured != UINT64_MAX && presentation >= captured && presentation - captured > offline_maximum_age) {
            offline_maximum_age = presentation - captured;
        }
        stereo[count * 2] = ring->samples[slot * 2];''')
    c.write_text(text, encoding='utf-8')
    header = destination / 'Sources/HearPortAtomics/include/HearPortAtomics.h'
    text = header.read_text(encoding='utf-8')
    text = replace_once(text, 'uint64_t hearport_audio_ring_expired_frames',
        'void hearport_offline_reset_age(void);\nuint64_t hearport_offline_maximum_age(void);\n\nuint64_t hearport_audio_ring_expired_frames')
    header.write_text(text, encoding='utf-8')
    shutil.copyfile(Path(__file__).with_name('offline_playback.swift'),
        destination / 'Tests/HearPortReceiverTests/OfflinePlaybackTests.swift')


if __name__ == '__main__':
    prepare(Path(sys.argv[1]), Path(sys.argv[2]))
