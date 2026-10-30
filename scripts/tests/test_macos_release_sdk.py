import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('macos_release', Path(__file__).resolve().parents[1] / 'build-macos-release.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class TemporarySdkSourceTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'features.dart'
        self.path.write_bytes(b'original')

    def test_restores_after_success_and_build_failure(self):
        for failed in (False, True):
            try:
                with module.temporary_source(self.path, b'original', b'patched'):
                    self.assertEqual(self.path.read_bytes(), b'patched')
                    if failed:
                        raise ValueError('build failure')
            except ValueError:
                pass
            self.assertEqual(self.path.read_bytes(), b'original')

    def test_preserves_unrelated_edits(self):
        self.path.write_bytes(b'user changes')
        with self.assertRaises(RuntimeError):
            with module.temporary_source(self.path, b'original', b'patched'):
                self.fail('must not build')
        self.assertEqual(self.path.read_bytes(), b'user changes')

    def test_recovers_known_interrupted_patch(self):
        self.path.write_bytes(b'patched')
        with module.temporary_source(self.path, b'original', b'patched'):
            pass
        self.assertEqual(self.path.read_bytes(), b'original')

    def test_preserves_edits_during_build(self):
        with self.assertRaises(RuntimeError):
            with module.temporary_source(self.path, b'original', b'patched'):
                self.path.write_bytes(b'concurrent changes')
        self.assertEqual(self.path.read_bytes(), b'concurrent changes')


if __name__ == '__main__':
    unittest.main()
