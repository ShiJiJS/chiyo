"""Protect existing/out-of-tree files from the opt-in helper candidate builder."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location(
    "focus_builder", Path(__file__).resolve().parents[1] / "build-macos-focused-helper.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class CandidateDestinationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.original = MODULE.OUTPUT_ROOT
        MODULE.OUTPUT_ROOT = self.root / "build"
        MODULE.OUTPUT_ROOT.mkdir()

    def tearDown(self):
        MODULE.OUTPUT_ROOT = self.original
        self.temporary.cleanup()

    def test_existing_directory_and_contents_are_preserved(self):
        destination = MODULE.OUTPUT_ROOT / "existing"
        destination.mkdir()
        original = destination / "owner-file"
        original.write_bytes(b"keep existing bytes")
        with self.assertRaises(ValueError):
            MODULE.output_path(destination)
        self.assertEqual(original.read_bytes(), b"keep existing bytes")

    def test_symlink_parent_cannot_redirect_a_new_output(self):
        outside = self.root / "outside"
        outside.mkdir()
        alias = MODULE.OUTPUT_ROOT / "alias"
        alias.symlink_to(outside, target_is_directory=True)
        with self.assertRaises(ValueError):
            MODULE.output_path(alias / "candidate")
        self.assertEqual(list(outside.iterdir()), [])
        self.assertTrue(alias.is_symlink())

    def test_dangling_link_and_outside_path_are_preserved(self):
        alias = MODULE.OUTPUT_ROOT / "dangling"
        alias.symlink_to(self.root / "missing")
        for path in [alias, self.root / "outside-new"]:
            with self.assertRaises(ValueError):
                MODULE.output_path(path)
        self.assertTrue(alias.is_symlink())
        self.assertFalse((self.root / "outside-new").exists())

    def test_unicode_new_candidate_is_allowed_but_direct_app_output_is_not(self):
        destination = MODULE.OUTPUT_ROOT / "合成 helper 候选"
        self.assertEqual(MODULE.output_path(destination), destination)
        self.assertFalse(destination.exists())
        for suffix in ["app", "xpc", "dSYM"]:
            with self.assertRaises(ValueError):
                MODULE.output_path(MODULE.OUTPUT_ROOT / ("candidate." + suffix))


if __name__ == "__main__":
    unittest.main()
