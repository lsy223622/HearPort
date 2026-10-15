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
    text = destination.read_text(encoding='utf-8')
    anchor = '    public func captureTime(sourceFrame: UInt64) -> UInt64? {'
    method = '''    mutating func offlineRestore(_ previous: PlayoutController) {
        if offlineKeepTarget { targetMilliseconds = previous.targetMilliseconds }
        if offlineKeepHistory { delays = previous.delays }
        if offlineKeepRate { correction = previous.correction; lastDecisionAt = previous.lastDecisionAt }
        if offlineKeepAnchor { anchor = previous.anchor }
    }

'''
    if text.count(anchor) != 1:
        raise ValueError('production controller state experiment insertion point changed')
    destination.write_text(text.replace(anchor, method + anchor), encoding='utf-8')


def prepare_probe(source, destination):
    text = source.read_text(encoding='utf-8')
    changes = [(
        '        endSourceFrame = sourceFrame + 30 * 48_000',
        '        endSourceFrame = sourceFrame + offlineSourceFrameCount'), (
        '    mutating func updateUncertainty(_ uncertainty: UInt64) { clockUncertainty = uncertainty }',
        '    var offlineSourceFrame: UInt64 { sourceFrame }\n\n'
        '    mutating func updateUncertainty(_ uncertainty: UInt64) { clockUncertainty = uncertainty }'), (
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
                    let previousControl = control
                    control = PlayoutController(budget: budget,
                        maximumCorrection: round.controller == 0 ? 0 : Double(round.correctionPercent) / 100,
                        adaptive: round.controller >= 2)
                    control.offlineRestore(previousControl)
                }'''), (
        '        guard !SequenceNumber.isBefore(record.sequence, nextSequence) ||',
        '''        if record.kind != .fec && SequenceNumber.isBefore(record.sequence, nextSequence) {
            offlineProbeAudit.receivedAfterConsumptionPackets += 1
        }
        guard !SequenceNumber.isBefore(record.sequence, nextSequence) ||'''), (
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


def prepare_recovery(source, destination):
    text = source.read_text(encoding='utf-8')
    before = 'const auto snapshot_lag_limit = maximum_lag_ + feedback_age;'
    after = 'const auto snapshot_lag_limit = maximum_lag_ + feedback_age - std::chrono::milliseconds(offlineRecoveryLeadMilliseconds);'
    if text.count(before) != 1:
        raise ValueError('production recovery timing experiment insertion point changed')
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(text.replace(before, after), encoding='utf-8')


if __name__ == '__main__':
    prepare(Path(sys.argv[1]), Path(sys.argv[2]))
    prepare_probe(Path(sys.argv[3]), Path(sys.argv[4]))
    prepare_recovery(Path(sys.argv[5]), Path(sys.argv[6]))
