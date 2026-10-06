import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which("bash") and os.name == "posix", "Linux Bash required")
class ScriptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.www = self.directory / "www"
        self.www.mkdir()
        self.project = self.www / "test"

    def bash(self, script, source="deploy-moodle.sh"):
        prefix = '''set -euo pipefail
source "$MOOSHIP_ROOT/''' + source + '''"
WWW_DIR="$TEST_DIR/www"
PROXY_DIR="$WWW_DIR/nginxproxy"
SLUG=test
'''
        environment = dict(os.environ, MOOSHIP_ROOT=str(ROOT), TEST_DIR=str(self.directory))
        return subprocess.run(["bash", "-s"], input=prefix + script, text=True,
                              capture_output=True, env=environment, cwd=str(ROOT), timeout=45)

    def fixture(self):
        self.project.mkdir()
        (self.project / "public_html").mkdir()
        (self.project / "moodledata").mkdir()
        (self.project / "docker-compose.yml").write_text("services: {}\n", encoding="utf-8")
        (self.project / "public_html" / "config.php").write_text("<?php\n", encoding="utf-8")
        (self.project / "moodledata" / "course.txt").write_text("course content", encoding="utf-8")
        (self.project / ".env").write_text(
            "SITE_HOST=test.example\nDB_NATIVE=false\nDB_POSTGRES_NAME=test\n"
            "MOODLE_VERSION=4.5.0\nPHP_VERSION=83\n", encoding="utf-8")

    def test_repeat_deploy_preserves_data_and_never_calls_docker(self):
        self.fixture()
        result = self.bash('docker() { echo unexpected >> "$TEST_DIR/docker.log"; }; create_project')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.project / "moodledata" / "course.txt").read_text(), "course content")
        self.assertFalse((self.directory / "docker.log").exists())

    def test_reserved_and_traversal_slugs_rejected_in_lifecycle_scripts(self):
        for source in ("remove.sh", "activate.sh", "deactivate.sh"):
            for slug in ("nginxproxy", "../outside", "/tmp/outside", "test/child"):
                with self.subTest(source=source, slug=slug):
                    result = self.bash('parse_args --slug "$BAD_SLUG" --domain test.example'
                                       .replace('"$BAD_SLUG"', "'" + slug + "'"), source=source) if source == "remove.sh" else self.bash(
                                           "parse_args --slug '" + slug + "'", source=source)
                    self.assertNotEqual(result.returncode, 0)

    def test_symlink_project_rejected(self):
        outside = self.directory / "outside"
        outside.mkdir()
        self.project.symlink_to(outside, target_is_directory=True)
        result = self.bash('mooship_project_path test')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(outside.is_dir())

    def test_env_private_and_summary_does_not_print_secrets(self):
        self.project.mkdir()
        result = self.bash('''PROJECT_DIR="$WWW_DIR/test"
DOMAIN=test.example; DB_TYPE=postgres; PHP_VERSION=83
PORT_HTTP=8101; PORT_HTTPS=4101; PORT_PHP=9101; PORT_REDIS=6501; PORT_POSTGRES=5501
REDIS_PASSWORD=SecretRedis; DB_POSTGRES_PASSWORD=SecretDatabase
DB_POSTGRES_USER=test; DB_POSTGRES_NAME=test; MOODLE_ADMIN_PASSWORD=SecretAdmin
MOODLE_ADMIN_USER=admin; MOODLE_ADMIN_EMAIL=admin@test.example
write_project_env; print_summary
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.project / ".env").stat().st_mode & 0o777, 0o600)
        for secret in ("SecretRedis", "SecretDatabase", "SecretAdmin"):
            self.assertNotIn(secret, result.stdout + result.stderr)

    def test_install_failure_is_fatal(self):
        self.fixture()
        result = self.bash('''PROJECT_DIR="$WWW_DIR/test"; DOMAIN=test.example
docker() { if [[ "$*" == *--help* ]]; then echo help; return 0; fi; return 42; }
install_moodle_database
echo SHOULD_NOT_RUN
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("SHOULD_NOT_RUN", result.stdout)

    def test_no_ssl_creates_http_configuration_and_prints_http_urls(self):
        result = self.bash('''
DOMAIN=test.example; DB_TYPE=postgres; PHP_VERSION=83; OBTAIN_SSL=false
DB_POSTGRES_NAME=testsite; DB_POSTGRES_USER=testuser; DB_POSTGRES_PASSWORD=Synthetic_Pg
REDIS_PASSWORD=Synthetic_Redis; MOODLE_ADMIN_USER=admin
PORT_POSTGRES=5543; PORT_MYSQL=3307; PORT_REDIS=6501; PORT_PHP=9101
PORT_HTTP=8101; PORT_HTTPS=4101
create_project
mkdir -p "$PROJECT_DIR/public_html"
touch "$PROJECT_DIR/public_html/version.php"
chown() { :; }
configure_moodle_config
print_summary
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        env = (self.project / ".env").read_text()
        config = (self.project / "public_html/config.php").read_text()
        self.assertIn("SITE_SCHEME=http\n", env)
        self.assertIn("$CFG->wwwroot   = 'http://test.example';", config)
        self.assertIn("http://test.example/login/", result.stdout)
        self.assertNotIn("https://test.example", result.stdout)
        nginx = (self.project / ".config/nginx/_site.conf").read_text()
        self.assertIn("#\tlisten 443 ssl;", nginx)
        self.assertIn("fastcgi_pass             test_php:9000;", nginx)

    def test_https_is_still_the_default_and_flag_order_is_respected(self):
        result = self.bash('''
parse_args --slug test --domain test.example --db-type postgres --ssl-email admin@test.example
printf 'SCHEME=%s\\n' "$(site_scheme)"
parse_args --slug test --domain test.example --db-type postgres --no-ssl
printf 'SCHEME=%s\\n' "$(site_scheme)"
parse_args --slug test --domain test.example --db-type postgres --no-ssl --obtain-ssl --ssl-email admin@test.example
printf 'SCHEME=%s\\n' "$(site_scheme)"
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([line for line in result.stdout.splitlines() if line.startswith("SCHEME=")],
                         ["SCHEME=https", "SCHEME=http", "SCHEME=https"])

    def test_ssl_failure_is_fatal(self):
        self.fixture()
        result = self.bash('''PROJECT_DIR="$WWW_DIR/test"; DOMAIN=test.example; SSL_EMAIL=admin@test.example
docker() { return 42; }
obtain_ssl_certificate
echo SHOULD_NOT_RUN
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("SHOULD_NOT_RUN", result.stdout)

    def test_failed_application_does_not_publish_proxy_configuration(self):
        # Exercise main's ordering with side effects replaced by trace markers.
        result = self.bash('''
for function in check_root parse_args mooship_require_new_project assign_ports select_php_version_for_moodle install_docker mooship_require_docker mooship_require_unused_resources ensure_www_dir init_nginxproxy create_dhparam create_project comment_ssl_blocks create_native_database build_and_start_project install_moodle configure_moodle_config; do
  eval "$function() { :; }"
done
install_moodle_database() { return 42; }
update_proxy_nginx_conf() { echo PUBLISHED; }
update_proxy_docker_compose() { echo PUBLISHED; }
main
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("PUBLISHED", result.stdout)

    def test_activation_failure_keeps_site_disabled(self):
        self.fixture()
        sites = self.www / "nginxproxy/sites"
        sites.mkdir(parents=True)
        disabled = sites / "test.conf.disabled"
        disabled.write_text("unchanged", encoding="utf-8")
        result = self.bash('''
check_root() { :; }; mooship_require_docker() { :; }
start_project_containers() { :; }; restart_project_services() { :; }
docker() {
  case "$*" in
    'compose config --services') printf 'php\\nnginx\\n' ;;
    'compose ps --status running --services') printf 'php\\n' ;;
  esac
}
main --slug test
''', source="activate.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(disabled.read_text(), "unchanged")
        self.assertFalse((sites / "test.conf").exists())

    def test_native_database_rejects_sql_fragments_and_system_names(self):
        for engine, name, user in (("mysql", "site;DROP", "user"),
                                   ("postgres", "site", "user'"),
                                   ("postgres", "template1", "user"),
                                   ("mysql", "site", "root")):
            with self.subTest(engine=engine, name=name, user=user):
                result = self.bash('mooship_validate_database_identifiers "$ENGINE" "$NAME" "$USER_NAME"'
                                   .replace('"$ENGINE"', '"' + engine + '"')
                                   .replace('"$NAME"', '"' + name + '"')
                                   .replace('"$USER_NAME"', '"' + user + '"'))
                self.assertNotEqual(result.returncode, 0)

    def test_remove_never_drops_unowned_native_database(self):
        self.fixture()
        (self.project / ".env").write_text(
            "DB_NATIVE=true\nDB_PORT=5432\nDB_POSTGRES_NAME=another_site\nDB_POSTGRES_USER=another_user\n",
            encoding="utf-8")
        result = self.bash('''PROJECT_DIR="$WWW_DIR/test"
sudo() { echo DROP_WAS_CALLED; }
remove_native_database
''', source="remove.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("DROP_WAS_CALLED", result.stdout)

    def test_native_preflight_failure_does_not_create_project(self):
        result = self.bash('''DB_NATIVE=true; DB_TYPE=postgres; PORT_POSTGRES=5543
for function in check_root parse_args assign_ports select_php_version_for_moodle install_docker mooship_require_docker mooship_require_unused_resources; do
  eval "$function() { :; }"
done
mooship_require_new_native_database() { return 42; }
create_project() { mkdir "$WWW_DIR/test"; }
main
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.project.exists())

    def test_owned_native_removal_uses_selected_port(self):
        self.fixture()
        (self.project / ".env").write_text(
            "DB_NATIVE=true\nDB_PORT=5543\nDB_POSTGRES_NAME=testsite\nDB_POSTGRES_USER=testuser\n",
            encoding="utf-8")
        (self.project / ".mooship-native-database").write_text(
            "postgres:testsite:testuser:5543\n", encoding="utf-8")
        result = self.bash('''PROJECT_DIR="$WWW_DIR/test"
psql() { :; }; sudo() { printf '%s\\n' "$*" >> "$TEST_DIR/sql.log"; }
remove_native_database
''', source="remove.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        statements = (self.directory / "sql.log").read_text().splitlines()
        self.assertEqual(len(statements), 3)
        self.assertTrue(all("--port=5543" in command for command in statements))
        self.assertIn('DROP DATABASE IF EXISTS "testsite"', statements[1])

    @unittest.skipUnless(shutil.which("docker"), "Docker Compose CLI required")
    def test_generated_compose_variants_have_safe_ports_and_restart_policy(self):
        import json
        for engine in ("postgres", "mysql"):
            for native in ("true", "false"):
                with self.subTest(engine=engine, native=native):
                    result = self.bash('''DB_TYPE=''' + engine + '''; DB_NATIVE=''' + native + '''
SLUG="test_${DB_TYPE}_${DB_NATIVE}"; DOMAIN=test.example; PHP_VERSION=83
DB_POSTGRES_NAME=testsite; DB_POSTGRES_USER=testuser; DB_POSTGRES_PASSWORD=Synthetic_Pg
DB_MYSQL_NAME=testsite; DB_MYSQL_USER=testuser; DB_MYSQL_PASSWORD=Synthetic_Mysql
DB_MYSQL_ROOT_PASSWORD=Synthetic_Root; REDIS_PASSWORD=Synthetic_Redis
PORT_POSTGRES=5543; PORT_MYSQL=3307; PORT_REDIS=6501; PORT_PHP=9101
PORT_HTTP=8101; PORT_HTTPS=4101
create_project >/dev/null
docker compose --project-directory "$PROJECT_DIR" -f "$PROJECT_DIR/docker-compose.yml" config --format json
''')
                    self.assertEqual(result.returncode, 0, result.stderr)
                    services = json.loads(result.stdout)["services"]
                    self.assertEqual(services["certbot_renew"]["restart"], "unless-stopped")
                    for service in ("php", "redis", "db"):
                        if service in services:
                            for port in services[service].get("ports", []):
                                self.assertEqual(port["host_ip"], "127.0.0.1")
                    if native == "true":
                        self.assertNotIn("db", services)
                        self.assertNotIn("db", services["nginx"].get("depends_on", {}))
                    else:
                        self.assertIn("healthcheck", services["db"])
                        self.assertEqual(services["db"]["container_name"], "test_" + engine + "_false_db")

    def backup_mock(self, fail=False):
        return '''docker() {
  printf '%s\\n' "$*" >> "$TEST_DIR/docker.log"
  case "$*" in
    'compose ps --status running --services') printf 'php\\ncron\\nnginx\\ncertbot_renew\\n' ;;
    'compose exec -T db sh -c '*) ''' + ("return 42" if fail else "printf 'database payload'") + ''' ;;
    'compose run --rm -T --no-deps --entrypoint tar nginx '*) tar -C "$TEST_DIR/certificates" -cf - . ;;
  esac
}
backup_project test "$TEST_DIR/site.tar.gz"
'''

    def test_backup_contains_database_files_ssl_and_resumes_services(self):
        self.fixture()
        certificates = self.directory / "certificates"
        certificates.mkdir()
        (certificates / "test.pem").write_text("test certificate", encoding="utf-8")
        result = self.bash(self.backup_mock(), source="backup.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        archive = self.directory / "site.tar.gz"
        self.assertEqual(archive.stat().st_mode & 0o777, 0o600)
        target = self.directory / "extracted"
        target.mkdir()
        subprocess.run(["python3", str(ROOT / "lib/state.py"), "extract", str(archive), str(target), "test"], check=True)
        self.assertEqual((target / "database.dump").read_bytes(), b"database payload")
        self.assertEqual((target / "project/moodledata/course.txt").read_text(), "course content")
        log = (self.directory / "docker.log").read_text()
        self.assertIn("compose stop --timeout 30 php cron nginx certbot_renew", log)
        self.assertIn("compose start php cron nginx certbot_renew", log)

    def test_failed_backup_resumes_services_without_publishing_archive(self):
        self.fixture()
        result = self.bash(self.backup_mock(fail=True), source="backup.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.directory / "site.tar.gz").exists())
        self.assertIn("compose start php cron nginx certbot_renew", (self.directory / "docker.log").read_text())
        self.assertFalse(list(self.directory.glob(".mooship-*")))

    def test_restore_and_removal_preserve_existing_data_and_backups(self):
        self.fixture()
        archive = self.directory / "backup.tar.gz"
        archive.write_bytes(b"retained")
        result = self.bash('check_root() { :; }; restore_main --slug test --archive "$TEST_DIR/backup.tar.gz"', source="restore.sh")
        self.assertNotEqual(result.returncode, 0)
        result = self.bash('remove_backup_archive', source="remove.sh")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(archive.read_bytes(), b"retained")
        self.assertEqual((self.project / "moodledata/course.txt").read_text(), "course content")

    def restore_protocol(self, scheme):
        self.fixture()
        with (self.project / ".env").open("a", encoding="utf-8") as stream:
            stream.write("DB_PORT=5432\nDB_POSTGRES_USER=testuser\nDB_POSTGRES_PASSWORD=Synthetic_Pg\n")
            if scheme is not None:
                stream.write("SITE_SCHEME=" + scheme + "\n")
        nginx = self.project / ".config/nginx"
        nginx.mkdir(parents=True)
        shutil.copyfile(ROOT / "moodle/.config/nginx/_site.conf", nginx / "_site.conf")
        if scheme == "http":
            result = self.bash('PROJECT_DIR="$WWW_DIR/test"; enable_http_site')
            self.assertEqual(result.returncode, 0, result.stderr)
            configuration = (nginx / "_site.conf").read_text()
            configuration = configuration.replace("listen 80;", "listen 80;\n    location = /restricted { deny all; }", 1)
            (nginx / "_site.conf").write_text(configuration, encoding="utf-8")
        certificates = self.directory / "certificates"
        certificates.mkdir()
        (certificates / "test.pem").write_text("test certificate", encoding="utf-8")
        backup = self.bash(self.backup_mock(), source="backup.sh")
        self.assertEqual(backup.returncode, 0, backup.stderr)
        shutil.rmtree(self.project)
        (self.directory / "docker.log").unlink()
        return self.bash('''
check_root() { :; }; mooship_require_docker() { :; }; mooship_require_unused_resources() { :; }
mooship_wait_database() { :; }
create_native_database() { :; }; restore_database() { :; }; restart_nginxproxy() { :; }
ensure_project_docker_resources() { cd "$PROJECT_DIR"; }
build_and_start_project() { printf 'MODE=%s\\n' "$(site_scheme)"; }
docker() { printf '%s\\n' "$*" >> "$TEST_DIR/docker.log"; }
restore_main --slug test --archive "$TEST_DIR/site.tar.gz" <<< test
''', source="restore.sh")

    def test_restore_preserves_http_without_requiring_a_certificate(self):
        result = self.restore_protocol("http")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("MODE=http", result.stdout)
        self.assertNotIn("--entrypoint test", (self.directory / "docker.log").read_text())
        self.assertIn("#\tlisten 443 ssl;", (self.project / ".config/nginx/_site.conf").read_text())
        self.assertIn("location = /restricted { deny all; }", (self.project / ".config/nginx/_site.conf").read_text())
        proxy = (self.www / "nginxproxy/sites/test.conf").read_text()
        self.assertIn("#    listen 443 ssl;", proxy)
        self.assertEqual((self.project / "moodledata/course.txt").read_text(), "course content")

    def test_restore_preserves_https(self):
        result = self.restore_protocol("https")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("MODE=https", result.stdout)
        self.assertIn("--entrypoint test", (self.directory / "docker.log").read_text())
        self.assertNotIn("#    listen 443 ssl;", (self.www / "nginxproxy/sites/test.conf").read_text())

    def test_legacy_restore_defaults_to_https(self):
        result = self.restore_protocol(None)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("MODE=https", result.stdout)

    def test_invalid_archive_protocol_is_rejected_before_creating_a_project(self):
        result = self.restore_protocol("invalid")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Invalid site scheme", result.stdout + result.stderr)
        self.assertFalse(self.project.exists())


if __name__ == "__main__":
    unittest.main()
