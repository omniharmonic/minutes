#!/usr/bin/env python3
"""Local-only, silent speaker-condition audit. Originals and profiles are never changed."""
import argparse
import json
import math
import pathlib
import random
import struct
import subprocess
import tempfile
import wave

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('audio')
parser.add_argument('--expect-person', required=True, help='Existing local person ID; no enrollment occurs')
parser.add_argument('--cli', default='MinutesKit/.build/debug/minutes-cli')
parser.add_argument('--output', required=True, help='Counts-only JSON output')
args = parser.parse_args()
results = {}
with tempfile.TemporaryDirectory(prefix='minutes-voice-conditions-') as temporary:
    root = pathlib.Path(temporary)
    for name, filt in [('original', 'anull'), ('quiet18db', 'volume=0.12589254'),
                       ('gain6db', 'volume=1.995262'), ('telephone', 'highpass=f=300,lowpass=f=3400')]:
        subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', args.audio, '-af', filt,
                        '-ac', '1', '-ar', '16000', str(root / (name + '.wav'))], check=True)
    with wave.open(str(root / 'original.wav'), 'rb') as wav:
        values = struct.unpack('<%dh' % wav.getnframes(), wav.readframes(wav.getnframes()))
    rms = math.sqrt(sum(v*v for v in values) / max(1, len(values)))
    rng = random.Random(50)
    for snr in (20, 10):
        sigma = rms / 10**(snr/20)
        noisy = [max(-32768, min(32767, round(v + rng.gauss(0, sigma)))) for v in values]
        with wave.open(str(root / ('noise%ddb.wav' % snr)), 'wb') as wav:
            wav.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
            wav.writeframes(struct.pack('<%dh' % len(noisy), *noisy))
    for path in sorted(root.glob('*.wav')):
        results[path.stem] = {}
        for mode in ('voice-audit-file', 'caption-voice-file'):
            run = subprocess.run([args.cli, mode, str(path), '--expect-person', args.expect_person],
                                 capture_output=True, text=True, check=True)
            results[path.stem][mode] = [line for line in run.stdout.splitlines()
                if line.startswith(('Batch audit:', 'Expected-person', 'Caption voice', 'Decisions:', 'Anonymous provisional'))]
pathlib.Path(args.output).write_text(json.dumps(results, indent=2) + '\n')
print('Silent condition audit complete; counts-only results saved. Temporary audio removed.')
