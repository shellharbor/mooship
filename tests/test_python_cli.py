"""Exercise installer boundaries and backend forwarding without changing the server."""

from contextlib import redirect_stderr, redirect_stdout
import hashlib
import io
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from mooship import cli, install


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.archive = self.root / "mooship-1.2.2.tar.gz"
        self.destination = self.root / "toolkit"

    def archive_with(self, extra=(), version="1.2.2"):
        with tarfile.open(self.archive, "w:gz") as archive:
            for name in install.REQUIRED_FILES:
                data = (version + "\n").encode() if name == "VERSION" else b"fixture\n"
                member = tarfile.TarInfo(f"mooship-1.2.2/{name}")
                member.size = len(data)
                member.mode = 0o7777 if name.endswith(".sh") else 0o666
                archive.addfile(member, io.BytesIO(data))
            for member, data in extra:
                archive.addfile(member, io.BytesIO(data) if data is not None else None)
        return self.archive

    def fake_download(self, url, destination, limit=install.MAX_DOWNLOAD):
        if url.endswith(".sha256"):
            digest = hashlib.sha256(self.archive.read_bytes()).hexdigest()
            destination.write_text(f"{digest}  {self.archive.name}\n", encoding="ascii")
        else:
            destination.write_bytes(self.archive.read_bytes())

    def perform(self):
        with patch.object(install, "download", side_effect=self.fake_download):
            return install.install_native("1.2.2", str(self.destination))

    def test_verified_install_and_repeat_preserve_existing_files(self):
        self.archive_with()
        self.assertEqual(self.perform(), self.destination)
        self.assertEqual((self.destination / "VERSION").read_text().strip(), "1.2.2")
        if os.name == "posix":
            self.assertEqual((self.destination / "deploy-moodle.sh").stat().st_mode & 0o7777, 0o755)
        with patch.object(install, "download") as download:
            with self.assertRaisesRegex(ValueError, "already exists"):
                install.install_native("1.2.2", str(self.destination))
            download.assert_not_called()
        self.assertEqual((self.destination / "VERSION").read_text().strip(), "1.2.2")

    def test_rejects_checksum_mismatch_and_other_filename_before_destination_creation(self):
        self.archive_with()
        checksum = self.root / "sum"
        for content in (f"{'0' * 64}  {self.archive.name}",
                        f"{'0' * 64}  different.tar.gz", "malformed"):
            with self.subTest(content=content):
                checksum.write_text(content)
                with self.assertRaises(ValueError):
                    install.verify_checksum(self.archive, checksum, self.archive.name)
        self.assertFalse(self.destination.exists())

    def test_checksum_failure_does_not_publish(self):
        self.archive_with()
        with patch.object(install, "download", side_effect=self.fake_download), \
                patch.object(install, "verify_checksum", side_effect=ValueError("bad checksum")):
            with self.assertRaises(ValueError):
                install.install_native("1.2.2", str(self.destination))
        self.assertFalse(self.destination.exists())

    @unittest.skipUnless(os.name == "posix", "POSIX modes")
    def test_permissive_umask_cannot_make_the_toolkit_world_writable(self):
        self.archive_with()
        previous = os.umask(0)
        try:
            self.perform()
        finally:
            os.umask(previous)
        for path in (self.destination, self.destination / "moodle", self.destination / "lib"):
            self.assertEqual(path.stat().st_mode & 0o7777, 0o755)
        self.assertEqual((self.destination / "VERSION").stat().st_mode & 0o7777, 0o644)

    def test_rejects_links_traversal_absolute_duplicate_and_special_members(self):
        for name, kind in (("mooship-1.2.2/../../escape", tarfile.REGTYPE),
                           ("/escape", tarfile.REGTYPE),
                           ("other/file", tarfile.REGTYPE),
                           ("mooship-1.2.2/link", tarfile.SYMTYPE),
                           ("mooship-1.2.2/hard", tarfile.LNKTYPE),
                           ("mooship-1.2.2/fifo", tarfile.FIFOTYPE),
                           ("mooship-1.2.2/VERSION", tarfile.REGTYPE)):
            with self.subTest(name=name, kind=kind):
                member = tarfile.TarInfo(name)
                member.type = kind
                member.linkname = "/tmp/escape"
                self.archive_with([(member, b"" if kind == tarfile.REGTYPE else None)])
                with self.assertRaises(ValueError):
                    self.perform()
                self.assertFalse(self.destination.exists())
                self.assertFalse((self.root / "escape").exists())

    def test_rejects_mismatched_version_missing_files_and_expansion_limit(self):
        self.archive_with(version="9.9.9")
        with self.assertRaisesRegex(ValueError, "VERSION"):
            self.perform()
        with tarfile.open(self.archive, "w:gz"):
            pass
        with self.assertRaisesRegex(ValueError, "missing"):
            self.perform()
        self.archive_with()
        with patch.object(install, "MAX_EXPANDED", 1):
            with self.assertRaisesRegex(ValueError, "size limit"):
                self.perform()
        self.assertFalse(self.destination.exists())

    @unittest.skipUnless(os.name == "posix", "POSIX symlinks")
    def test_refuses_dangling_symlink_and_symlink_parent(self):
        self.destination.symlink_to(self.root / "missing")
        with self.assertRaisesRegex(ValueError, "symbolic"):
            install.installation_path(str(self.destination))
        self.destination.unlink()
        self.destination.symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symbolic"):
            install.installation_path(str(self.destination / "new"))

    def test_concurrent_install_cannot_replace_existing_destination(self):
        self.archive_with()
        original = install.unpack_release

        def concurrent(*args):
            result = original(*args)
            self.destination.mkdir()
            (self.destination / "sentinel").write_text("keep")
            return result

        with patch.object(install, "download", side_effect=self.fake_download), \
                patch.object(install, "unpack_release", side_effect=concurrent):
            with self.assertRaises(FileExistsError):
                install.install_native("1.2.2", str(self.destination))
        self.assertEqual((self.destination / "sentinel").read_text(), "keep")

    def test_bad_version_and_paths_are_rejected(self):
        for value in ("latest", "../1.2.2", "1.2", "v1.2.2", "1.2.2;touch bad"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                install.release_version(value)
        for value in ("relative", "/tmp/../opt/mooship", "/tmp/a,b", "/tmp/a\nb"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                install.absolute_path(value)

    def test_failed_copy_leaves_a_marker_and_existing_path_is_refused(self):
        self.archive_with()
        with patch.object(install, "download", side_effect=self.fake_download), \
                patch.object(install.shutil, "copytree", side_effect=OSError("disk full")):
            with self.assertRaises(OSError):
                install.install_native("1.2.2", str(self.destination))
        self.assertTrue((self.destination / ".mooship-installing").is_file())
        with self.assertRaisesRegex(ValueError, "already exists"):
            self.perform()

    def test_http_download_and_downgrade_redirect_are_rejected(self):
        with self.assertRaises(ValueError):
            install.download("http://example.test/file", self.root / "download")
        with self.assertRaises(ValueError):
            install.HTTPSRedirects().redirect_request(None, None, 302, "", {}, "http://example.test/file")

    def test_download_size_limit_leaves_no_installation(self):
        response = io.BytesIO(b"too large")
        with patch.object(install, "build_opener") as opener:
            opener.return_value.open.return_value = response
            with self.assertRaisesRegex(ValueError, "size or time"):
                install.download("https://example.test/file", self.root / "download", limit=2)
        self.assertFalse(self.destination.exists())


class CLITests(unittest.TestCase):
    def call(self, arguments):
        output, errors = io.StringIO(), io.StringIO()
        with redirect_stdout(output), redirect_stderr(errors):
            status = cli.main(arguments)
        return status, output.getvalue(), errors.getvalue()

    def test_install_preview_never_downloads_or_writes(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "new"
            with patch.object(cli, "install_native") as install_native:
                status, output, _ = self.call(["install", "--directory", str(destination), "--dry-run"])
            self.assertEqual(status, 0)
            self.assertIn("Would download and verify Mooship", output)
            install_native.assert_not_called()
            self.assertFalse(destination.exists())

    def test_native_forwarding_keeps_metacharacters_separate_and_private(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "VERSION").write_text("1.2.0", encoding="ascii")
            for command, filename in cli.COMMANDS.items():
                (root / "lib").mkdir(exist_ok=True)
                (root / "lib/runtime_policy.py").touch()
                (root / "moodle/.docker/php").mkdir(parents=True, exist_ok=True)
                (root / "moodle/.docker/php/runtime-policy.json").write_text("{}", encoding="ascii")
                (root / filename).write_text("#!/bin/bash\n", encoding="ascii")
                with self.subTest(command=command), patch.object(cli.sys, "platform", "linux"), \
                        patch.object(cli.shutil, "which", return_value="/bin/bash"), \
                        patch.object(cli.os, "execvp") as execute:
                    status, output, errors = self.call([
                        command, "--directory", directory, "--", "--slug", "demo", "secret;$(touch nope)",
                    ])
                self.assertEqual(status, 0)
                execute.assert_called_once_with("bash", [
                    "bash", str(root / filename), "--slug", "demo", "secret;$(touch nope)",
                ])
                self.assertEqual(output + errors, "")

    def test_legacy_toolkits_cannot_deploy_activate_or_restore_but_remain_readable(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "VERSION").write_text("1.2.0", encoding="ascii")
            for command in ("deploy", "activate", "restore"):
                with self.subTest(command=command), patch.object(cli.os, "execvp") as execute:
                    status, _, errors = self.call([command, "--directory", directory])
                    self.assertEqual(status, 1)
                    self.assertIn("mandatory PHP security policy", errors)
                    execute.assert_not_called()
            self.assertEqual(cli.toolkit_root(directory, require_policy=False), root)

    def test_partial_and_missing_toolkits_are_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.assertEqual(self.call(["doctor", "--directory", directory])[0], 1)
            (root / "VERSION").write_text("1.2.0", encoding="ascii")
            (root / ".mooship-installing").touch()
            status, _, error = self.call(["doctor", "--directory", directory])
            self.assertEqual(status, 1)
            self.assertIn("incomplete", error)

    def test_toolkit_version_reads_selected_release(self):
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / "VERSION").write_text("1.1.2", encoding="ascii")
            status, output, _ = self.call(["toolkit-version", "--directory", directory])
            self.assertEqual((status, output.strip()), (0, "1.1.2"))
            self.assertEqual(self.call(["toolkit-version", "--directory", directory, "--", "unexpected"])[0], 1)

    def test_server_operations_explain_unsupported_platform(self):
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / "VERSION").write_text("1.2.0", encoding="ascii")
            with patch.object(cli.sys, "platform", "win32"):
                status, _, error = self.call(["doctor", "--directory", directory])
            self.assertEqual(status, 1)
            self.assertIn("Linux server over SSH", error)

    @unittest.skipUnless(sys.platform == "linux", "Requires Linux Bash and process signals")
    def test_real_backend_exit_status_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "VERSION").write_text("1.2.0", encoding="ascii")
            (root / "doctor.sh").write_text("exit 2\n", encoding="ascii")
            process = subprocess.run(
                [sys.executable, "-m", "mooship", "doctor", "--directory", directory],
                env={**os.environ, "PYTHONPATH": str(Path(__file__).resolve().parents[1] / "src")},
                capture_output=True, check=False,
            )
            self.assertEqual(process.returncode, 2)
