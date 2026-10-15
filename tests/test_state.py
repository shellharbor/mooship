import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("state", ROOT / "lib" / "state.py")
state = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(state)


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def archive(self, entries):
        path = self.root / "backup.tar.gz"
        with tarfile.open(path, "w:gz") as archive:
            for name, content, link in entries:
                member = tarfile.TarInfo(name)
                if link is not None:
                    member.type = tarfile.SYMTYPE
                    member.linkname = link
                    archive.addfile(member)
                else:
                    member.size = len(content)
                    archive.addfile(member, io.BytesIO(content))
        return path

    def test_unsafe_paths_and_links_rejected_before_extraction(self):
        for name, link in (("../outside", None), ("/outside", None),
                           ("project/link", "../../outside"),
                           ("project/link", "/etc/passwd")):
            with self.subTest(name=name, link=link):
                path = self.archive([("project/safe", b"safe", None), (name, b"bad", link)])
                destination = self.root / "target"
                destination.mkdir(exist_ok=True)
                with self.assertRaises(ValueError):
                    state.extract_checked(path, destination)
                self.assertEqual(list(destination.iterdir()), [])

    def test_write_through_symlink_rejected(self):
        path = self.archive([("project/link", b"", "other"),
                             ("project/link/file", b"bad", None)])
        with self.assertRaises(ValueError):
            state.extract_checked(path, self.root / "target")

    def test_duplicate_members_rejected(self):
        path = self.archive([("project/file", b"first", None),
                             ("project/file", b"second", None)])
        with self.assertRaises(ValueError):
            state.extract_checked(path, self.root / "target")

    def fixture(self):
        directory = self.root / "source"
        project = directory / "project"
        (project / "public_html").mkdir(parents=True)
        (project / ".env").write_text(
            "SITE_HOST=test.example\nDB_NATIVE=false\nDB_POSTGRES_NAME=test\n"
            "MOODLE_VERSION=4.5.0\nPHP_VERSION=83\n", encoding="utf-8")
        (project / "docker-compose.yml").write_text("services: {}\n", encoding="utf-8")
        (project / "public_html" / "config.php").write_text("<?php\n", encoding="utf-8")
        (directory / "database.dump").write_bytes(b"PGDMP sample data")
        with tarfile.open(directory / "certificates.tar", "w"):
            pass
        state.write_manifest(directory, "test")
        return directory

    def package(self, directory):
        path = self.root / "backup.tar.gz"
        with tarfile.open(path, "w:gz") as archive:
            for name in ("project", "database.dump", "certificates.tar", "manifest.json"):
                archive.add(directory / name, arcname=name)
        return path

    def test_complete_backup_extracts_and_validates(self):
        directory = self.fixture()
        path = self.package(directory)
        target = self.root / "target"
        target.mkdir()
        state.extract_backup(path, target, "test")
        self.assertEqual((target / "database.dump").read_bytes(), b"PGDMP sample data")
        self.assertEqual(state.read_env(target / "project" / ".env")["SITE_HOST"], "test.example")

    def test_corrupt_dump_and_wrong_slug_rejected(self):
        directory = self.fixture()
        (directory / "database.dump").write_bytes(b"changed")
        path = self.package(directory)
        for slug in ("test", "other"):
            with self.subTest(slug=slug):
                target = self.root / slug
                target.mkdir()
                with self.assertRaises(ValueError):
                    state.extract_backup(path, target, slug)

    def test_env_is_data_and_keeps_equals(self):
        path = self.root / ".env"
        path.write_text("PASSWORD=literal=$(touch hacked)\nPATH=/bad\n", encoding="utf-8")
        self.assertEqual(state.read_env(path)["PASSWORD"], "literal=$(touch hacked)")
        self.assertFalse((self.root / "hacked").exists())


if __name__ == "__main__":
    unittest.main()
