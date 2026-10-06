"""Opt-in nginx → nginx → PHP checks with local Docker images and synthetic fixtures."""

import base64
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("mooship_web", ROOT / "lib/web.py")
WEB = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(WEB)


@unittest.skipUnless(os.environ.get("MOOSHIP_HTTP_INTEGRATION") == "1",
                     "Opt-in Docker HTTP integration tests")
class HttpRoundtripTests(unittest.TestCase):
    def docker(self, *arguments):
        return subprocess.run(["docker", *arguments], check=True, capture_output=True,
                              text=True, timeout=60).stdout.strip()

    def write(self, path, content):
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("w", encoding="utf-8", newline="\n") as stream:
            stream.write(content)

    def setUp(self):
        self.docker("info", "--format", "{{.OSType}}")
        temporary = tempfile.TemporaryDirectory(prefix=".mooship-http-test-", dir=str(ROOT))
        self.directory = Path(temporary.name).resolve()
        # Recursive cleanup is limited to the fixture directory created in this workspace.
        self.assertEqual(self.directory.parent, ROOT.resolve())
        self.assertTrue(self.directory.name.startswith(".mooship-http-test-"))
        self.addCleanup(temporary.cleanup)
        self.slug = "mooship_http_" + uuid.uuid4().hex[:12]
        self.network = self.slug
        self.containers = []
        self.docker("network", "create", "--internal", "--label", "org.mooship.test=http", self.network)
        self.addCleanup(self.cleanup_docker)

    def cleanup_docker(self):
        for name in reversed(self.containers):
            subprocess.run(["docker", "rm", "--force", name], capture_output=True, timeout=30)
        subprocess.run(["docker", "network", "rm", self.network], capture_output=True, timeout=30)

    def mount(self, source, target):
        return ["--mount", "type=bind,source=" + str(source) + ",target=" + target + ",readonly"]

    def start(self, name, image, command, mounts):
        self.containers.append(name)
        arguments = ["run", "--detach", "--pull", "never", "--name", name,
                     "--network", self.network, "--network-alias", name,
                     "--read-only", "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
                     "--user", "1000:1000", "--tmpfs", "/tmp:rw,uid=1000,gid=1000,mode=1777",
                     "--tmpfs", "/var/cache/nginx:rw,uid=1000,gid=1000",
                     "--tmpfs", "/var/log/nginx:rw,uid=1000,gid=1000"]
        for source, target in mounts:
            arguments += self.mount(source, target)
        self.docker(*arguments, "--entrypoint", command[0], image, *command[1:])

    def certificates(self):
        keys = self.directory / "keys"
        keys.mkdir()
        self.docker("run", "--rm", "--pull", "never", "--network", "none", "--read-only",
                    "--cap-drop", "ALL", "--security-opt", "no-new-privileges", "--user", "1000:1000",
                    "--mount", "type=bind,source=" + str(keys) + ",target=/keys",
                    "alpine/openssl:latest", "req", "-x509", "-nodes", "-newkey", "rsa:2048",
                    "-days", "1", "-subj", "/CN=test.example",
                    "-keyout", "/keys/privkey.pem", "-out", "/keys/fullchain.pem")
        certificates = self.directory / "certificates"
        for folder in (certificates / "live/test.example",
                       certificates / self.slug / "live/test.example"):
            folder.mkdir(parents=True)
            shutil.copyfile(keys / "fullchain.pem", folder / "fullchain.pem")
            shutil.copyfile(keys / "fullchain.pem", folder / "chain.pem")
            shutil.copyfile(keys / "privkey.pem", folder / "privkey.pem")
        return certificates

    def prepare(self, https=False, basic_auth=False, public=False):
        project = (ROOT / "moodle/.config/nginx/_site.conf").read_text(encoding="utf-8")
        project = project.replace("MYSITE.COM", "test.example").replace("{SLUG}", self.slug)
        if public:
            project = project.replace("root /var/www/html;", "root /var/www/html/public;")
        if basic_auth:
            project = project.replace('#        auth_basic ', '        auth_basic ')
            project = project.replace('#        auth_basic_user_file ', '        auth_basic_user_file ')
        if not https:
            project = WEB.http_configuration(project)
        self.write(self.directory / "project.conf", project)
        proxy = (ROOT / "nginxproxy/site-template.conf").read_text(encoding="utf-8")
        proxy = proxy.replace("SLUG", self.slug).replace("DOMAIN", "test.example")
        if not https:
            lines = proxy.splitlines()
            tls = WEB.server_blocks(lines)[1]
            lines[tls[0]:tls[1]] = ["#" + line for line in tls[2]]
            proxy = "\n".join(lines) + "\n"
        self.write(self.directory / "proxy.conf", proxy)
        for name in ("project", "proxy"):
            self.write(self.directory / (name + "-main.conf"),
                       "pid /tmp/nginx.pid;\nerror_log /dev/stderr;\nevents {}\nhttp {\n"
                       "include /etc/nginx/mime.types;\ninclude /fixtures/" + name + ".conf;\n}\n")
        self.write(self.directory / "php-fpm.conf",
                   "[global]\nerror_log=/proc/self/fd/2\ndaemonize=no\n"
                   "[www]\nlisten=0.0.0.0:9000\npm=static\npm.max_children=2\ncatch_workers_output=yes\n")
        html = self.directory / "html"
        webroot = html / "public" if public else html
        self.write(webroot / "index.php", "<?php echo 'MOOSHIP:' . (empty($_SERVER['HTTPS']) ? 'http' : 'https');")
        self.write(webroot / "pluginfile.php", "<?php echo $_SERVER['PATH_INFO'];")
        self.write(webroot / "asset.css", "synthetic asset")
        self.write(webroot / ".env", "must not be served")
        self.write(self.directory / "acme/.well-known/acme-challenge/token", "synthetic challenge")
        password = self.docker("run", "--rm", "--pull", "never", "--network", "none", "--read-only",
                               "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
                               "--entrypoint", "htpasswd", "httpd:alpine", "-nb", "reviewer", "Synthetic_Basic")
        self.write(self.directory / ".htpasswd", password + "\n")
        certificates = self.certificates() if https else self.directory / "certificates"
        certificates.mkdir(exist_ok=True)
        common = [(self.directory, "/fixtures"), (html, "/var/www/html"),
                  (self.directory / "acme", "/var/www/certbot"),
                  (self.directory / ".htpasswd", "/etc/nginx/.htpasswd"),
                  (certificates, "/etc/letsencrypt")]
        self.start(self.slug + "_php", os.environ.get("MOOSHIP_TEST_PHP_IMAGE", "php:8.4-fpm"),
                   ["php-fpm", "--fpm-config", "/fixtures/php-fpm.conf", "--nodaemonize"], common)
        self.start(self.slug + "_nginx", "nginx:1.29.1-alpine",
                   ["nginx", "-g", "daemon off;"],
                   common + [(self.directory / "project-main.conf", "/etc/nginx/nginx.conf")])
        self.proxy = self.slug + "_proxy"
        self.start(self.proxy, "nginx:1.29.1-alpine",
                   ["nginx", "-g", "daemon off;"],
                   common + [(self.directory / "proxy-main.conf", "/etc/nginx/nginx.conf")])
        self.client = self.slug + "_client"
        self.start(self.client, "python:3.12-alpine", ["sleep", "600"], common)
        self.base = ("https://" if https else "http://") + self.proxy
        self.write(self.directory / "client.py", '''import json, ssl, sys
from urllib.error import HTTPError
from urllib.request import Request, urlopen
headers = {"Host": "test.example"}
if sys.argv[2]: headers["Authorization"] = "Basic " + sys.argv[2]
try:
    response = urlopen(Request(sys.argv[1], headers=headers), timeout=2,
                       context=ssl._create_unverified_context())
except HTTPError as error:
    response = error
with response:
    print(json.dumps([response.status, response.read().decode("utf-8"), dict(response.headers)]))
''')
        for _ in range(10):
            try:
                self.request("/.well-known/acme-challenge/token")
                break
            except subprocess.CalledProcessError:
                time.sleep(0.2)
        else:
            logs = []
            for name in self.containers:
                output = subprocess.run(["docker", "logs", name], capture_output=True, text=True, timeout=10)
                logs.append(name + ": " + output.stdout + output.stderr)
            self.fail("HTTP services did not become ready: " + "\n".join(logs))
        for name in (self.slug + "_nginx", self.proxy):
            self.docker("exec", name, "nginx", "-t")

    def request(self, path, authenticated=False):
        authorization = base64.b64encode(b"reviewer:Synthetic_Basic").decode("ascii") if authenticated else ""
        return tuple(json.loads(self.docker("exec", self.client, "python3", "/fixtures/client.py",
                                            self.base + path, authorization)))

    def verify_site(self, https=False, basic_auth=False, public=False):
        self.prepare(https=https, basic_auth=basic_auth, public=public)
        status, body, headers = self.request("/", authenticated=basic_auth)
        self.assertEqual(status, 200)
        self.assertEqual(body, "MOOSHIP:" + ("https" if https else "http"))
        self.assertEqual("Strict-Transport-Security" in headers, https)
        self.assertEqual(self.request("/pluginfile.php/course/file", basic_auth)[:2], (200, "/course/file"))
        self.assertEqual(self.request("/asset.css", basic_auth)[:2], (200, "synthetic asset"))
        self.assertIn(self.request("/.env", basic_auth)[0], (403, 404))
        self.assertEqual(self.request("/dataroot/private.txt", basic_auth)[0], 404)
        self.assertEqual(self.request("/.well-known/acme-challenge/token")[:2], (200, "synthetic challenge"))
        if basic_auth:
            self.assertEqual(self.request("/")[0], 401)
            self.assertEqual(self.request("/pluginfile.php/course/file")[0], 401)
            self.assertEqual(self.request("/asset.css")[0], 401)

    def test_http_legacy_document_root(self):
        self.verify_site()

    def test_http_public_document_root_with_basic_auth(self):
        self.verify_site(basic_auth=True, public=True)

    def test_https_remains_functional_with_basic_auth(self):
        self.verify_site(https=True, basic_auth=True)


if __name__ == "__main__":
    unittest.main()
