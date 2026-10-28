"""Encode owned native frames at their recorded wall-clock speed.

Accept legacy PNG receipts and lossless straight-RGBA/zlib receipts. Pixel
decoding and palette encoding run on the host after native interaction stops.
"""
import argparse
import hashlib
import json
from pathlib import Path
import statistics
import zlib
from PIL import Image

MAX_FRAME_PIXELS = 8_388_608
MAX_TOTAL_PIXELS = 512_000_000


def decode_frame(root, frame):
    candidate = root / frame['file']
    source = candidate.resolve()
    if candidate.is_symlink() or not source.is_relative_to(root) or not source.is_file():
        raise ValueError('Frame path escaped the explicit evidence directory')
    if source.stat().st_size > MAX_FRAME_PIXELS * 4 + 65536:
        raise ValueError('Frame input exceeds the bounded pixel payload')
    payload = source.read_bytes()
    kind = frame.get('format', 'png')
    if kind == 'rgba8888-zlib':
        width, height = frame.get('width'), frame.get('height')
        if (type(width) is not int or type(height) is not int or
                not 0 < width <= 4096 or not 0 < height <= 4096 or
                width * height > MAX_FRAME_PIXELS or not source.name.endswith('.rgba.zlib')):
            raise ValueError('Invalid raw framebuffer dimensions or format')
        if frame.get('compressedBytes', len(payload)) != len(payload):
            raise ValueError('Compressed frame length does not match its receipt')
        decoder = zlib.decompressobj()
        try:
            raw = decoder.decompress(payload, width * height * 4 + 1)
        except zlib.error as error:
            raise ValueError('Invalid zlib framebuffer') from error
        if (len(raw) != width * height * 4 or not decoder.eof or
                decoder.unconsumed_tail or decoder.unused_data):
            raise ValueError('Incomplete, oversized or concatenated RGBA frame')
        image = Image.frombytes('RGBA', (width, height), raw)
    elif kind == 'png' and source.suffix == '.png':
        with Image.open(source) as original:
            if original.width * original.height > MAX_FRAME_PIXELS:
                raise ValueError('PNG framebuffer exceeds pixel limit')
            image = original.convert('RGBA')
    else:
        raise ValueError('Unsupported native frame format')
    return image, {'file': frame['file'], 'format': kind,
                   'sha256': hashlib.sha256(payload).hexdigest(),
                   'decodedRgbaSha256': hashlib.sha256(image.tobytes()).hexdigest()}


def statistics_for(values, unit):
    ordered = sorted(values)
    return {'count': len(values), 'maximum' + unit: max(values, default=0),
            'median' + unit: statistics.median(values) if values else 0,
            'p95' + unit: ordered[min(len(ordered) - 1, int(len(ordered) * .95))] if ordered else 0}


def gap_summary(times):
    return statistics_for([b - a for a, b in zip(times, times[1:])], 'Ms')


def encode(manifest):
    manifest = Path(manifest).resolve()
    root = manifest.parent
    receipt = json.loads(manifest.read_text(encoding='utf-8'))
    frames = receipt['frames']
    duration = receipt['wallClockDurationMs']
    if not 3 <= len(frames) <= 900 or type(duration) is not int or duration <= 0:
        raise ValueError('Expected a bounded native frame recording')
    times = [f['ms'] for f in frames]
    if (any(type(t) is not int or not 0 <= t <= duration for t in times) or
            any(b < a for a, b in zip(times, times[1:]))):
        raise ValueError('Frame timestamps must be monotonic and within the recording')
    events = receipt.get('events', [])
    if (any(type(e.get('ms')) is not int or not 0 <= e['ms'] <= duration for e in events) or
            any(b['ms'] < a['ms'] for a, b in zip(events, events[1:]))):
        raise ValueError('Event timestamps must be monotonic and within the recording')
    images, boundaries, hashes = [], [], []
    size = None
    total_pixels = 0
    previews = {0: 'start', len(frames) // 2: 'middle', len(frames) - 1: 'end'}
    try:
        for index, frame in enumerate(frames):
            image, identity = decode_frame(root, frame)
            try:
                if size is not None and image.size != size:
                    raise ValueError('A recording must retain one framebuffer size')
                size = image.size
                total_pixels += image.width * image.height
                if total_pixels > MAX_TOTAL_PIXELS:
                    raise ValueError('Recording exceeds the host pixel budget')
                if index in previews:
                    image.save(manifest.with_name(manifest.stem + '-' + previews[index] + '.png'))
                with image.convert('RGB') as rgb:
                    encoded = rgb.quantize(colors=256)
            finally:
                image.close()
            hashes.append(identity)
            boundary = round(frame['ms'] / 10) * 10
            if boundaries and boundary == boundaries[-1]:
                images[-1].close()
                images[-1] = encoded
            else:
                images.append(encoded)
                boundaries.append(boundary)
        end = max(boundaries[-1] + 10, round(duration / 10) * 10)
        durations = [b - a for a, b in zip(boundaries, boundaries[1:] + [end])]
        output = manifest.with_suffix('.gif')
        images[0].save(output, save_all=True, append_images=images[1:],
                       duration=durations, loop=0, disposal=2, optimize=False)
    finally:
        for image in images:
            image.close()
    with Image.open(output) as check:
        actual_duration = 0
        encoded_frames = check.n_frames
        for index in range(check.n_frames):
            check.seek(index)
            actual_duration += check.info.get('duration', 0)
    if abs(actual_duration - (end - boundaries[0])) > 10:
        raise ValueError('Encoded animation changed the wall-clock duration')
    windows = []
    for index, event in enumerate(events):
        finish = events[index + 1]['ms'] if index + 1 < len(events) else duration
        sampled = [t for t in times if event['ms'] <= t <= finish]
        windows.append({'event': event['event'], 'startMs': event['ms'], 'endMs': finish,
                        'sourceFrameCount': len(sampled),
                        'coverageGaps': gap_summary([event['ms'], *sampled, finish])})
    report = {'format': 'GIF', 'playbackSpeed': 1, 'wallClockDurationMs': duration,
              'firstFrameMs': times[0], 'encodedStartMs': boundaries[0], 'encodedEndMs': end,
              'encodedDurationMs': actual_duration, 'sourceFrameCount': len(frames),
              'distinctSourceFrameCount': len({h['decodedRgbaSha256'] for h in hashes}),
              'sourceTimesMs': times,
              'encodedFrameCount': encoded_frames, 'cumulativeTimeQuantizationMs': 10,
              'framebufferSize': list(size), 'sourcePixelRatio': receipt.get('pixelRatio', 1),
              'viewportCropped': receipt.get('viewportCropped', False),
              'sourceGaps': gap_summary(times), 'eventWindows': windows,
              'captureTimeUs': (statistics_for([f['captureUs'] for f in frames], 'Us')
                                if all('captureUs' in f for f in frames) else None),
              'busyTicksSkipped': receipt.get('busyTicksSkipped'),
              'unpaintedTicksSkipped': receipt.get('unpaintedTicksSkipped'),
              'bufferedCompressedBytes': receipt.get('bufferedCompressedBytes'),
              'gifPaletteColors': 256, 'sourceHashes': hashes}
    manifest.with_name(manifest.stem + '-encoding.json').write_text(
        json.dumps(report, indent=2), encoding='utf-8')
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', required=True)
    report = encode(parser.parse_args().manifest)
    print(json.dumps({k: v for k, v in report.items() if k not in ['sourceHashes', 'eventWindows']}))


if __name__ == '__main__':
    main()
