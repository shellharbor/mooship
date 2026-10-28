"""Refuse failed or unverified dependency installation before application initialization."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(os.name == 'posix' and shutil.which('sh'), 'Requires a Linux shell')
class DependencyTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.folder = Path(temporary.name)
        self.bin = self.folder / 'bin'
        self.bin.mkdir()
        self.project = self.folder / 'moodle'
        self.project.mkdir()
        self.log = self.folder / 'trace'
        self.stub('php', '''case "$1" in
  -r)
    if printf '%s' "$2" | grep -q json_decode; then exit "$METADATA_STATUS"; fi
    echo TRAIT >> "$TRACE"; exit "$TRAIT_STATUS" ;;
  *) echo "COMPOSER $*" >> "$TRACE"; exit "$INSTALL_STATUS" ;;
esac
''')
        self.stub('curl', '''echo "CURL $*" >> "$TRACE"
while [ "$1" != -o ]; do shift; done
printf 'inert fixture' > "$2"
echo "TEMP $2" >> "$TRACE"
exit "$DOWNLOAD_STATUS"
''')
        self.stub('sha256sum', '''read -r checksum path
echo "HASH $checksum" >> "$TRACE"
exit "$HASH_STATUS"
''')

    def stub(self, name, body):
        path = self.bin / name
        path.write_text('#!/bin/sh\n' + body, encoding='utf-8')
        path.chmod(0o755)

    def invoke(self, lock=True, **changes):
        if lock:
            (self.project / 'composer.lock').write_text('{}', encoding='utf-8')
        self.log.write_text('', encoding='utf-8')
        environment = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                           TRACE=str(self.log), METADATA_STATUS='0', TRAIT_STATUS='0',
                           INSTALL_STATUS='0', DOWNLOAD_STATUS='0', HASH_STATUS='0')
        environment.update(changes)
        result = subprocess.run(['sh', str(ROOT / 'lib/install-dependencies.sh'), str(self.project)],
                                env=environment, capture_output=True, text=True, timeout=15)
        trace = self.log.read_text(encoding='utf-8')
        for line in trace.splitlines():
            if line.startswith('TEMP '):
                self.assertFalse(Path(line[5:]).exists(), 'Temporary Composer PHAR must be removed')
        return result, trace

    def test_legacy_manifest_skips_download_and_execution(self):
        result, trace = self.invoke(lock=False, METADATA_STATUS='3')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(trace, '')

    def test_invalid_metadata_refuses_download(self):
        result, trace = self.invoke(METADATA_STATUS='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(trace, '')

    def test_missing_lockfile_refuses_resolution_and_download(self):
        result, trace = self.invoke(lock=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('composer.lock is missing', result.stderr)
        self.assertEqual(trace, '')

    def test_download_checksum_install_and_autoload_failures_are_fatal(self):
        for stage in ('DOWNLOAD_STATUS', 'HASH_STATUS', 'INSTALL_STATUS', 'TRAIT_STATUS'):
            with self.subTest(stage=stage):
                result, trace = self.invoke(**{stage: '17'})
                self.assertNotEqual(result.returncode, 0)
                if stage in ('DOWNLOAD_STATUS', 'HASH_STATUS'):
                    self.assertNotIn('COMPOSER ', trace)

    def test_pinned_verified_install_has_no_developer_code_or_script_execution(self):
        result, trace = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('https://getcomposer.org/download/2.10.3/composer.phar', trace)
        self.assertIn('HASH 7a2d379d5b8ffdaa028580ef26494c36d2feef4b178d3dd1473a4dbc5e17c8d6', trace)
        for option in ('--no-dev', '--no-scripts', '--no-plugins', '--no-interaction'):
            self.assertIn(option, trace)
        self.assertNotIn('--ignore-platform', trace)
        self.assertLess(trace.index('HASH '), trace.index('COMPOSER '))
        self.assertTrue(trace.rstrip().endswith('TRAIT'))
