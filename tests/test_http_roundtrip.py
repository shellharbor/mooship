"""Opt-in nginx → nginx → PHP checks with local Docker images and synthetic fixtures."""

import base64
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
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
        def cleanup_fixture():
            # Docker Desktop may release Windows bind mounts shortly after container removal.
            for attempt in range(11):
                try:
                    temporary.cleanup()
                    return
                except PermissionError:
                    if os.name != 'nt' or attempt == 10:
                        raise
                    time.sleep(1)
        self.addCleanup(cleanup_fixture)
        self.slug = "mooship_http_" + uuid.uuid4().hex[:12]
        self.network = self.slug
        self.containers = []
        self.extra_networks = []
        # Containers run as the invoking user so Linux bind mounts stay readable and writable.
        if hasattr(os, "getuid"):
            self.uid, self.gid = os.getuid(), os.getgid()
        else:
            self.uid, self.gid = 1000, 1000
        self.user = "{}:{}".format(self.uid, self.gid)
        self.docker("network", "create", "--internal", "--label", "org.mooship.test=http", self.network)
        self.addCleanup(self.cleanup_docker)

    def cleanup_docker(self):
        for name in reversed(self.containers):
            subprocess.run(["docker", "rm", "--force", name], capture_output=True, timeout=30)
        subprocess.run(["docker", "network", "rm", self.network], capture_output=True, timeout=30)
        for network in self.extra_networks:
            subprocess.run(["docker", "network", "rm", network], capture_output=True, timeout=30)

    def mount(self, source, target):
        return ["--mount", "type=bind,source=" + str(source) + ",target=" + target + ",readonly"]

    def start(self, name, image, command, mounts):
        self.containers.append(name)
        owner = "uid={},gid={}".format(self.uid, self.gid)
        arguments = ["run", "--detach", "--pull", "never", "--name", name,
                     "--network", self.network, "--network-alias", name,
                     "--read-only", "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
                     "--user", self.user, "--tmpfs", "/tmp:rw," + owner + ",mode=1777",
                     "--tmpfs", "/var/cache/nginx:rw," + owner,
                     "--tmpfs", "/var/log/nginx:rw," + owner]
        for source, target in mounts:
            arguments += self.mount(source, target)
        self.docker(*arguments, "--entrypoint", command[0], image, *command[1:])

    def certificates(self):
        keys = self.directory / "keys"
        keys.mkdir()
        self.docker("run", "--rm", "--pull", "never", "--network", "none", "--read-only",
                    "--cap-drop", "ALL", "--security-opt", "no-new-privileges", "--user", self.user,
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

    def prepare(self, https=False, basic_auth=False, public=False, legacy_root_at_start=False):
        project = (ROOT / "moodle/.config/nginx/_site.conf").read_text(encoding="utf-8")
        project = project.replace("MYSITE.COM", "test.example").replace("{SLUG}", self.slug)
        if public and not legacy_root_at_start:
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
        self.write(webroot / "r.php", "<?php echo 'ROUTER:' . $_SERVER['REQUEST_URI'];")
        self.write(webroot / "course/index.php", "<?php echo 'COURSE';")
        self.write(webroot / "address.php", "<?php echo $_SERVER['REMOTE_ADDR'];")
        self.write(webroot / "sendfile.php",
                   "<?php header('X-Accel-Redirect: /dataroot/localcache/theme/all.css');")
        self.write(webroot / "asset.css", "synthetic asset")
        self.write(webroot / ".env", "must not be served")
        moodledata = self.directory / "moodledata"
        self.write(moodledata / "localcache/theme/all.css", "synthetic moodledata file")
        self.write(self.directory / "acme/.well-known/acme-challenge/token", "synthetic challenge")
        password = self.docker("run", "--rm", "--pull", "never", "--network", "none", "--read-only",
                               "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
                               "--entrypoint", "htpasswd", "httpd:2.4-alpine", "-nb", "reviewer", "Synthetic_Basic")
        self.write(self.directory / ".htpasswd", password + "\n")
        certificates = self.certificates() if https else self.directory / "certificates"
        certificates.mkdir(exist_ok=True)
        common = [(self.directory, "/fixtures"), (html, "/var/www/html"),
                  (moodledata, "/var/www/moodledata"),
                  (self.directory / "acme", "/var/www/certbot"),
                  (self.directory / ".htpasswd", "/etc/nginx/.htpasswd"),
                  (certificates, "/etc/letsencrypt")]
        self.start(self.slug + "_php", os.environ.get("MOOSHIP_TEST_PHP_IMAGE", "php:8.4-fpm"),
                   ["php-fpm", "--fpm-config", "/fixtures/php-fpm.conf", "--nodaemonize"], common)
        self.start(self.slug + "_nginx", "nginx:1.29.1-alpine",
                   ["nginx", "-g", "daemon off;"],
                   common + [(self.directory / "project-main.conf", "/etc/nginx/nginx.conf"),
                             (self.directory / "project.conf", "/fixtures/project.conf")])
        self.proxy = self.slug + "_proxy"
        self.start(self.proxy, "nginx:1.29.1-alpine",
                   ["nginx", "-g", "daemon off;"],
                   common + [(self.directory / "proxy-main.conf", "/etc/nginx/nginx.conf")])
        self.client = self.slug + "_client"
        self.start(self.client, "python:3.12-alpine", ["sleep", "600"], common)
        self.base = ("https://" if https else "http://") + self.proxy
        # Redirects are reported, not followed: test.example is not resolvable in the network.
        self.write(self.directory / "client.py", '''import json, ssl, sys
from urllib.error import HTTPError
from urllib.request import HTTPRedirectHandler, HTTPSHandler, Request, build_opener
class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *arguments, **keywords):
        return None
opener = build_opener(NoRedirect, HTTPSHandler(context=ssl._create_unverified_context()))
headers = {"Host": "test.example"}
if sys.argv[2]: headers["Authorization"] = "Basic " + sys.argv[2]
if sys.argv[3]: headers["X-Forwarded-For"] = sys.argv[3]
try:
    response = opener.open(Request(sys.argv[1], headers=headers), timeout=2)
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

    def request(self, path, authenticated=False, base=None, forwarded_for=""):
        authorization = base64.b64encode(b"reviewer:Synthetic_Basic").decode("ascii") if authenticated else ""
        return tuple(json.loads(self.docker("exec", self.client, "python3", "/fixtures/client.py",
                                            (base or self.base) + path, authorization, forwarded_for)))

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
        # Moodle routing engine: directories keep their index.php, unknown paths reach r.php.
        self.assertEqual(self.request("/course/", basic_auth)[:2], (200, "COURSE"))
        self.assertEqual(self.request("/virtual/route?id=7", basic_auth)[:2],
                         (200, "ROUTER:/virtual/route?id=7"))
        # Retired PHP paths are router shims too, including their original query/path info.
        self.assertEqual(self.request('/retired.php?id=7', basic_auth)[:2],
                         (200, 'ROUTER:/retired.php?id=7'))
        self.assertEqual(self.request('/retired.php/extra?id=7', basic_auth)[:2],
                         (200, 'ROUTER:/retired.php/extra?id=7'))
        # $CFG->xsendfile: PHP hands the file to nginx through the internal /dataroot/ location.
        self.assertEqual(self.request("/sendfile.php", basic_auth)[:2], (200, "synthetic moodledata file"))
        # PHP sees the client address, not nginxproxy's, and clients cannot forge it.
        client = self.docker("inspect", "--format",
                             '{{(index .NetworkSettings.Networks "' + self.network + '").IPAddress}}',
                             self.client)
        self.assertEqual(self.request("/address.php", basic_auth)[:2], (200, client))
        self.assertEqual(self.request("/address.php", basic_auth, forwarded_for="203.0.113.9")[:2],
                         (200, client))
        if https:
            status, _, headers = self.request("/course/view.php?id=7", base="http://" + self.proxy)
            self.assertEqual(status, 301)
            self.assertEqual(headers["Location"], "https://test.example/course/view.php?id=7")
            self.assertEqual(self.request("/.well-known/acme-challenge/token", base="http://" + self.proxy)[:2],
                             (200, "synthetic challenge"))
        if basic_auth:
            self.assertEqual(self.request("/")[0], 401)
            self.assertEqual(self.request("/pluginfile.php/course/file")[0], 401)
            self.assertEqual(self.request("/asset.css")[0], 401)
            self.assertEqual(self.request("/virtual/route")[0], 401)

    def test_stopped_project_does_not_stop_the_proxy(self):
        self.prepare()
        self.docker("rm", "--force", self.slug + "_nginx")
        self.docker("exec", self.proxy, "nginx", "-t")
        self.docker("exec", self.proxy, "nginx", "-s", "reload")
        time.sleep(0.5)
        self.assertEqual(self.request("/")[0], 502)
        self.assertEqual(self.docker("inspect", "--format", "{{.State.Running}}", self.proxy), "true")

    def test_http_legacy_document_root(self):
        self.verify_site()

    def test_php_self_requests_resolve_the_synthetic_site_through_the_proxy(self):
        self.prepare()
        network = self.slug + '_self_checks'
        self.extra_networks.append(network)
        self.docker('network', 'create', '--internal', '--label', 'org.mooship.test=http', network)
        self.docker('network', 'connect', '--alias', 'self.mooship.test', network, self.proxy)
        self.docker('network', 'connect', network, self.slug + '_php')
        result = self.docker('exec', self.slug + '_php', 'php', '-r',
                             'echo file_get_contents("http://self.mooship.test/course/index.php");')
        self.assertEqual(result, 'COURSE')

    def test_public_root_change_is_applied_to_the_running_nginx(self):
        self.prepare(public=True, legacy_root_at_start=True)
        self.assertEqual(self.request('/course/index.php')[0], 404)
        path = self.directory / 'project.conf'
        inode = path.stat().st_ino
        subprocess.run([sys.executable, '-B', str(ROOT / 'lib/web.py'), '--public-root', str(path)],
                       check=True, capture_output=True, timeout=10)
        self.assertEqual(path.stat().st_ino, inode)
        self.assertEqual(self.request('/course/index.php')[0], 404)
        self.docker('exec', self.slug + '_nginx', 'nginx', '-t')
        self.docker('exec', self.slug + '_nginx', 'nginx', '-s', 'reload')
        for _ in range(20):
            result = self.request('/course/index.php')
            if result[:2] == (200, 'COURSE'):
                break
            time.sleep(0.1)
        self.assertEqual(result[:2], (200, 'COURSE'))

    def test_http_public_document_root_with_basic_auth(self):
        self.verify_site(basic_auth=True, public=True)

    def test_https_remains_functional_with_basic_auth(self):
        self.verify_site(https=True, basic_auth=True)


if __name__ == "__main__":
    unittest.main()
