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


if __name__ == '__main__':
    prepare(Path(sys.argv[1]), Path(sys.argv[2]))
