"""Exercise the actual macOS Bash launcher with inert Flutter/Python functions.

Checks argument forwarding only: no Flutter build, app/helper launch or signing.
The existing pinned SDK and Xcode are read for the launcher's normal preflight.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
WRAPPER = r'''
flutter() {
  printf '%s\0' "$@" >> "$FAKE_FLUTTER_LOG"
  printf '\n' >> "$FAKE_FLUTTER_LOG"
}
python3() {
  printf '%s\0' "$@" >> "$FAKE_PYTHON_LOG"
  printf '\n' >> "$FAKE_PYTHON_LOG"
}
export -f flutter python3
exec /bin/bash "$MAC_BUILD_LAUNCHER" "$@"
'''


class MacBuildArgumentsTests(unittest.TestCase):
    def run_launcher(self, *arguments):
        with tempfile.TemporaryDirectory() as name:
            flutter = Path(name) / "flutter.log"
            python = Path(name) / "python.log"
            env = os.environ | {"FAKE_FLUTTER_LOG": str(flutter), "FAKE_PYTHON_LOG": str(python),
                                "MAC_BUILD_LAUNCHER": str(ROOT / "scripts/dev-macos.sh")}
            result = subprocess.run(["/bin/bash", "-c", WRAPPER, "launcher-check", *arguments],
                                    cwd=ROOT, env=env, capture_output=True, timeout=20)
            def calls(path):
                if not path.exists():
                    return []
                return [[word.decode() for word in row.split(b"\0")[:-1]]
                        for row in path.read_bytes().splitlines()]
            return result, calls(flutter), calls(python)

    def test_empty_arguments_work_on_macos_bash_without_extra_empty_string(self):
        result, flutter, python = self.run_launcher("build")
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(flutter, [])
        self.assertTrue(python[0][0].endswith("/build-macos-release.py"))
        self.assertEqual(len(python), 3)
        self.assertTrue(python[2][0].endswith("/bundle-macos-focused-helper.py"))
        self.assertEqual(len(python[2]), 2)  # Default embeds the helper.

    def test_candidate_option_is_consumed_and_other_arguments_keep_spaces(self):
        result, flutter, python = self.run_launcher("build", "--with-focused-fill-candidate", "--build-name=合成 版本")
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(flutter, [])
        self.assertEqual(python[0][-1], "--build-name=合成 版本")
        self.assertEqual(len(python[2]), 2)
        self.assertNotIn("--with-focused-fill-candidate", python[0])

    def test_run_preserves_ordinary_arguments_without_packaging(self):
        result, flutter, python = self.run_launcher("run", "--debug")
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(flutter, [["run", "-d", "macos", "--debug"]])
        self.assertEqual(python, [])

    def test_run_rejects_candidate_flag_before_calling_flutter(self):
        result, flutter, python = self.run_launcher("run", "--with-focused-fill-candidate")
        self.assertEqual(result.returncode, 64)
        self.assertEqual(flutter, [])
        self.assertEqual(python, [])


if __name__ == "__main__":
    unittest.main()
