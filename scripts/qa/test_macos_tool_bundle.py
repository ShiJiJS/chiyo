"""Negative builder checks: no network, installations or actual app mutation."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('mac_tools', Path(__file__).resolve().parents[1] / 'bundle-macos-tools.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class BundleIntegrityTests(unittest.TestCase):
    def test_corrupt_cache_is_rejected_without_download(self):
        with tempfile.TemporaryDirectory() as name:
            original = MODULE.ROOT
            try:
                MODULE.ROOT = Path(name)
                cache = MODULE.ROOT / '.downloads'
                cache.mkdir()
                (cache / 'fixture.zip').write_bytes(b'corrupt cached archive')
                with self.assertRaisesRegex(RuntimeError, 'Cached SHA256 mismatch'):
                    MODULE.verified_download('fixture.zip', 'https://invalid.invalid/', '0' * 64)
                self.assertEqual((cache / 'fixture.zip').read_bytes(), b'corrupt cached archive')
            finally:
                MODULE.ROOT = original

    def test_dependency_symlink_escape_is_rejected(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name) / 'payload'
            root.mkdir()
            (Path(name) / 'outside').write_bytes(b'not part of payload')
            (root / 'redirected').symlink_to('../outside')
            with self.assertRaises(ValueError):
                MODULE.inventory(root)


if __name__ == '__main__':
    unittest.main()
