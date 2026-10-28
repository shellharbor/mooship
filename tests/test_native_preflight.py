"""Real PHP-to-host DB probes against disposable databases published on random ports."""

import json
import os
from pathlib import Path
import subprocess
import time
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]


def docker(*args, timeout=120, input_text=None):
    return subprocess.run(["docker", *args], capture_output=True, text=True, encoding="utf-8",
                          errors="replace", timeout=timeout, check=False, input=input_text)


@unittest.skipUnless(os.environ.get("MOOSHIP_NATIVE_PREFLIGHT_TESTS") == "1", "Opt-in native DB routing checks")
class NativePreflightTests(unittest.TestCase):
    def test_php_authenticates_via_host_gateway_and_refuses_failures(self):
        image = os.environ["MOOSHIP_PREFLIGHT_PHP_IMAGE"]
        from test_runtime_policy import POLICY
        actual = docker("run", "--rm", "--read-only", "--network", "none", "--entrypoint", "php",
                        image, "-r", "echo PHP_VERSION;")
        self.assertEqual(actual.returncode, 0, actual.stderr)
        POLICY.check_php(actual.stdout.strip())
        engine = os.environ.get("MOOSHIP_PREFLIGHT_DB", "postgres")
        name = "mooship-native-probe-" + uuid.uuid4().hex[:12]
        password = "Synthetic_" + uuid.uuid4().hex
        db_image = "postgres:17-alpine" if engine == "postgres" else "mysql:8.4"
        port = "5432" if engine == "postgres" else "3306"
        settings = (["POSTGRES_USER=moodle", "POSTGRES_DB=moodle", "POSTGRES_PASSWORD=" + password]
                    if engine == "postgres" else
                    ["MYSQL_USER=moodle", "MYSQL_DATABASE=moodle", "MYSQL_PASSWORD=" + password,
                     "MYSQL_ROOT_PASSWORD=" + uuid.uuid4().hex])
        for reference in (image, db_image):
            self.assertEqual(docker("image", "inspect", reference).returncode, 0, reference)
        options = ["run", "-d", "--name", name, "--label", "io.mooship.test=" + name,
                   "--publish", "0.0.0.0::" + port]
        for setting in settings:
            options.extend(["--env", setting])
        self.addCleanup(lambda: docker("rm", "-f", "-v", name))
        result = docker(*options, db_image)
        self.assertEqual(result.returncode, 0, result.stderr)
        metadata = json.loads(docker("inspect", name).stdout)[0]
        published = metadata["NetworkSettings"]["Ports"][port + "/tcp"][0]["HostPort"]
        source = (ROOT / "lib/check-database.php").read_text(encoding="utf-8")

        def probe(mode="connect", secret=password):
            args = ["run", "--rm", "-i", "--read-only", "--cap-drop=ALL",
                    "--security-opt=no-new-privileges:true", "--user", "1000:1000",
                    "--label", "io.mooship.test=" + name,
                    "--add-host", "host.docker.internal:host-gateway", "--entrypoint", "php"]
            for setting in ("MOOSHIP_DB_TYPE=" + engine, "MOOSHIP_DB_HOST=host.docker.internal",
                            "MOOSHIP_DB_PORT=" + published, "MOOSHIP_DB_NAME=moodle",
                            "MOOSHIP_DB_USER=moodle", "MOOSHIP_DB_PASSWORD=" + secret,
                            "MOOSHIP_DB_CHECK=" + mode):
                args.extend(["--env", setting])
            return docker(*args, image, input_text=source, timeout=30)

        deadline = time.monotonic() + 180
        while True:
            result = probe()
            if result.returncode == 0:
                break
            self.assertLess(time.monotonic(), deadline, result.stderr)
            time.sleep(2)
        self.assertEqual(probe("tcp").returncode, 0)
        self.assertEqual(probe("installed").returncode, 3)
        denied = probe(secret="Incorrect_" + uuid.uuid4().hex)
        self.assertNotEqual(denied.returncode, 0)
        self.assertNotIn(password, denied.stdout + denied.stderr)
        for sql, expected in (("CREATE TABLE mdl_config (name VARCHAR(64), value VARCHAR(64))", 4),
                              ("INSERT INTO mdl_config VALUES ('version', '2024100715')", 0)):
            command = ("PGPASSWORD=\"$POSTGRES_PASSWORD\" psql -U moodle -d moodle -v ON_ERROR_STOP=1 -c \"$1\""
                       if engine == "postgres" else
                       "MYSQL_PWD=\"$MYSQL_PASSWORD\" mysql -umoodle -Dmoodle -e \"$1\"")
            result = docker("exec", name, "sh", "-c", command, "sh", sql)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = probe("installed")
            self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        self.assertEqual(docker("stop", "--time", "20", name).returncode, 0)
        # Docker's host proxy may accept TCP even after its backend stops.
        self.assertNotEqual(probe().returncode, 0)
