"""Compile the experimental deadline rule into an offline copy only."""
import sys
from pathlib import Path


def prepare(source, destination):
    text = source.read_text(encoding='utf-8')
    anchor = '        let action: PlayoutAction\n'
    if text.count(anchor) != 1:
        raise ValueError('production controller experiment insertion point changed')
    rule = '''        if offlineDeadlineGuardMilliseconds > 0, correction < 0, let deadline {
            let remaining = now < deadline ? Double(deadline - now) / 1e6 : 0
            let scale = min(1, max(0, (remaining - 5) / offlineDeadlineGuardMilliseconds))
            correction = max(correction, -maximumCorrection * scale)
        }
'''
    destination.write_text(text.replace(anchor, rule + anchor), encoding='utf-8')


def prepare_probe(source, destination):
    text = source.read_text(encoding='utf-8')
    changes = [(
        '                let retainedFrames = running ? min(bufferedFrames, renderReserveFrames) : 0',
        '                let previousPackets = packets\n'
        '                let retainedFrames = running ? min(bufferedFrames, renderReserveFrames) : 0'), (
        '                packets = packets.filter { ($0.key &- nextSequence) < retainedPackets }',
        '''                packets = packets.filter {
                    offlineKeepBuffer ? budget.prepareDeadline(capturedAt: $0.value.captured) > now
                        : ($0.key &- nextSequence) < retainedPackets
                }
                for (sequence, packet) in previousPackets where packets[sequence] == nil {
                    offlineProbeAudit.discardedSequences.insert(sequence)
                    offlineProbeAudit.droppedBufferedFrames += Int(packet.record.frameCount) - (sequence == nextSequence ? offset : 0)
                }'''), (
        '''                control = PlayoutController(budget: budget,
                    maximumCorrection: round.controller == 0 ? 0 : Double(round.correctionPercent) / 100,
                    adaptive: round.controller >= 2)''',
        '''                if !offlineKeepController {
                    control = PlayoutController(budget: budget,
                        maximumCorrection: round.controller == 0 ? 0 : Double(round.correctionPercent) / 100,
                        adaptive: round.controller >= 2)
                }'''), (
        '        guard deadline > now else { return }',
        '''        guard deadline > now else {
            offlineProbeAudit.rejectedExpiredPackets += 1
            offlineProbeAudit.expiredSequences.insert(record.sequence)
            return
        }'''), (
        '        packets[record.sequence] = Packet(record: record, captured: capturedAt, uncertainty: uncertainty)',
        '''        offlineProbeAudit.discardedSequences.remove(record.sequence)
        offlineProbeAudit.expiredSequences.remove(record.sequence)
        packets[record.sequence] = Packet(record: record, captured: capturedAt, uncertainty: uncertainty)'''), (
        '            } else { concealed += count }',
        '''            } else {
                concealed += count
                if packet != nil { offlineProbeAudit.expiredQueuedFrames += count }
                else if offlineProbeAudit.discardedSequences.contains(nextSequence) {
                    offlineProbeAudit.discardedMissingFrames += count
                } else if offlineProbeAudit.expiredSequences.contains(nextSequence) {
                    offlineProbeAudit.lateArrivalFrames += count
                } else { offlineProbeAudit.networkMissingFrames += count }
            }''')]
    for before, after in changes:
        if text.count(before) != 1:
            raise ValueError(f'production probe experiment insertion point changed: {before}')
        text = text.replace(before, after)
    destination.write_text(text, encoding='utf-8')


if __name__ == '__main__':
    prepare(Path(sys.argv[1]), Path(sys.argv[2]))
    prepare_probe(Path(sys.argv[3]), Path(sys.argv[4]))
