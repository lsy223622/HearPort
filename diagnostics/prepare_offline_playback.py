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
    var offlinePlayedSource: UInt64? { renderRing.lastSourceFrame }
    var offlineStretchCounts: (UInt64, UInt64) { (timeStretch.inputFrames, timeStretch.outputFrames) }

    private func pumpLocked() {''')
    if text.count('                realtimeMetrics.recordConcealment()') != 2:
        raise ValueError('concealment insertion points changed')
    text = text.replace('                realtimeMetrics.recordConcealment()',
        '                offlineConcealedFrames += 120\n                realtimeMetrics.recordConcealment()')
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
