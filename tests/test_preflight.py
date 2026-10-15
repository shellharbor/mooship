"""Port preflight, native DB routing, installation state and bounded service readiness."""

import shlex
import shutil
import socket

from test_scripts import BashTestCase


class PreflightTests(BashTestCase):
    def test_every_explicit_port_rejects_invalid_values_before_docker(self):
        for name in ("PORT_HTTP", "PORT_HTTPS", "PORT_PHP", "PORT_REDIS", "PORT_POSTGRES", "PORT_MYSQL"):
            for value in ("abc", "0", "-1", "65536", "123456", "12\n34"):
                with self.subTest(name=name, value=value):
                    result = self.bash(
                        "DB_TYPE=postgres; " + name + "=" + shlex.quote(value) + "\n"
                        'docker() { echo CALLED_DOCKER; }; assign_ports')
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("Invalid port", result.stdout + result.stderr)
                    self.assertNotIn("CALLED_DOCKER", result.stdout)

    def test_proxy_ports_and_duplicate_normalized_ports_are_rejected(self):
        for settings in ("PORT_HTTP=80", "PORT_PHP=443", "PORT_HTTP=08101; PORT_PHP=8101",
                         "DB_NATIVE=true; PORT_HTTP=5432"):
            with self.subTest(settings=settings):
                result = self.bash("DB_TYPE=postgres; " + settings + """
docker() { :; }; mooship_port_available() { return 0; }; assign_ports
""")
                self.assertNotEqual(result.returncode, 0)
                self.assertRegex(result.stdout + result.stderr, "reserved|Duplicate")

    def test_occupied_socket_and_docker_publication_are_detected(self):
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen()
            result = self.bash("mooship_port_available " + str(listener.getsockname()[1]))
            self.assertNotEqual(result.returncode, 0)
        result = self.bash(
            "MOOSHIP_DOCKER_PORTS='0.0.0.0:18101->80/tcp'; mooship_port_available 18101")
        self.assertNotEqual(result.returncode, 0)

    def test_native_listener_is_allowed_and_defaults_are_reserved(self):
        result = self.bash("""DB_TYPE=postgres; DB_NATIVE=true
PORT_HTTP=18101; PORT_HTTPS=14101; PORT_PHP=19101; PORT_REDIS=16501
docker() { printf '0.0.0.0:5432->5432/tcp\\n'; }
mooship_port_available() { [[ "$1" != 5432 ]]; }
assign_ports; printf 'NATIVE=%s\\n' "$PORT_POSTGRES"
""")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("NATIVE=5432", result.stdout)

    def test_automatic_selection_skips_an_explicit_assignment(self):
        result = self.bash("""MOOSHIP_ASSIGNED_PORTS=' 19101'
find_free_port 19101 19102 PHP
""")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "19102")

    def test_native_host_flag_rejects_ignored_or_unsafe_values(self):
        for flags in ("--db-host db.example", "--db-native --db-host 'db;echo injected'",
                      "--db-native --db-host 'db/host'"):
            result = self.bash(
                "parse_args --slug test --domain test.example --db-type postgres --no-ssl " + flags)
            self.assertNotEqual(result.returncode, 0)

    def test_default_native_mapping_and_custom_host_are_used_by_php_and_cron(self):
        for host in ("host.docker.internal", "192.0.2.10"):
            with self.subTest(host=host):
                # Each generation uses a separate temporary project directory.
                result = self.bash("""DB_NATIVE=true; DB_TYPE=postgres; DOMAIN=test.example; PHP_VERSION=83
NATIVE_DB_HOST=""" + shlex.quote(host) + """
DB_POSTGRES_NAME=testsite; DB_POSTGRES_USER=testuser; DB_POSTGRES_PASSWORD=Synthetic_Pg
REDIS_PASSWORD=Synthetic_Redis; PORT_POSTGRES=5543
PORT_HTTP=18101; PORT_HTTPS=14101; PORT_PHP=19101; PORT_REDIS=16501
create_project
mkdir -p "$PROJECT_DIR/public_html"; touch "$PROJECT_DIR/public_html/version.php"
chown() { :; }; configure_moodle_config
""")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                config = (self.project / "public_html/config.php").read_text()
                compose = (self.project / "docker-compose.yml").read_text()
                self.assertIn("$CFG->dbhost    = '" + host + "'", config)
                self.assertIn("DB_HOST=" + host, (self.project / ".env").read_text())
                self.assertEqual(compose.count("host.docker.internal:host-gateway"),
                                 2 if host == "host.docker.internal" else 0)
                shutil.rmtree(self.project)

    def test_database_probe_passes_secret_through_environment_and_selected_endpoint(self):
        for native, host, port in (("true", "host.docker.internal", "5543"), ("false", "test_db", "5432")):
            result = self.bash("""DB_TYPE=postgres; DB_NATIVE=""" + native + """
PORT_POSTGRES=5543; DB_POSTGRES_NAME=testsite; DB_POSTGRES_USER=testuser
DB_POSTGRES_PASSWORD=Synthetic_Probe_Secret
docker() {
  [[ "$MOOSHIP_DB_PASSWORD" == Synthetic_Probe_Secret ]] || return 9
  printf 'ENDPOINT=%s:%s ARGS=%s\\n' "$MOOSHIP_DB_HOST" "$MOOSHIP_DB_PORT" "$*"
}
mooship_check_database connect
""")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("ENDPOINT=" + host + ":" + port, result.stdout)
            self.assertNotIn("Synthetic_Probe_Secret", result.stdout + result.stderr)

    def test_readiness_waits_for_health_and_is_bounded(self):
        result = self.bash("""MOOSHIP_READY_ATTEMPTS=3
docker() {
  if [[ -f "$TEST_DIR/once" ]]; then echo 'running healthy'
  else touch "$TEST_DIR/once"; echo 'running starting'; fi
}
sleep() { echo SLEPT; }
mooship_wait_service php
""")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count("SLEPT"), 1)
        for status in ("running unhealthy", "exited unhealthy"):
            result = self.bash("""MOOSHIP_READY_ATTEMPTS=2
docker() { echo '""" + status + """'; }; sleep() { :; }
mooship_wait_service nginx
""")
            self.assertNotEqual(result.returncode, 0)
            self.assertRegex(result.stderr, "exited|within 4 seconds")

    def test_unreachable_or_partial_database_never_runs_installer(self):
        self.fixture()
        for status in (1, 4):
            result = self.bash('PROJECT_DIR="$WWW_DIR/test"\n'
                               "mooship_check_database() { return " + str(status) + "; }\n"
                               "docker() { echo INSTALLER_CALLED; }; install_moodle_database")
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("INSTALLER_CALLED", result.stdout)

    def test_legacy_redis_readiness_checks_authenticated_ping(self):
        result = self.bash('''PROJECT_DIR="$WWW_DIR/test"; MOOSHIP_READY_ATTEMPTS=2
mooship_read_env() { printf Synthetic_Redis; }
docker() {
  if [[ "$1" == inspect ]]; then echo 'running none';
  else [[ "$REDISCLI_AUTH" == Synthetic_Redis ]] && echo PONG; fi
}
mooship_wait_service redis
''')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_installed_database_skips_the_installer(self):
        self.fixture()
        result = self.bash("""PROJECT_DIR="$WWW_DIR/test"
mooship_check_database() { return 0; }; docker() { echo INSTALLER_CALLED; }
install_moodle_database
""")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("INSTALLER_CALLED", result.stdout)

    def test_nginx_configuration_is_checked_before_reload(self):
        self.project.mkdir()
        result = self.bash('''PROJECT_DIR="$WWW_DIR/test"
docker() { printf '%s\\n' "$*" >> "$TEST_DIR/reload.log"; }
reload_project_nginx
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.directory / 'reload.log').read_text().splitlines(),
                         ['compose exec -T nginx nginx -t', 'compose exec -T nginx nginx -s reload'])
        result = self.bash('''PROJECT_DIR="$WWW_DIR/test"
docker() { [[ "$*" != *'nginx -t' ]] && echo RELOADED; return 42; }
reload_project_nginx
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('RELOADED', result.stdout)
