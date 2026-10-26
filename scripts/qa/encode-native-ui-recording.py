"""Encode this test's own PNG frame receipt at its original wall-clock speed.

No desktop capture, window control, user profile, or production data is involved.
GIF uses cumulative 10ms boundaries, so rounding does not speed up each frame.
"""
import argparse
import hashlib
import json
from pathlib import Path
from PIL import Image

parser = argparse.ArgumentParser()
parser.add_argument('--manifest', required=True)
args = parser.parse_args()
manifest = Path(args.manifest).resolve()
root = manifest.parent
receipt = json.loads(manifest.read_text(encoding='utf-8'))
frames = receipt['frames']
if not 3 <= len(frames) <= 900:
    raise ValueError('Expected a bounded native frame recording')
images, boundaries, hashes = [], [], []
for frame in frames:
    source = (root / frame['file']).resolve()
    if not source.is_relative_to(root) or source.suffix != '.png':
        raise ValueError('Frame path escaped the explicit evidence directory')
    boundary = round(frame['ms'] / 10) * 10
    with Image.open(source) as image:
        encoded = image.convert('RGB').quantize(colors=256)
    if boundaries and boundary == boundaries[-1]:
        images[-1].close()
        images[-1] = encoded
        continue
    images.append(encoded)
    boundaries.append(boundary)
    hashes.append({'file': frame['file'], 'sha256': hashlib.sha256(source.read_bytes()).hexdigest()})
end = max(boundaries[-1] + 10, round(receipt['wallClockDurationMs'] / 10) * 10)
durations = [b - a for a, b in zip(boundaries, boundaries[1:] + [end])]
output = manifest.with_suffix('.gif')
images[0].save(output, save_all=True, append_images=images[1:],
               duration=durations, loop=0, disposal=2, optimize=False)
for image in images:
    image.close()
with Image.open(output) as check:
    actual_duration = 0
    for index in range(check.n_frames):
        check.seek(index)
        actual_duration += check.info.get('duration', 0)
if abs(actual_duration - (end - boundaries[0])) > 10:
    raise ValueError('Encoded animation changed the wall-clock duration')
report = {'format': 'GIF', 'playbackSpeed': 1,
          'wallClockDurationMs': receipt['wallClockDurationMs'],
          'encodedDurationMs': actual_duration, 'sourceFrameCount': len(frames),
          'cumulativeTimeQuantizationMs': 10, 'sourceHashes': hashes}
manifest.with_name(manifest.stem + '-encoding.json').write_text(
    json.dumps(report, indent=2), encoding='utf-8')
print(json.dumps({k: v for k, v in report.items() if k != 'sourceHashes'}))
