"""Codec/time integrity checks, independent of native UI timing."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zlib
from PIL import Image

spec = importlib.util.spec_from_file_location('encoder', Path(__file__).with_name('encode-native-ui-recording.py'))
encoder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(encoder)


class RecordingEncoderTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='zhiyu-codec-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()

    def raw(self, index, color=(31, 77, 125, 128), ms=None):
        path = self.root / f'frame-{index}.rgba.zlib'
        with Image.new('RGBA', (8, 8), color) as image:
            data = zlib.compress(image.tobytes(), level=1)
        path.write_bytes(data)
        return {'file': path.name, 'format': 'rgba8888-zlib', 'width': 8, 'height': 8,
                'compressedBytes': len(data), 'ms': index * 33 if ms is None else ms,
                'captureUs': 1000 + index * 100}

    def receipt(self, frames, duration=100, events=None):
        path = self.root / 'clip.json'
        path.write_text(json.dumps({'frames': frames, 'wallClockDurationMs': duration,
                                    'events': events or [], 'pixelRatio': 1,
                                    'viewportCropped': False}))
        return path

    def still_receipt(self, frames, **changes):
        path = self.root / 'native-stills.json'
        data = {'kind': 'native-flutter-stills-raw-rgba', 'pixelRatio': 1,
                'viewportCropped': False, 'stills': frames, **changes}
        path.write_text(json.dumps(data))
        return path

    def test_deferred_stills_preserve_alpha_pixels_names_and_capture_metadata(self):
        frame = {**self.raw(0), 'output': 'dialog-light.png',
                 'recordingActive': True, 'recordingMs': 350}
        report = encoder.encode_stills(self.still_receipt([frame]))
        self.assertEqual(report['sourceCount'], 1)
        self.assertEqual(report['format'], 'lossless-RGBA-PNG')
        self.assertEqual(report['sources'][0]['recordingMs'], 350)
        self.assertEqual(report['sources'][0]['captureUs'], 1000)
        with Image.open(self.root / frame['output']) as image:
            self.assertEqual(image.size, (8, 8))
            self.assertEqual(image.mode, 'RGBA')
            self.assertEqual(image.getpixel((0, 0)), (31, 77, 125, 128))
        self.assertEqual(len(report['sources'][0]['pngSha256']), 64)

    def test_deferred_still_outputs_reject_escape_duplicates_symlinks_and_source_overwrite(self):
        frame = {**self.raw(0), 'output': 'good.png'}
        link = self.root / 'link.png'
        link.symlink_to(self.root / frame['file'])
        for name in ['../escape.png', 'nested/file.png', frame['file'], 'bad\n.png', 'link.png']:
            with self.subTest(name=name), self.assertRaises(ValueError):
                encoder.encode_stills(self.still_receipt([{**frame, 'output': name}]))
        with self.assertRaises(ValueError):
            encoder.encode_stills(self.still_receipt([frame, frame]))
        self.assertFalse((self.root / 'good.png').exists())

    def test_deferred_still_receipts_require_full_resolution_raw_bounded_sources(self):
        frame = {**self.raw(0), 'output': 'still.png'}
        for changes in [{'kind': 'unknown'}, {'pixelRatio': .5}, {'pixelRatio': True},
                        {'viewportCropped': True}, {'stills': []},
                        {'stills': [frame] * 257},
                        {'stills': [{**frame, 'format': 'png'}]}]:
            with self.subTest(changes=list(changes)), self.assertRaises(ValueError):
                encoder.encode_stills(self.still_receipt([frame], **changes))

    def test_deferred_still_aggregate_pixel_budget_is_enforced(self):
        frames = [{**self.raw(i), 'output': f'still-{i}.png'} for i in range(2)]
        with patch.object(encoder, 'MAX_TOTAL_PIXELS', 100), self.assertRaises(ValueError):
            encoder.encode_stills(self.still_receipt(frames))

    def test_straight_rgba_pixels_and_alpha_round_trip_without_scaling(self):
        frame = self.raw(0)
        image, identity = encoder.decode_frame(self.root, frame)
        with image:
            self.assertEqual(image.size, (8, 8))
            self.assertEqual(image.getpixel((0, 0)), (31, 77, 125, 128))
            self.assertEqual(len(identity['decodedRgbaSha256']), 64)
        frames = [frame, self.raw(1), self.raw(2)]
        encoder.encode(self.receipt(frames))
        with Image.open(self.root / 'clip-start.png') as preview:
            self.assertEqual(preview.getpixel((0, 0)), (31, 77, 125, 128))

    def test_raw_timeline_quantizes_cumulatively_and_reports_real_gaps(self):
        frames = [self.raw(i, (i * 50, 20, 90, 255)) for i in range(3)]
        report = encoder.encode(self.receipt(frames, 101, [{'event': 'open', 'ms': 0},
                                                          {'event': 'close', 'ms': 50}]))
        self.assertEqual(report['playbackSpeed'], 1)
        self.assertEqual(report['encodedDurationMs'], 100)
        self.assertEqual(report['sourceTimesMs'], [0, 33, 66])
        self.assertEqual(report['sourceGaps']['maximumMs'], 33)
        self.assertEqual(report['captureTimeUs']['maximumUs'], 1200)
        self.assertEqual(report['distinctSourceFrameCount'], 3)
        self.assertEqual(report['eventWindows'][0]['sourceFrameCount'], 2)

    def test_legacy_png_receipt_remains_readable(self):
        frames = []
        for i in range(3):
            path = self.root / f'old-{i}.png'
            with Image.new('RGB', (8, 8), (20 * i, 40, 80)) as image:
                image.save(path)
            frames.append({'file': path.name, 'ms': i * 40})
        report = encoder.encode(self.receipt(frames, 120))
        self.assertEqual(report['encodedDurationMs'], 120)
        self.assertIsNone(report['captureTimeUs'])
        self.assertTrue(all(f['format'] == 'png' for f in report['sourceHashes']))

    def test_duplicate_quantized_timestamps_retain_all_source_hashes(self):
        frames = [self.raw(i, (i * 60, 0, 0, 255), t) for i, t in enumerate([0, 1, 25, 61])]
        report = encoder.encode(self.receipt(frames, 90))
        self.assertEqual(report['sourceFrameCount'], 4)
        self.assertEqual(len(report['sourceHashes']), 4)
        self.assertEqual(report['encodedDurationMs'], 90)
        self.assertLessEqual(report['encodedFrameCount'], 3)

    def test_nonzero_first_capture_is_reported_without_inventing_a_prefix(self):
        frames = [self.raw(i, ms=t) for i, t in enumerate([10, 40, 70])]
        report = encoder.encode(self.receipt(frames, 100))
        self.assertEqual(report['firstFrameMs'], 10)
        self.assertEqual(report['encodedStartMs'], 10)
        self.assertEqual(report['encodedDurationMs'], 90)

    def test_corrupt_truncated_oversized_and_concatenated_zlib_are_rejected(self):
        frame = self.raw(0)
        path = self.root / frame['file']
        valid = path.read_bytes()
        for data in [b'not-zlib', valid[:-1], zlib.compress(b'0' * 100000), valid + valid]:
            with self.subTest(size=len(data)):
                path.write_bytes(data)
                frame['compressedBytes'] = len(data)
                with self.assertRaises(ValueError):
                    encoder.decode_frame(self.root, frame)

    def test_dimensions_and_compressed_length_are_checked(self):
        frame = self.raw(0)
        for changes in [{'width': 4097}, {'height': -1}, {'width': True},
                        {'compressedBytes': frame['compressedBytes'] + 1}]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                encoder.decode_frame(self.root, {**frame, **changes})

    def test_path_escape_and_symlink_are_rejected(self):
        frame = self.raw(0)
        with self.assertRaises(ValueError):
            encoder.decode_frame(self.root, {**frame, 'file': '../outside.rgba.zlib'})
        alias = self.root / 'alias.rgba.zlib'
        alias.symlink_to(self.root / frame['file'])
        with self.assertRaises(ValueError):
            encoder.decode_frame(self.root, {**frame, 'file': alias.name})

    def test_backwards_or_outside_frame_and_event_times_are_rejected(self):
        for times in [[0, 60, 33], [0, 33, 120], [0, True, 66]]:
            with self.subTest(times=times), self.assertRaises(ValueError):
                encoder.encode(self.receipt([self.raw(i, ms=t) for i, t in enumerate(times)]))
        with self.assertRaises(ValueError):
            encoder.encode(self.receipt([self.raw(i) for i in range(3)], events=[{'event': 'late', 'ms': 101}]))

    def test_size_changes_and_total_pixel_budget_are_rejected(self):
        frames = [self.raw(i) for i in range(3)]
        with patch.object(encoder, 'MAX_TOTAL_PIXELS', 100), self.assertRaises(ValueError):
            encoder.encode(self.receipt(frames))
        path = self.root / 'other.png'
        with Image.new('RGB', (9, 8)) as image:
            image.save(path)
        with self.assertRaises(ValueError):
            encoder.encode(self.receipt([frames[0], {'file': path.name, 'ms': 33}, frames[2]]))


if __name__ == '__main__':
    unittest.main(verbosity=2)
