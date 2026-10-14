"""Resource profiles, outgoing mail, backup retention and scheduling, and doctor.sh."""

import os
from pathlib import Path
import stat

from test_scripts import ROOT, BashTestCase

PARSE = "parse_args --slug test --domain test.example --db-type postgres --no-ssl "


class ProfileTests(BashTestCase):
    def profile(self, memory_kib, existing_projects):
        (self.directory / "meminfo").write_text("MemTotal: {} kB\nMemFree: 1 kB\n".format(memory_kib),
                                                encoding="utf-8")
        for index in range(existing_projects):
            project = self.www / "site{}".format(index)
            project.mkdir()
            (project / "docker-compose.yml").write_text("services: {}\n", encoding="utf-8")
        (self.www / "nginxproxy").mkdir()
        (self.www / "nginxproxy/docker-compose.yml").write_text("services: {}\n", encoding="utf-8")
        result = self.bash('''PROFILE=auto; select_resource_profile
printf 'P=%s %s %s %s %s\\n' "$PROFILE" "$PHP_FPM_MAX_CHILDREN" "$PHP_FPM_START_SERVERS" \\
  "$PHP_FPM_MIN_SPARE_SERVERS" "$PHP_FPM_MAX_SPARE_SERVERS"
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        return [line for line in result.stdout.splitlines() if line.startswith("P=")][0]

    def test_auto_profile_divides_host_memory_among_projects(self):
        # 8 GiB; nginxproxy is not a project
        self.assertEqual(self.profile(8 * 1024 * 1024, 0), "P=large 32 8 4 16")

    def test_auto_profile_with_another_project(self):
        self.assertEqual(self.profile(8 * 1024 * 1024, 1), "P=medium 16 4 2 8")

    def test_auto_profile_on_a_crowded_host(self):
        self.assertEqual(self.profile(8 * 1024 * 1024, 3), "P=small 8 2 1 4")

    def test_unreadable_memory_falls_back_to_small(self):
        result = self.bash('PROFILE=auto; select_resource_profile; echo "P=$PROFILE $PHP_FPM_MAX_CHILDREN"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("P=small 8", result.stdout)

    def test_profile_values_are_written_for_the_selected_database(self):
        self.project.mkdir()
        for engine, native, present, absent in (
                ("postgres", "false", "PG_SHARED_BUFFERS=1GB\n", "MYSQL_INNODB"),
                ("mysql", "false", "MYSQL_INNODB_BUFFER_POOL_SIZE=2G\n", "PG_SHARED_BUFFERS"),
                ("postgres", "true", "PHP_FPM_MAX_CHILDREN=32\n", "PG_SHARED_BUFFERS")):
            with self.subTest(engine=engine, native=native):
                result = self.bash('''PROJECT_DIR="$WWW_DIR/test"; DB_TYPE=''' + engine + '''
DB_NATIVE=''' + native + '''; PROFILE=large; select_resource_profile >/dev/null; write_project_env''')
                self.assertEqual(result.returncode, 0, result.stderr)
                env = (self.project / ".env").read_text()
                self.assertIn("MOOSHIP_PROFILE=large\n", env)
                self.assertIn(present, env)
                self.assertNotIn(absent, env)

    def test_unknown_profile_is_rejected(self):
        result = self.bash(PARSE + "--profile huge")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--profile", result.stdout + result.stderr)


class MailTests(BashTestCase):
    def parse(self, flags):
        return self.bash(PARSE + flags + '\nprintf "SECURE=%s\\n" "$SMTP_SECURE"')

    def test_encryption_defaults_follow_the_port(self):
        for flags, expected in (("--smtp-host smtp.example.com:587", "SECURE=tls"),
                                ("--smtp-host smtp.example.com:465", "SECURE=ssl"),
                                ("--smtp-host relay.local --smtp-secure none", "SECURE=none"),
                                ("", "SECURE=")):
            with self.subTest(flags=flags):
                result = self.parse(flags)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(expected + "\n", result.stdout)

    def test_invalid_mail_settings_are_rejected_before_deployment(self):
        for flags in ("--smtp-user mailer",
                      "--smtp-host 'smtp example.com'",
                      "--smtp-host smtp.example.com --smtp-secure starttls",
                      "--smtp-host smtp.example.com --smtp-password Secret",
                      "--smtp-host smtp.example.com --smtp-user 'mail er'",
                      "--moodle-admin-email not-an-address",
                      "--noreply-email 'noreply@example'",
                      "--redis-password 'Bad$Password'",
                      "--redis-password \"quote'd\""):
            with self.subTest(flags=flags):
                self.assertNotEqual(self.parse(flags).returncode, 0)

    def test_admin_email_flag_reaches_the_installer(self):
        self.project.mkdir()
        (self.project / "public_html").mkdir()
        (self.project / "public_html/config.php").write_text("<?php\n", encoding="utf-8")
        (self.project / ".env").write_text("SITE_HOST=test.example\n", encoding="utf-8")
        result = self.bash('''PROJECT_DIR="$WWW_DIR/test"; DOMAIN=test.example
MOODLE_ADMIN_EMAIL=owner@example.org
docker() { [[ "$*" == *--help* ]] && return 0; printf '%s\\n' "$*" > "$TEST_DIR/install.log"; }
install_moodle_database >/dev/null
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--adminemail=owner@example.org", (self.directory / "install.log").read_text())

    def test_smtp_password_travels_in_the_environment_not_in_arguments(self):
        result = self.bash('''
docker() {
  printf '%s\\n' "$*" > "$TEST_DIR/arguments"
  env | grep '^MOOSHIP_' | sort > "$TEST_DIR/environment"
  cat > "$TEST_DIR/script"
}
SMTP_HOST=smtp.example.com:587; SMTP_SECURE=none; SMTP_USER=mailer
SMTP_PASSWORD='S3cret pass$word'; NOREPLY_EMAIL=noreply@example.com
configure_moodle_mail
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        arguments = (self.directory / "arguments").read_text()
        self.assertTrue(arguments.startswith("exec -i -e MOOSHIP_SMTPHOSTS"))
        self.assertIn("test_php php", arguments)
        self.assertNotIn("S3cret", arguments + result.stdout + result.stderr)
        environment = (self.directory / "environment").read_text().splitlines()
        self.assertIn("MOOSHIP_SMTPPASS=S3cret pass$word", environment)
        self.assertIn("MOOSHIP_SMTPSECURE=", environment)
        self.assertIn("MOOSHIP_NOREPLYADDRESS=noreply@example.com", environment)
        self.assertIn("set_config($name", (self.directory / "script").read_text())

    def test_mail_is_left_alone_without_settings(self):
        result = self.bash('docker() { echo CALLED; }; configure_moodle_mail')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("CALLED", result.stdout)

    def test_failed_mail_configuration_is_fatal(self):
        result = self.bash('docker() { cat >/dev/null; return 1; }; SMTP_HOST=smtp.example.com; '
                           'SMTP_SECURE=tls; configure_moodle_mail; echo SHOULD_NOT_RUN')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("SHOULD_NOT_RUN", result.stdout)


class BackupRetentionTests(BashTestCase):
    NAMES = ["test_20261001_030000.tar.gz", "test_20261002_030000.tar.gz",
             "test_20261003_030000.tar.gz", "test_20261004_030000.tar.gz"]
    OTHERS = ["test2_20261001_030000.tar.gz", "test_before-upgrade.tar.gz", "notes.txt"]

    def archives(self):
        backups = self.directory / "backups"
        backups.mkdir()
        for name in self.NAMES + self.OTHERS:
            (backups / name).write_text(name, encoding="utf-8")
        return backups

    def hook(self, body):
        hook = self.directory / "hook.sh"
        hook.write_text("#!/bin/bash\n" + body + "\n", encoding="utf-8")
        hook.chmod(0o755)
        return hook

    def test_prune_keeps_the_newest_archives_of_this_slug_only(self):
        backups = self.archives()
        result = self.bash('prune_backups test "$TEST_DIR/backups" 2', source="backup.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sorted(path.name for path in backups.iterdir()),
                         sorted(self.NAMES[2:] + self.OTHERS))

    def test_hook_receives_the_archive_before_old_archives_are_pruned(self):
        backups = self.archives()
        self.hook('printf "%s %s\\n" "$1" "$2" > "$(dirname "$0")/hook.log"; ls "$(dirname "$1")" | wc -l >> "$(dirname "$0")/hook.log"')
        result = self.bash('''backup_project() { echo archive > "$2"; }
backup_run test "$TEST_DIR/backups/test_20261005_030000.tar.gz" 1 "$TEST_DIR/hook.sh"
''', source="backup.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        log = (self.directory / "hook.log").read_text().splitlines()
        self.assertEqual(log[0], str(backups / "test_20261005_030000.tar.gz") + " test")
        self.assertEqual(log[1].strip(), str(len(self.NAMES + self.OTHERS) + 1))
        self.assertEqual(sorted(path.name for path in backups.iterdir()),
                         sorted(["test_20261005_030000.tar.gz"] + self.OTHERS))

    def test_failed_hook_keeps_every_archive(self):
        backups = self.archives()
        self.hook("exit 3")
        result = self.bash('''backup_project() { echo archive > "$2"; }
backup_run test "$TEST_DIR/backups/test_20261005_030000.tar.gz" 1 "$TEST_DIR/hook.sh"
''', source="backup.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("hook failed", result.stderr)
        self.assertEqual(len(list(backups.iterdir())), len(self.NAMES + self.OTHERS) + 1)

    def test_unsafe_hooks_and_retention_values_are_rejected(self):
        hook = self.hook("exit 0")
        hook.chmod(0o777)
        relative = os.path.relpath(str(hook), str(ROOT))
        for arguments in ('"$TEST_DIR/hook.sh"', "'" + relative + "'"):
            with self.subTest(hook=arguments):
                result = self.bash('backup_project() { echo CALLED; }; backup_run test "$TEST_DIR/a.tar.gz" "" '
                                   + arguments, source="backup.sh")
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("CALLED", result.stdout)
        result = self.bash('backup_project() { echo CALLED; }; backup_run test "$TEST_DIR/a.tar.gz" 0',
                           source="backup.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("CALLED", result.stdout)


class ScheduleTests(BashTestCase):
    SYSTEMCTL = 'systemctl() { printf "%s\\n" "$*" >> "$TEST_DIR/systemctl.log"; }\n'

    def test_enable_writes_service_and_timer(self):
        self.fixture()
        hook = self.directory / "upload.sh"
        hook.write_text("#!/bin/bash\n", encoding="utf-8")
        hook.chmod(0o750)
        result = self.bash(self.SYSTEMCTL + 'enable_schedule test 02:15 5 "$TEST_DIR/upload.sh"',
                           source="schedule-backup.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        units = self.directory / "systemd"
        service = (units / "mooship-backup-test.service").read_text()
        timer = (units / "mooship-backup-test.timer").read_text()
        self.assertIn("ExecStart=/bin/bash {}/backup.sh --slug test --keep 5 --post-hook {}\n"
                      .format(ROOT, hook), service)
        self.assertIn("Type=oneshot", service)
        self.assertIn("OnCalendar=*-*-* 02:15:00\n", timer)
        self.assertIn("Persistent=true", timer)
        self.assertEqual(stat.S_IMODE((units / "mooship-backup-test.timer").stat().st_mode), 0o644)
        log = (self.directory / "systemctl.log").read_text().splitlines()
        self.assertEqual(log, ["daemon-reload", "enable --now mooship-backup-test.timer"])

    def test_invalid_schedules_are_rejected(self):
        self.fixture()
        for arguments in ("25:00 7", "3:30 7", "03:30 0", "03:30 many"):
            with self.subTest(arguments=arguments):
                result = self.bash(self.SYSTEMCTL + "enable_schedule test " + arguments + ' ""',
                                   source="schedule-backup.sh")
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.directory / "systemd").exists())

    def test_schedule_requires_an_installed_project(self):
        result = self.bash(self.SYSTEMCTL + 'enable_schedule test 03:30 7 ""', source="schedule-backup.sh")
        self.assertNotEqual(result.returncode, 0)

    def test_unschedule_removes_units_and_is_idempotent(self):
        units = self.directory / "systemd"
        units.mkdir()
        for suffix in ("service", "timer"):
            (units / ("mooship-backup-test." + suffix)).write_text("unit", encoding="utf-8")
        (units / "mooship-backup-test2.timer").write_text("other project", encoding="utf-8")
        result = self.bash(self.SYSTEMCTL + "mooship_unschedule_backup test\nmooship_unschedule_backup test",
                           source="schedule-backup.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([path.name for path in units.iterdir()], ["mooship-backup-test2.timer"])
        log = (self.directory / "systemctl.log").read_text().splitlines()
        self.assertEqual(log, ["disable --now mooship-backup-test.timer", "daemon-reload"])


class DoctorTests(BashTestCase):
    def site(self, scheme="https", sites=("test.conf",), backup=True):
        self.fixture()
        with (self.project / ".env").open("a", encoding="utf-8") as stream:
            stream.write("SITE_SCHEME=" + scheme + "\n")
        (self.www / "nginxproxy/sites").mkdir(parents=True)
        for name in sites:
            (self.www / "nginxproxy/sites" / name).write_text("server {}\n", encoding="utf-8")
        (self.directory / "backups").mkdir()
        if backup:
            (self.directory / "backups/test_20261006_030000.tar.gz").write_text("x", encoding="utf-8")

    def doctor(self, php="running", smtp="smtp.example.com:587", checks=0, http="200"):
        return self.bash('''set +e
docker() {
  case "$*" in
    "compose --project-directory "*" config --services")
      printf 'php\\nnginx\\ndb\\ncron\\nredis\\ncertbot\\ncertbot_renew\\npermissions\\n' ;;
    "inspect -f "*" test_php") echo "''' + php + '''" ;;
    "inspect -f "*" test_db") echo running/healthy ;;
    "inspect -f "*) echo running ;;
    "exec test_nginx openssl "*) echo "notAfter=Jan  1 00:00:00 2099 GMT" ;;
    "exec test_php test -f "*) return 0 ;;
    "exec test_php php /var/www/html/admin/cli/checks.php --type=status")
      echo "CHECK SUMMARY"; return ''' + str(checks) + ''' ;;
    "exec -i test_php php") cat >/dev/null; printf '%s' "''' + smtp + '''" ;;
    *) echo "UNEXPECTED docker $*"; return 99 ;;
  esac
}
curl() { printf '%s' "''' + http + '''"; }
systemctl() { return 1; }
doctor_project test false
echo "STATUS=$STATUS"
''', source="doctor.sh")

    def test_healthy_site(self):
        self.site()
        result = self.doctor()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("STATUS=0", result.stdout)
        for text in ("[OK  ] Containers running: php nginx db cron redis certbot_renew",
                     "https://test.example/login/index.php answers 200",
                     "Certificate for test.example is valid for",
                     "[OK  ] Moodle status checks: CHECK SUMMARY",
                     "SMTP smtp.example.com:587", "[OK  ] Last backup"):
            self.assertIn(text, result.stdout)
        self.assertNotIn("UNEXPECTED", result.stdout)

    def test_stopped_container_is_critical(self):
        self.site()
        result = self.doctor(php="exited")
        self.assertIn("[FAIL] Containers not running: php: exited", result.stdout)
        self.assertIn("STATUS=2", result.stdout)

    def test_failed_moodle_checks_and_server_errors_are_critical(self):
        self.site()
        self.assertIn("STATUS=2", self.doctor(checks=2).stdout)
        self.assertIn("STATUS=2", self.doctor(http="502").stdout)

    def test_missing_mail_and_backups_are_warnings(self):
        self.site(backup=False)
        result = self.doctor(smtp="")
        self.assertIn("[WARN] No SMTP server", result.stdout)
        self.assertIn("[WARN] No backups", result.stdout)
        self.assertIn("STATUS=1", result.stdout)

    def test_http_site_skips_the_certificate(self):
        self.site(scheme="http")
        result = self.doctor()
        self.assertIn("http://test.example/login/index.php answers 200", result.stdout)
        self.assertNotIn("Certificate", result.stdout)
        self.assertIn("STATUS=0", result.stdout)

    def test_deactivated_site_skips_runtime_checks(self):
        self.site(sites=("test.conf.disabled",))
        result = self.doctor()
        self.assertIn("[INFO] Deactivated", result.stdout)
        self.assertNotIn("Containers", result.stdout)
        self.assertIn("STATUS=0", result.stdout)

    def test_only_moodle_projects_are_listed(self):
        self.site()
        other = self.www / "static"
        other.mkdir()
        (other / "docker-compose.yml").write_text("services: {}\n", encoding="utf-8")
        result = self.bash("list_projects", source="doctor.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.split(), ["test"])
