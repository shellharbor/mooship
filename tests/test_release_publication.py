"""Check release gates and native archive contents without registry credentials."""

import hashlib
import importlib.util
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch


def load_script(name):
    path = Path(__file__).resolve().parents[1] / ".github" / "scripts" / (name + ".py")
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


release = load_script("check_release")
archive = load_script("build_release")


class ReleaseGateTests(unittest.TestCase):
    def test_tag_must_match_the_exact_version(self):
        release.validate_tag("v1.2.0", "1.2.0")
        for value in ("v1.1.2", "1.2.0", "v1.2", "v1.2.0/../main", "v1.2.0\n"):
            with self.subTest(tag=value), self.assertRaises(ValueError):
                release.validate_tag(value, "1.2.0")

    def test_ci_requires_this_commit_and_the_latest_run_to_succeed(self):
        runs = [{"id": index, "name": name, "head_sha": "reviewed", "status": "completed", "conclusion": "success"}
                for index, name in enumerate(sorted(release.REQUIRED))]
        release.check_runs(runs, "reviewed")
        with self.assertRaises(ValueError):
            release.check_runs(runs, "different")
        for status, conclusion in (("in_progress", None), ("completed", "failure"), ("completed", "skipped")):
            latest = {**runs[0], "id": 999, "status": status, "conclusion": conclusion}
            with self.subTest(status=status, conclusion=conclusion), self.assertRaises(ValueError):
                release.check_runs([*runs, latest], "reviewed")

    def test_native_archive_is_reproducible_and_excludes_nonruntime_data(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            names = sorted(archive.FILES | {"lib/common.sh", "moodle/.config/php/mooship.ini", "README.secret"})
            for name in names:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"1.2.0\n" if name == "VERSION" else b"fixture\r\n")
            (root / ".env").write_text("SECRET=synthetic", encoding="ascii")
            inventory = subprocess.CompletedProcess([], 0, stdout=("\0".join(names) + "\0").encode())
            with patch.object(archive.subprocess, "run", return_value=inventory):
                first = archive.build(root, root / "first")
                second = archive.build(root, root / "second")
            self.assertEqual(first.read_bytes(), second.read_bytes())
            digest = hashlib.sha256(first.read_bytes()).hexdigest()
            self.assertEqual(first.with_name(first.name + ".sha256").read_text().strip(), f"{digest}  {first.name}")
            with tarfile.open(first) as source:
                self.assertNotIn("mooship-1.2.0/.env", source.getnames())
                self.assertNotIn("mooship-1.2.0/README.secret", source.getnames())
                script = source.getmember("mooship-1.2.0/deploy-moodle.sh")
                self.assertEqual(script.mode, 0o755)
                self.assertEqual(source.extractfile(script).read(), b"fixture\n")

    def test_missing_native_files_refuse_archive_creation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "VERSION").write_text("1.2.0", encoding="ascii")
            with patch.object(archive.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, stdout=b"VERSION\0")):
                with self.assertRaisesRegex(ValueError, "missing"):
                    archive.build(root, root / "output")
            self.assertFalse((root / "output").exists())
