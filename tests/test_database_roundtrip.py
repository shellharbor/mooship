"""Opt-in Docker tests; only synthetic data in newly created, labelled containers."""

import os
from pathlib import Path
import subprocess
import time
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(os.environ.get("MOOSHIP_DOCKER_TESTS") == "1", "Opt-in Docker integration tests")
class DatabaseRoundtripTests(unittest.TestCase):
    def docker(self, *args, data=None, check=True):
        return subprocess.run(["docker", *args], input=data, capture_output=True, check=check)

    def container(self, image, environment, socket_path):
        name = "mooship-test-" + uuid.uuid4().hex[:12]
        token = uuid.uuid4().hex
        options = ["run", "--detach", "--rm", "--name", name, "--network", "none",
                   "--read-only", "--security-opt", "no-new-privileges", "--cap-drop", "ALL"]
        for capability in ("CHOWN", "DAC_OVERRIDE", "SETUID", "SETGID"):
            options.extend(["--cap-add", capability])
        options.extend(["--tmpfs", "/tmp:rw,mode=1777", "--tmpfs",
                        socket_path + ":rw,uid=999,gid=999,mode=0775",
                        "--label", "io.mooship.test=" + token,
                        "--volume", str(ROOT) + ":/mooship:ro"])
        for key, value in environment.items():
            options.extend(["--env", key + "=" + value])
        self.docker(*options, image)

        def cleanup():
            inspected = self.docker("inspect", "--format", '{{index .Config.Labels "io.mooship.test"}}', name, check=False)
            if inspected.returncode == 0 and inspected.stdout.strip() == token.encode():
                self.docker("rm", "--force", name)
        self.addCleanup(cleanup)
        return name

    def wait(self, name, command):
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            if self.docker("exec", name, "sh", "-c", command, check=False).returncode == 0:
                return
            time.sleep(2)
        logs = self.docker("logs", name, check=False)
        self.fail("Test database did not start: " + logs.stdout.decode(errors="replace")[-1000:])

    def restore(self, name, db_type, dump):
        # Invoke the production restore_database function; map its docker exec to this test DB.
        script = '''source /mooship/restore.sh
DB_TYPE=''' + db_type + '''
DB_NATIVE=false
export POSTGRES_DB=recovered MYSQL_DATABASE=recovered
docker() {
  [[ "$1 $2 $3 $4" == 'compose exec -T db' ]] || return 99
  shift 4
  "$@"
}
restore_database /dev/stdin
'''
        return self.docker("exec", "-i", name, "bash", "-c", script, data=dump)

    def test_postgres_dump_restores_data(self):
        name = self.container("postgres:17-alpine", {
            "POSTGRES_USER": "testuser", "POSTGRES_DB": "testsite",
            "POSTGRES_PASSWORD": "Synthetic_Pg_123",
        }, "/var/run/postgresql")
        self.wait(name, 'PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -U testuser -d testsite -c "SELECT 1"')
        self.docker("exec", name, "psql", "-U", "testuser", "-d", "testsite", "-c",
                    "CREATE TABLE probe (id integer, note text); INSERT INTO probe VALUES (1, 'mooship roundtrip');")
        dump = self.docker("exec", name, "pg_dump", "--format=custom", "-U", "testuser", "-d", "testsite").stdout
        self.assertTrue(dump.startswith(b"PGDMP"))
        self.docker("exec", name, "psql", "-U", "testuser", "-d", "testsite", "-c", "CREATE DATABASE recovered")
        self.restore(name, "postgres", dump)
        result = self.docker("exec", name, "psql", "-U", "testuser", "-d", "recovered", "-Atc", "SELECT note FROM probe WHERE id=1")
        self.assertEqual(result.stdout.strip(), b"mooship roundtrip")
        # Native restore runs as the system administrator and must assign tables to the app role.
        self.docker("exec", name, "psql", "-U", "testuser", "-d", "testsite", "-c",
                    "CREATE ROLE nativeuser LOGIN")
        self.docker("exec", name, "psql", "-U", "testuser", "-d", "testsite", "-c",
                    "CREATE DATABASE native_recovered OWNER nativeuser")
        native_script = '''source /mooship/restore.sh
DB_TYPE=postgres; DB_NATIVE=true; PORT_POSTGRES=5432
DB_POSTGRES_NAME=native_recovered; DB_POSTGRES_USER=nativeuser
sudo() { [[ "$1 $2" == '-u postgres' ]] || return 99; shift 2; PGUSER=testuser "$@"; }
restore_database /dev/stdin
'''
        self.docker("exec", "-i", name, "bash", "-c", native_script, data=dump)
        owner = self.docker("exec", name, "psql", "-U", "nativeuser", "-d", "native_recovered", "-Atc",
                            "SELECT tableowner FROM pg_tables WHERE tablename='probe'")
        self.assertEqual(owner.stdout.strip(), b"nativeuser")

    def test_mysql_dump_restores_data(self):
        name = self.container("mysql:8.4", {
            "MYSQL_USER": "testuser", "MYSQL_DATABASE": "testsite",
            "MYSQL_PASSWORD": "Synthetic_Mysql_123", "MYSQL_ROOT_PASSWORD": "Synthetic_Root_123",
        }, "/var/run/mysqld")
        self.wait(name, 'MYSQL_PWD="$MYSQL_PASSWORD" mysql -h 127.0.0.1 -u testuser testsite -e "SELECT 1"')
        self.docker("exec", name, "sh", "-c", '''MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -u root -e "
CREATE TABLE testsite.probe (id integer, note text);
INSERT INTO testsite.probe VALUES (1, 'mooship roundtrip');
CREATE DATABASE recovered;
GRANT ALL ON recovered.* TO 'testuser'@'%';"''')
        dump = self.docker("exec", name, "sh", "-c", 'MYSQL_PWD="$MYSQL_PASSWORD" mysqldump --user="$MYSQL_USER" --single-transaction --no-tablespaces --set-gtid-purged=OFF --routines --events --triggers "$MYSQL_DATABASE"').stdout
        self.assertIn(b"probe", dump)
        self.restore(name, "mysql", dump)
        result = self.docker("exec", name, "sh", "-c", 'MYSQL_PWD="$MYSQL_PASSWORD" mysql -u testuser recovered --batch --skip-column-names -e "SELECT note FROM probe WHERE id=1"')
        self.assertEqual(result.stdout.strip(), b"mooship roundtrip")
        self.docker("exec", name, "sh", "-c", '''MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -u root -e "
CREATE DATABASE native_recovered; GRANT ALL ON native_recovered.* TO 'testuser'@'%';"''')
        native_script = '''source /mooship/restore.sh
DB_TYPE=mysql; DB_NATIVE=true; PORT_MYSQL=3306
DB_MYSQL_NAME=native_recovered; DB_MYSQL_USER=testuser; DB_MYSQL_PASSWORD="$MYSQL_PASSWORD"
restore_database /dev/stdin
'''
        self.docker("exec", "-i", name, "bash", "-c", native_script, data=dump)
        result = self.docker("exec", name, "sh", "-c", 'MYSQL_PWD="$MYSQL_PASSWORD" mysql -h 127.0.0.1 -u testuser native_recovered --batch --skip-column-names -e "SELECT note FROM probe WHERE id=1"')
        self.assertEqual(result.stdout.strip(), b"mooship roundtrip")


if __name__ == "__main__":
    unittest.main()
