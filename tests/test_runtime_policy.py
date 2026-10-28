"""Security-floor and Moodle/PHP compatibility regressions."""

import importlib.util
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import unittest

from test_scripts import BashTestCase

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("runtime_policy", ROOT / "lib/runtime_policy.py")
POLICY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(POLICY)


class RuntimePolicyTests(unittest.TestCase):
    def test_mandatory_patch_floors_and_all_boundary_versions(self):
        expected = {"8.2": "8.2.35", "8.3": "8.3.36", "8.4": "8.4.27", "8.5": "8.5.12"}
        self.assertEqual(json.loads(POLICY.POLICY_PATH.read_text())["minimum_php"], expected)
        for branch, minimum in expected.items():
            with self.subTest(branch=branch):
                POLICY.check_php(minimum)
                patch = int(minimum.split(".")[2])
                POLICY.check_php(f"{branch}.{patch + 1}")
                with self.assertRaises(ValueError):
                    POLICY.check_php(f"{branch}.{patch - 1}")
        for old in ("7.4.99", "8.0.99", "8.1.99", "8.3.36RC1", "8.3", "8.6.0", "9.0.0"):
            with self.subTest(php=old), self.assertRaises(ValueError):
                POLICY.check_php(old)

    def test_moodle_floor_and_known_compatible_branches(self):
        for moodle, selected in (("4.3", "8.2"), ("4.4.0", "8.2"), ("4.5.15", "8.3"),
                                 ("5.0", "8.4"), ("5.1", "8.4"), ("5.2", "8.4"), ("5.3", "8.4")):
            self.assertEqual(POLICY.select(moodle), selected)
        self.assertEqual(POLICY.select("4.5", "82"), "8.2")
        for old in ("3.9", "3.11.18", "4.0", "4.1.99", "4.2.99", "4.3-rc1", "04.3", "6.0"):
            with self.subTest(moodle=old), self.assertRaises(ValueError):
                POLICY.select(old)
        for moodle, php in (("4.3", "8.3"), ("4.5", "8.4"), ("5.2", "8.2"),
                            ("5.3", "8.5"), ("4.5", "8.1"), ("4.5", "8.3.35")):
            with self.subTest(moodle=moodle, php=php), self.assertRaises(ValueError):
                POLICY.select(moodle, php)

    def test_every_host_base_is_pinned_to_a_patched_branch_and_legacy_templates_are_absent(self):
        for branch in ("82", "83", "84"):
            text = (ROOT / f"moodle/.docker/php/php{branch}.Dockerfile").read_text()
            match = re.search(r"^FROM php:([0-9.]+)-fpm-bookworm@sha256:[0-9a-f]{64}$", text, re.MULTILINE)
            self.assertIsNotNone(match)
            POLICY.check_php(match[1])
            self.assertIn("RUN php /opt/mooship/check-runtime.php", text)
            self.assertIn('ENTRYPOINT ["mooship-runtime-entrypoint"]', text)
        for branch in ("74", "80", "81"):
            self.assertFalse((ROOT / f"moodle/.docker/php/php{branch}.Dockerfile").exists())
            self.assertFalse((ROOT / f"moodle/.config/php/php{branch}.ini").exists())

    def test_policy_cli_rejects_unknown_runtime_and_does_not_accept_a_secure_wrong_branch(self):
        cases = ((["select", "4.3", "82"], 0), (["check-runtime", "5.3", "8.4.27"], 0),
                 (["check-runtime", "5.3", "8.2.35"], 1), (["check-php", "8.3.35"], 1),
                 (["select", "4.2"], 1), (["unknown"], 1))
        for arguments, expected in cases:
            with self.subTest(arguments=arguments):
                result = subprocess.run([sys.executable, "-B", str(ROOT / "lib/runtime_policy.py"), *arguments],
                                        text=True, capture_output=True, check=False)
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)

    def test_source_release_is_read_as_data_and_must_agree_with_saved_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaisesRegex(ValueError, "missing"):
                POLICY.check_source(root, "4.5.15", "8.3")
            source = root / "version.php"
            source.write_text("<?php\n$release = '4.5.15 (Build: 20260928)';\n", encoding="utf-8")
            self.assertEqual(POLICY.check_source(root, "4.5.15", "8.3"), "4.5.15")
            with self.assertRaisesRegex(ValueError, "source/metadata mismatch"):
                POLICY.check_source(root, "4.5.14", "8.3")
            (root / "public").mkdir()
            source = root / "public/version.php"
            source.write_text("<?php\n$release = '5.3 (Build: 20261005)';\n", encoding="utf-8")
            self.assertEqual(POLICY.check_source(root, "5.3.0", "8.4"), "5.3")
            with self.assertRaisesRegex(ValueError, "not supported"):
                POLICY.check_source(root, "5.3", "8.2")
            for release in ("4.2.99", "5.3+", "5.3rc1", "unknown"):
                source.write_text("<?php\n$release = '" + release + "';\n", encoding="utf-8")
                with self.subTest(release=release), self.assertRaises(ValueError):
                    POLICY.check_source(root, "5.3.0", "8.4")


class RuntimeLifecycleTests(BashTestCase):
    def test_activation_rejects_old_or_mismatching_installed_source_before_build(self):
        self.fixture()
        for release in ("4.2.99", "5.3.0", "4.5.15"):
            with self.subTest(release=release):
                (self.project / "public_html/version.php").write_text("<?php\n$release = '" + release + "';\n")
                result = self.bash('PROJECT_DIR="$WWW_DIR/test"\n'
                                   'docker() { if [[ "$*" == "compose config --services" ]]; then echo php; '
                                   'else echo DOCKER_MUTATION; fi; }; start_project_containers', source="activate.sh")
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("DOCKER_MUTATION", result.stdout)
    def test_old_moodle_and_incompatible_php_are_rejected_before_creating_resources(self):
        for arguments in ("--moodle-version 4.2.99", "--moodle-version 4.3 --php-version 8.3",
                          "--moodle-version 4.5 --php-version 8.1"):
            with self.subTest(arguments=arguments):
                result = self.bash('docker() { echo DOCKER_CALLED; }; parse_args --slug test '
                                   '--domain test.example ' + arguments)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("DOCKER_CALLED", result.stdout)
                self.assertFalse(self.project.exists())

    def test_activation_rejects_stale_actual_php_before_starting_services(self):
        self.fixture()
        for actual in ("8.1.99", "8.3.35", "8.4.27", "", "8.3.36RC1"):
            with self.subTest(actual=actual):
                result = self.bash('PROJECT_DIR="$WWW_DIR/test"; actual=' + shlex.quote(actual) + '''
docker() {
  printf '%s\\n' "$*" >> "$TEST_DIR/activation.log"
  case "$*" in
    'compose config --services') printf 'php\\ncron\\nnginx\\n' ;;
    'compose run --rm -T --no-deps --entrypoint php php -r echo PHP_VERSION;') printf '%s' "$actual" ;;
  esac
}
start_project_containers
''', source="activate.sh")
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("compose up", (self.directory / "activation.log").read_text())

    def test_activation_builds_and_probes_before_startup_and_html_needs_no_php(self):
        self.fixture()
        for services in ("php\\ncron\\nnginx", "nginx"):
            with self.subTest(services=services):
                log = self.directory / "activation.log"
                log.unlink(missing_ok=True)
                result = self.bash('PROJECT_DIR="$WWW_DIR/test"; TEST_SERVICES=' + shlex.quote(services) + '''
docker() {
  printf '%s\\n' "$*" >> "$TEST_DIR/activation.log"
  case "$*" in
    'compose config --services') printf '%b\\n' "$TEST_SERVICES" ;;
    'compose run --rm -T --no-deps --entrypoint php php -r echo PHP_VERSION;') printf '8.3.36' ;;
  esac
}
start_project_containers
''', source="activate.sh")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                lines = log.read_text().splitlines()
                self.assertEqual(lines[-1], "compose up -d --build")
                if services == "nginx":
                    self.assertEqual(len(lines), 2)
                else:
                    self.assertEqual(lines[1], "compose build --pull php cron")
                    self.assertIn("echo PHP_VERSION;", lines[2])
