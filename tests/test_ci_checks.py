"""Behavioral checks for the documentation CI gate."""

import importlib.util
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("mooship_docs", Path(__file__).resolve().parents[1] / ".github/scripts/check_docs.py")
DOCS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DOCS)


class DocumentationChecksTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.document = self.root / "README.md"

    def check(self, text):
        self.document.write_text(text, encoding="utf-8")
        return DOCS.check_document(self.document, self.root)

    def test_existing_files_and_heading_anchors(self):
        target = self.root / "guide with spaces.md"
        target.write_text("# HTTP / HTTPS\n# HTTP / HTTPS\n", encoding="utf-8")
        self.assertEqual(self.check(
            "# Overview\n[Self](#overview)\n[Guide](<guide%20with%20spaces.md#http--https-1>)\n"), [])

    def test_missing_file_and_heading_fail(self):
        errors = self.check("# Overview\n[Missing](missing.md)\n[Wrong](#unknown)\n")
        self.assertEqual(len(errors), 2)
        self.assertIn("missing link target", errors[0])
        self.assertIn("missing heading anchor", errors[1])

    def test_fenced_and_inline_examples_and_external_links_are_ignored(self):
        self.assertEqual(self.check(
            "```markdown\n[Example](missing.md)\n```\n"
            "`[Example](missing.md)`\n[Remote](https://example.com/guide)\n"), [])

    def test_links_outside_repository_fail(self):
        self.assertIn("leaves the repository", self.check("[Outside](../outside.md)\n")[0])

    def test_root_relative_paths_and_html_anchors(self):
        (self.root / "guide.md").write_text('<a id="custom"></a>\n', encoding="utf-8")
        self.assertEqual(self.check("[Guide](/guide.md#custom)\n"), [])

    def test_inline_code_preserves_placeholder_text_in_headings(self):
        self.assertEqual(self.check(
            "# `/var/www/<slug>/config.php`\n[Config](#varwwwslugconfigphp)\n"), [])


@unittest.skipUnless(shutil.which("git"), "Git required for repository inventory checks")
class RepositoryDocumentationChecksTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        subprocess.run(["git", "init", "--quiet", str(self.root)], check=True, capture_output=True)
        self.document = self.root / "README.md"
        self.document.write_text("# Overview\n", encoding="utf-8")
        self.git("add", "README.md")
        (self.root / ".gitignore").write_text("local/\n", encoding="utf-8")
        self.local = self.root / "local"
        self.local.mkdir()
        (self.local / "guide.md").write_text("# Local guide\n", encoding="utf-8")

    def git(self, *arguments):
        return subprocess.run(["git", *arguments], cwd=str(self.root), check=True, capture_output=True)

    def test_existing_ignored_files_and_directories_cannot_satisfy_public_links(self):
        self.document.write_text("[File](local/guide.md)\n[Directory](local/)\n", encoding="utf-8")
        errors = DOCS.check_document(self.document, self.root, DOCS.list_repository_files(self.root))
        self.assertEqual(len(errors), 2)
        self.assertTrue(all("not included in the repository" in error for error in errors))

    def test_pending_public_files_and_directories_are_available(self):
        directory = self.root / "docs"
        directory.mkdir()
        guide = directory / "guide with spaces.md"
        guide.write_text("# Introduction\n", encoding="utf-8")
        self.document.write_text(
            "[Guide](<docs/guide%20with%20spaces.md#introduction>)\n[Directory](docs/)\n", encoding="utf-8")
        self.assertEqual(DOCS.check_document(
            self.document, self.root, DOCS.list_repository_files(self.root)), [])

    def test_tracked_ignored_documents_are_still_checked(self):
        document = self.root / "tracked.md"
        document.write_text("[Missing](missing.md)\n", encoding="utf-8")
        self.git("add", "tracked.md")
        (self.root / ".gitignore").write_text("local/\ntracked.md\n", encoding="utf-8")
        files = DOCS.list_repository_files(self.root)
        self.assertIn(document, files)
        errors = DOCS.check_document(document, self.root, files)
        self.assertEqual(len(errors), 1)
        self.assertIn("missing link target", errors[0])

    def test_command_fails_for_an_existing_ignored_target(self):
        script = self.root / ".github" / "scripts" / "check_docs.py"
        script.parent.mkdir(parents=True)
        shutil.copyfile(DOCS.__file__, script)
        examples = self.root / "examples"
        examples.mkdir()
        (examples / "endpoint-payload.json").write_text("{}\n", encoding="utf-8")
        self.document.write_text("[Local guide](local/guide.md)\n", encoding="utf-8")
        result = subprocess.run([sys.executable, "-B", str(script)], cwd=str(self.root),
                                text=True, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("not included in the repository: local/guide.md", result.stderr)


if __name__ == "__main__":
    unittest.main()
