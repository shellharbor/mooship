"""Behavioral checks for the documentation CI gate."""

import importlib.util
from pathlib import Path
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


if __name__ == "__main__":
    unittest.main()
