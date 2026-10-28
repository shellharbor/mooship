"""Opt-in installation and security checks for the standalone runtime images."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
import uuid


APP_IMAGE = os.environ.get("MOOSHIP_APP_IMAGE", "shellharbor/mooship:dev-moodle4.5.15-php8.3")
WEB_IMAGE = os.environ.get("MOOSHIP_WEB_IMAGE", "shellharbor/mooship:dev-moodle4.5.15-nginx")
PHP82_IMAGE = "php:8.2.35-fpm-bookworm@sha256:4d81f8b24a4b9cbe263093d5e2fbaa49647b1290193488b936f08355933a5060"


def docker(*args, timeout=120, input_text=None):
    return subprocess.run(
        ["docker", *args], capture_output=True, text=True, encoding="utf-8",
        errors="replace", timeout=timeout, check=False, input=input_text,
    )


@unittest.skipUnless(os.environ.get("MOOSHIP_IMAGE_TESTS") == "1", "Set MOOSHIP_IMAGE_TESTS=1")
class RuntimeImageTests(unittest.TestCase):
    def setUp(self):
        for image in (APP_IMAGE, WEB_IMAGE, "postgres:17-alpine", "mysql:8.4"):
            self.assert_ok(docker("image", "inspect", image))
        from test_runtime_policy import POLICY
        actual = docker("run", "--rm", "--read-only", "--network", "none", "--entrypoint", "php",
                        APP_IMAGE, "-r", "echo PHP_VERSION;")
        POLICY.check_php(self.assert_ok(actual).strip())
        self.prefix = "mooship-image-" + uuid.uuid4().hex[:12]
        self.containers = []
        self.volumes = []
        self.network = self.prefix
        self.label = "io.mooship.test=" + self.prefix
        self.secrets = tempfile.TemporaryDirectory(prefix=self.prefix)
        # The fixture directory is bind-mounted as a whole; UID 1000 must traverse it on Linux.
        Path(self.secrets.name).chmod(0o755)
        self.addCleanup(self.secrets.cleanup)
        self.addCleanup(self.cleanup_docker)
        self.assert_ok(docker("network", "create", "--label", self.label, self.network))
        # MySQL's upstream initializer interpolates this into a SQL string.
        # Exercise quotes/backslashes in our secret reader and admin installer separately.
        self.password = "Test_$&-" + uuid.uuid4().hex
        self.admin_password = "Test_Aa9!'$\\&-" + uuid.uuid4().hex
        for name, value in (("db_password", self.password), ("admin_password", self.admin_password)):
            path = Path(self.secrets.name) / name
            path.write_text(value + "\n", encoding="utf-8")
            path.chmod(0o644)

    def cleanup_docker(self):
        for name in reversed(self.containers):
            docker("rm", "--force", "--volumes", name)
        for name in self.volumes:
            docker("volume", "rm", name)
        docker("network", "rm", self.network)

    def assert_ok(self, result):
        self.assertEqual(result.returncode, 0, result.stdout[-6000:] + result.stderr[-6000:])
        return result.stdout

    def run_container(self, role, image, args=(), options=(), detached=False):
        name = self.prefix + "-" + role
        self.containers.append(name)
        command = ["run", "--name", name, "--label", self.label, "--network", self.network]
        if detached:
            command.append("--detach")
        return name, docker(*command, *options, image, *args, timeout=600)

    def runtime_options(self, volume, engine="pgsql"):
        return [
            "--read-only", "--cap-drop=ALL", "--security-opt=no-new-privileges:true",
            "--tmpfs", "/tmp:uid=1000,gid=1000,mode=1770", "--volume", volume + ":/var/moodledata",
            "--mount", "type=bind,source=" + self.secrets.name + ",target=/run/secrets,readonly",
            "--env", "MOODLE_DB_TYPE=" + engine, "--env", "MOODLE_DB_HOST=db",
            "--env", "MOODLE_DB_PASSWORD_FILE=/run/secrets/db_password",
            "--env", "MOODLE_WWWROOT=http://web:8080",
        ]

    def test_web_liveness_is_healthy_without_a_database(self):
        name, result = self.run_container("web-liveness", WEB_IMAGE, options=[
            "--read-only", "--cap-drop=ALL", "--security-opt=no-new-privileges:true",
            "--tmpfs", "/tmp:uid=1000,gid=1000,mode=1770",
            "--env", "MOOSHIP_FPM_UPSTREAM=127.0.0.1:9000",
        ], detached=True)
        self.assert_ok(result)
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            status = self.assert_ok(docker("inspect", "--format", "{{.State.Health.Status}}", name)).strip()
            if status == "healthy":
                return
            time.sleep(2)
        self.fail("nginx Docker HEALTHCHECK did not become healthy: " + self.assert_ok(docker("logs", name)))

    def test_php_guard_enforces_every_patch_floor_and_actual_moodle_compatibility(self):
        code = r'''
require '/opt/mooship/check-runtime.php';
$policy = json_decode(file_get_contents('/opt/mooship/runtime-policy.json'), true, 512, JSON_THROW_ON_ERROR);
$floors = ['8.2' => 35, '8.3' => 36, '8.4' => 27, '8.5' => 12];
$accepted = [];
$rejected = [];
foreach ($floors as $branch => $patch) {
    foreach ([$patch, $patch + 1] as $safe) {
        mooship_check_php_version("$branch.$safe", $policy);
        $accepted[] = "$branch.$safe";
    }
    $rejected[] = $branch . '.' . ($patch - 1);
}
foreach (array_merge($rejected, ['7.4.99', '8.0.99', '8.1.99', '8.3.36RC1', '8.6.0', '8.3']) as $unsafe) {
    try {
        mooship_check_php_version($unsafe, $policy);
        throw new LogicException('Guard accepted prohibited PHP: ' . $unsafe);
    } catch (RuntimeException $expected) {
        // The guard rejects the synthetic version; the test itself runs on patched PHP.
    }
}
mooship_check_runtime('4.5.15');
mooship_check_moodle_version('4.3', '8.2', $policy);
mooship_check_moodle_version('4.3.0', '8.2', $policy);
foreach ($policy['moodle_php'] as $moodle => $branches) {
    foreach ($branches as $php) {
        mooship_check_moodle_version($moodle, $php, $policy);
    }
}
foreach (['4.2.99', '4.3', '6.0', '4.5-rc1'] as $moodle) {
    try {
        mooship_check_runtime($moodle);
        throw new LogicException('Guard accepted incompatible Moodle: ' . $moodle);
    } catch (RuntimeException $expected) {
    }
}
echo json_encode(['actual' => PHP_VERSION, 'accepted' => $accepted]);
'''
        _, result = self.run_container("php-policy", APP_IMAGE, ["php", "-r", code],
                                       options=["--read-only", "--env", "PHP_VERSION=8.1.99"])
        response = json.loads(self.assert_ok(result))
        self.assertEqual(response["actual"].split(".")[:2], ["8", "3"])
        self.assertEqual(len(response["accepted"]), 8)

    def test_host_startup_accepts_initial_moodle43_on_patched_php82_and_rejects_other_sources(self):
        self.assert_ok(docker("pull", PHP82_IMAGE, timeout=300))
        policy = Path(__file__).resolve().parents[1] / "moodle/.docker/php"
        with tempfile.TemporaryDirectory(prefix="mooship-moodle-floor-") as temporary:
            source = Path(temporary)
            for release, allowed in (("4.3", True), ("4.3.0", True), ("4.2.99", False), ("5.3", False)):
                with self.subTest(release=release):
                    (source / "version.php").write_text("<?php\n$release = '" + release + " (Build: 20231009)';\n", encoding="utf-8")
                    result = docker("run", "--rm", "--read-only", "--network", "none",
                                    "--mount", "type=bind,source=" + str(policy) + ",target=/opt/mooship,readonly",
                                    "--mount", "type=bind,source=" + str(source) + ",target=/var/www/html,readonly",
                                    "--entrypoint", "/bin/sh", PHP82_IMAGE,
                                    "/opt/mooship/runtime-entrypoint.sh", "php", "-r", "echo PHP_VERSION;")
                    if allowed:
                        self.assertEqual(self.assert_ok(result).strip(), "8.2.35")
                    else:
                        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                        self.assertIn("[ERROR]", result.stderr)

    def test_php82_stdin_database_probe_reports_failures_without_cli_stream_constants(self):
        self.assert_ok(docker("pull", PHP82_IMAGE, timeout=300))
        source = (Path(__file__).resolve().parents[1] / "lib/check-database.php").read_text(encoding="utf-8")
        result = docker("run", "--rm", "-i", "--read-only", "--network", "none", "--entrypoint", "php",
                        "--env", "MOOSHIP_DB_HOST=127.0.0.1", "--env", "MOOSHIP_DB_PORT=9",
                        "--env", "MOOSHIP_DB_TYPE=postgres", PHP82_IMAGE, input_text=source)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("[ERROR] Database probe failed from PHP.", result.stderr)
        self.assertNotIn("Fatal error", result.stdout + result.stderr)

    def test_image_contract_and_invalid_configuration(self):
        self.password = "Test_'$\\&-" + uuid.uuid4().hex
        (Path(self.secrets.name) / "db_password").write_text(self.password + "\n", encoding="utf-8")
        for image in (APP_IMAGE, WEB_IMAGE):
            metadata = json.loads(self.assert_ok(docker("image", "inspect", image)))[0]
            self.assertEqual(metadata["Config"]["User"], "1000:1000")
            self.assertEqual(metadata["Config"]["StopSignal"], "SIGQUIT")
            self.assertIn("Healthcheck", metadata["Config"])
        _, result = self.run_container("help", APP_IMAGE, ["--help"])
        self.assertIn("Mooship Moodle runtime", self.assert_ok(result))
        volume = self.prefix + "-data"
        self.volumes.append(volume)
        self.assert_ok(docker("volume", "create", "--label", self.label, volume))
        options = self.runtime_options(volume)
        code = (
            'require "/opt/mooship/environment.php"; '
            'echo json_encode(["uid" => posix_geteuid(), "writable" => is_writable("/opt/moodle"), '
            '"password" => hash("sha256", \\Mooship\\settings()["password"]), '
            '"modules" => get_loaded_extensions()]);'
        )
        _, result = self.run_container("contract", APP_IMAGE, ["php", "-r", code], options)
        contract = json.loads(self.assert_ok(result))
        _, patch = self.run_container("php-patch", APP_IMAGE, ["php", "-r", "echo PHP_VERSION;"])
        from test_runtime_policy import POLICY
        POLICY.check_php(self.assert_ok(patch).strip())
        self.assertEqual(contract["uid"], 1000)
        self.assertFalse(contract["writable"])
        self.assertEqual(contract["password"], hashlib.sha256(self.password.encode()).hexdigest())
        self.assertTrue({"sodium", "intl", "mysqli", "pgsql", "redis", "soap", "gd", "zip"}
                        .issubset(contract["modules"]))
        _, result = self.run_container("conflict", APP_IMAGE, ["fpm"], [
            *options, "--env", "MOODLE_DB_PASSWORD=" + self.password,
        ])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not both", result.stderr)
        self.assertNotIn(self.password, result.stderr + result.stdout)
        _, result = self.run_container("bad-url", APP_IMAGE, ["fpm"], [
            *options, "--env", "MOODLE_WWWROOT=http://web:8080/subdirectory",
        ])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("MOODLE_WWWROOT", result.stderr)
        _, result = self.run_container("bad-workers", APP_IMAGE, ["fpm"], [
            *options, "--env", "PHP_FPM_MAX_CHILDREN=1",
        ])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("PHP_FPM_MAX_CHILDREN", result.stderr)

    def check_database_installation(self, engine):
        volume = self.prefix + "-data"
        self.volumes.append(volume)
        self.assert_ok(docker("volume", "create", "--label", self.label, volume))
        if engine == "pgsql":
            image = "postgres:17-alpine"
            environment = ["POSTGRES_USER=moodle", "POSTGRES_DB=moodle", "POSTGRES_PASSWORD=" + self.password]
            probe = ["pg_isready", "-U", "moodle", "-d", "moodle", "-h", "127.0.0.1"]
            query = ["psql", "-U", "moodle", "-d", "moodle", "-c"]
        else:
            image = "mysql:8.4"
            environment = ["MYSQL_USER=moodle", "MYSQL_DATABASE=moodle", "MYSQL_PASSWORD=" + self.password,
                           "MYSQL_ROOT_PASSWORD=" + uuid.uuid4().hex]
            probe = ["sh", "-c", 'MYSQL_PWD="$MYSQL_PASSWORD" mysql -umoodle -h127.0.0.1 -Dmoodle -e "SELECT 1"']
            query = ["sh", "-c", 'MYSQL_PWD="$MYSQL_PASSWORD" mysql -umoodle -h127.0.0.1 -Dmoodle -e "$1"', "sh"]
        db_options = ["--network-alias", "db"]
        for setting in environment:
            db_options.extend(["--env", setting])
        db, result = self.run_container("db", image, options=db_options, detached=True)
        self.assert_ok(result)
        deadline = time.monotonic() + 180
        while docker("exec", db, *probe).returncode != 0:
            state = json.loads(self.assert_ok(docker("inspect", db)))[0]["State"]
            if not state["Running"]:
                self.fail("Database exited during startup: " + docker("logs", db).stderr[-3000:])
            if time.monotonic() > deadline:
                self.fail("Database did not start: " + docker("logs", db).stdout[-3000:])
            time.sleep(2)
        options = self.runtime_options(volume, engine)
        _, result = self.run_container("before-install", APP_IMAGE, ["fpm"], options)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Install the database first", result.stderr)
        install_options = [*options, "--env", "MOODLE_AGREE_LICENSE=true", "--env",
                           "MOODLE_ADMIN_EMAIL=admin@example.org", "--env",
                           "MOODLE_ADMIN_PASSWORD_FILE=/run/secrets/admin_password"]
        install, result = self.run_container("install", APP_IMAGE, ["install"], install_options)
        self.assert_ok(result)
        self.assertNotIn(self.admin_password, result.stdout + result.stderr)
        inspect = self.assert_ok(docker("inspect", install))
        self.assertNotIn(self.admin_password, inspect)
        _, result = self.run_container("install-again", APP_IMAGE, ["install"], install_options)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("empty database", result.stderr)
        app, result = self.run_container("app", APP_IMAGE, options=[*options, "--network-alias", "app"], detached=True)
        self.assert_ok(result)
        deadline = time.monotonic() + 30
        while docker("exec", app, "mooship-healthcheck").returncode != 0:
            if time.monotonic() > deadline:
                self.fail("FPM did not start: " + docker("logs", app).stderr[-3000:])
            time.sleep(1)
        web, result = self.run_container("web", WEB_IMAGE, options=[
            "--network-alias", "web", "--read-only", "--cap-drop=ALL",
            "--security-opt=no-new-privileges:true", "--tmpfs", "/tmp:uid=1000,gid=1000,mode=1770",
            "--volume", volume + ":/var/moodledata:ro",
        ], detached=True)
        self.assert_ok(result)
        deadline = time.monotonic() + 30
        while docker("exec", web, "wget", "-qO-", "http://web:8080/healthz").returncode != 0:
            if time.monotonic() > deadline:
                self.fail("nginx did not start: " + docker("logs", web).stderr[-3000:])
            time.sleep(1)
        self.assertIn("ready", self.assert_ok(docker("exec", web, "wget", "-qO-", "http://web:8080/readyz")))
        login = self.assert_ok(docker("exec", web, "wget", "-qO-", "http://web:8080/login/index.php"))
        self.assertIn('name="username"', login)
        for path in ("/config.php", "/config.php/test", "/admin/cli/install_database.php", "/dataroot/test", "/.git/config"):
            result = docker("exec", web, "wget", "-S", "-O", "/dev/null", "http://web:8080" + path)
            self.assertNotEqual(result.returncode, 0, path)
            self.assertIn("404", result.stderr, path)
        _, result = self.run_container("cron", APP_IMAGE, ["cron-once"], options)
        self.assert_ok(result)
        self.assert_ok(docker("stop", "--time", "30", db))
        self.assert_ok(docker("exec", app, "mooship-healthcheck"))
        result = docker("exec", web, "wget", "-S", "-O", "/dev/null", "http://web:8080/readyz")
        self.assertIn("503", result.stderr)
        self.assert_ok(docker("start", db))
        deadline = time.monotonic() + 90
        while docker("exec", app, "mooship", "check").returncode != 0:
            self.assertLess(time.monotonic(), deadline, "Readiness did not recover")
            time.sleep(2)
        self.assert_ok(docker("exec", db, *query, "UPDATE mdl_config SET value='0' WHERE name='version'"))
        _, result = self.run_container("wrong-version", APP_IMAGE, ["fpm"], options)
        self.assertNotEqual(result.returncode, 0)
        for name in (web, app):
            self.assert_ok(docker("stop", "--time", "30", name))
            state = json.loads(self.assert_ok(docker("inspect", name)))[0]["State"]
            self.assertEqual(state["ExitCode"], 0, state)
            self.assertFalse(state["OOMKilled"])

    def test_postgresql_installation(self):
        self.check_database_installation("pgsql")

    def test_mysql_installation(self):
        self.check_database_installation("mysqli")


if __name__ == "__main__":
    unittest.main()
