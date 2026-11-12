"""Actual ad-hoc signing/embedding checks; synthetic binaries are never run.

All App/XPC fixtures and compiler files live in one temporary project directory
and are removed. No installed app, TCC, database, keychain or UI operation.
"""
import importlib.util
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("focused_bundle", ROOT / "scripts/bundle-macos-focused-helper.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class EmbeddedCandidateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        MODULE.ADAPTATION.mkdir(parents=True, exist_ok=True)
        cls.temporary = tempfile.TemporaryDirectory(prefix="focus-bundle-check-", dir=MODULE.ADAPTATION)
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.base = Path(cls.temporary.name)
        source = cls.base / "synthetic.c"
        source.write_text("int main(void) { return 0; }\n")
        cls.binary = cls.base / "synthetic-never-executed"
        subprocess.run(["xcrun", "clang", "-target", "arm64-apple-macos14.0", str(source), "-o", str(cls.binary)], check=True)
        cls.helper_build = cls.base / "helper"
        cls.receipt = MODULE.BUILDER.build(cls.helper_build)

    def setUp(self):
        self.work = tempfile.TemporaryDirectory(dir=self.base)
        self.addCleanup(self.work.cleanup)
        self.app = Path(self.work.name) / "info_desktop.app"
        contents = self.app / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        (contents / "Resources").mkdir()
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "com.example.infoDesktop", "CFBundleExecutable": "info_desktop",
            "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "LSMinimumSystemVersion": "14.0"}))
        self.owner = contents / "MacOS/info_desktop"
        self.worker = contents / "MacOS/info-runtime-worker"
        for program in [self.owner, self.worker]:
            shutil.copy2(self.binary, program)
        MODULE.command(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none",
                        "--entitlements", str(ROOT / "apps/desktop/macos/Runner/Worker.entitlements"), str(self.worker)])
        MODULE.command(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none",
                        "--entitlements", str(ROOT / "apps/desktop/macos/Runner/Release.entitlements"), str(self.app)])

    def build_helper(self, destination):
        destination.mkdir()
        shutil.copytree(self.helper_build / (MODULE.BUILDER.SERVICE + ".xpc"),
                        destination / (MODULE.BUILDER.SERVICE + ".xpc"))
        return self.receipt

    def embed(self):
        return MODULE.assemble(self.app, enabled=True, build_helper=self.build_helper)

    def test_explicit_disabled_without_helper_does_not_modify_the_app(self):
        before = {str(p.relative_to(self.app)): MODULE.BUILDER.digest(p) for p in self.app.rglob("*") if p.is_file()}
        self.assertEqual(MODULE.assemble(self.app, enabled=False), {"included": False, "modified": False, "capabilityEnabled": False})
        self.assertEqual(before, {str(p.relative_to(self.app)): MODULE.BUILDER.digest(p) for p in self.app.rglob("*") if p.is_file()})

    def test_embedding_and_explicit_remove_preserve_sandbox_and_worker(self):
        owner_rights = MODULE.entitlements(self.app)
        worker_rights = MODULE.entitlements(self.worker)
        worker_digest = MODULE.BUILDER.digest(self.worker)
        result = self.embed()
        self.assertTrue(result["included"])
        self.assertTrue(result["capabilityEnabled"])
        self.assertFalse(result["helperExecuted"])
        record = MODULE.inspect(self.app)
        self.assertEqual(record["helper"], self.receipt)
        self.assertEqual(MODULE.entitlements(self.app), owner_rights)
        self.assertEqual(MODULE.entitlements(self.worker), worker_rights)
        self.assertEqual(MODULE.BUILDER.digest(self.worker), worker_digest)
        result = MODULE.assemble(self.app, enabled=False)
        self.assertEqual(result, {"included": False, "modified": True, "capabilityEnabled": False})
        self.assertIsNone(MODULE.inspect(self.app))
        self.assertFalse((self.app / MODULE.HELPER).exists())
        self.assertFalse((self.app / MODULE.RECORD).exists())
        self.assertEqual(MODULE.entitlements(self.app), owner_rights)
        self.assertEqual(MODULE.BUILDER.digest(self.worker), worker_digest)
        MODULE.command(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(self.app)])

    def test_default_embeds_enabled_helper(self):
        result = MODULE.assemble(self.app, build_helper=self.build_helper)
        self.assertTrue(result["included"])
        self.assertTrue(result["capabilityEnabled"])
        self.assertFalse(MODULE.inspect(self.app)["helper"]["systemAcceptance"])

    def test_repeated_candidate_build_keeps_one_helper(self):
        self.embed()
        self.embed()
        self.assertEqual(MODULE.inspect(self.app)["helper"], self.receipt)
        self.assertEqual([path.name for path in (self.app / "Contents/XPCServices").iterdir()],
                         [MODULE.BUILDER.SERVICE + ".xpc"])

    def test_unmanaged_helper_is_preserved_for_default_and_candidate_modes(self):
        helper = self.app / MODULE.HELPER
        helper.mkdir(parents=True)
        unknown = helper / "owner-file"
        unknown.write_bytes(b"keep unknown build content")
        for enabled in [False, True]:
            with self.assertRaises(ValueError):
                MODULE.assemble(self.app, enabled=enabled, build_helper=self.build_helper)
            self.assertEqual(unknown.read_bytes(), b"keep unknown build content")

    def test_modified_recorded_payload_is_not_deleted(self):
        self.embed()
        program = self.app / MODULE.HELPER / "Contents/MacOS/AgentInfoFocusedFill"
        changed = program.read_bytes() + b"synthetic alteration"
        program.write_bytes(changed)
        with self.assertRaises(ValueError):
            MODULE.assemble(self.app)
        self.assertEqual(program.read_bytes(), changed)
        self.assertTrue((self.app / MODULE.RECORD).is_file())

    def test_unknown_resources_and_redirected_service_directory_are_preserved(self):
        resources = self.app / MODULE.RECORD.parent
        resources.mkdir()
        unknown = resources / "owner-file"
        unknown.write_bytes(b"keep")
        with self.assertRaises(ValueError):
            self.embed()
        self.assertEqual(unknown.read_bytes(), b"keep")
        unknown.unlink()
        resources.rmdir()
        outside = Path(self.work.name) / "outside"
        outside.mkdir()
        (self.app / "Contents/XPCServices").symlink_to(outside, target_is_directory=True)
        with self.assertRaises(ValueError):
            self.embed()
        self.assertEqual(list(outside.iterdir()), [])

    def test_outside_build_app_is_refused_before_any_changes(self):
        with tempfile.TemporaryDirectory() as name:
            outside = Path(name) / "info_desktop.app"
            outside.mkdir()
            (outside / "owner-file").write_bytes(b"keep")
            with self.assertRaises(ValueError):
                MODULE.assemble(outside, enabled=True)
            self.assertEqual((outside / "owner-file").read_bytes(), b"keep")

    def test_package_outputs_under_build_can_be_inspected_but_not_mutated(self):
        self.embed()
        with tempfile.TemporaryDirectory(prefix="focus-package-read-", dir=ROOT / "build") as name:
            archive = Path(name) / "synthetic.zip"
            extracted = Path(name) / "中文 空格 解压"
            MODULE.command(["/usr/bin/ditto", "-c", "-k", "--keepParent", str(self.app), str(archive)])
            MODULE.command(["/usr/bin/ditto", "-x", "-k", str(archive), str(extracted)])
            package = extracted / "info_desktop.app"
            self.assertEqual(MODULE.inspect(package), MODULE.inspect(self.app))
            with self.assertRaises(ValueError):
                MODULE.assemble(package, enabled=True, build_helper=self.build_helper)
            MODULE.command(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(package)])

    def test_build_root_alias_cannot_grant_access_to_an_outside_app(self):
        with tempfile.TemporaryDirectory() as name:
            outside = Path(name) / "info_desktop.app"
            shutil.copytree(self.app, outside)
            alias = Path(self.work.name) / "build-alias"
            alias.symlink_to(Path(name), target_is_directory=True)
            original = MODULE.ADAPTATION
            try:
                MODULE.ADAPTATION = alias
                with self.assertRaises(ValueError):
                    MODULE.assemble(alias / "info_desktop.app", enabled=True, build_helper=self.build_helper)
                MODULE.command(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(outside)])
            finally:
                MODULE.ADAPTATION = original


if __name__ == "__main__":
    unittest.main()
