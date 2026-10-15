"""Proxy lifecycle regressions against temporary, multi-site Compose files."""

import json
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest
import uuid

from test_scripts import BashTestCase

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("mooship_proxy", ROOT / "lib/proxy.py")
PROXY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROXY)


def proxy_fixture(slugs=("paused", "test", "test2"), disabled=("paused",)):
    lines = ["x-common-networks: &common-networks", "  networks:"]
    for slug in slugs:
        marker = "# " if slug in disabled else ""
        lines.extend(["    " + marker + "- " + slug, "", "    # Network entry above"])
    lines.extend([
        "services:", "  nginxproxy:", "    image: nginx:1.29.1-alpine",
        "    volumes:", "      - ./sites:/etc/nginx/sites:ro",
    ])
    for slug in slugs:
        marker = "# " if slug in disabled else ""
        lines.extend(["      " + marker + "- " + slug + "_ssl_certificates:/etc/letsencrypt/" + slug,
                      "", "      # Certificate entry above"])
    lines.extend([
        "    <<: *common-networks", "  unrelated:", "    image: alpine:3.24",
        "    volumes:", "      - ./test_ssl_certificates:/unrelated:ro", "networks:",
    ])
    for slug in slugs:
        marker = "# " if slug in disabled else ""
        lines.extend(["  " + marker + slug + ":", "    " + marker + "name: " + slug,
                      "    " + marker + "external: true"])
    lines.append("volumes:")
    for slug in slugs:
        marker = "# " if slug in disabled else ""
        lines.extend(["  " + marker + slug + "_ssl_certificates:",
                      "    " + marker + "name: " + slug + "_ssl_certificates",
                      "    " + marker + "external: true"])
    return "\n".join(lines) + "\n"


class ProxyLifecycleTests(BashTestCase):
    def setUp(self):
        super().setUp()
        self.proxy = self.www / "nginxproxy"
        self.proxy.mkdir()
        self.compose = self.proxy / "docker-compose.yml"

    def write_fixture(self, **kwargs):
        self.compose.write_text(proxy_fixture(**kwargs), encoding="utf-8")

    def edit(self, action, slug="test"):
        source, function = {
            "deactivate": ("deactivate.sh", "comment_in_docker_compose"),
            "activate": ("activate.sh", "uncomment_in_docker_compose"),
            "remove": ("remove.sh", "remove_from_docker_compose"),
        }[action]
        result = self.bash("SLUG=" + slug + "; " + function, source=source)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return self.compose.read_text(encoding="utf-8")

    def assert_other_sites_preserved(self, original, updated):
        for line in original.splitlines():
            if "paused" in line or "test2" in line or "/unrelated" in line:
                self.assertIn(line, updated)

    def test_deactivate_after_comments_and_blank_lines(self):
        self.write_fixture()
        original = self.compose.read_text()
        updated = self.edit("deactivate")
        self.assertIn("    # - test\n", updated)
        self.assertIn("      # - test_ssl_certificates:/etc/letsencrypt/test\n", updated)
        self.assertIn("  # test:\n", updated)
        self.assertIn("  # test_ssl_certificates:\n", updated)
        self.assert_other_sites_preserved(original, updated)
        self.assertEqual(self.edit("deactivate"), updated)

    def test_remove_active_site_after_comments_and_blank_lines(self):
        self.write_fixture()
        original = self.compose.read_text()
        updated = self.edit("remove")
        self.assertNotIn("- test\n", updated)
        self.assertNotIn("test_ssl_certificates:/etc/letsencrypt/test", updated)
        self.assertNotIn("  test:\n", updated)
        self.assertNotIn("  test_ssl_certificates:\n", updated)
        self.assert_other_sites_preserved(original, updated)
        self.assertEqual(self.edit("remove"), updated)

    def test_remove_disabled_site_cleans_commented_declarations(self):
        self.write_fixture(disabled=("paused", "test"))
        updated = self.edit("remove")
        self.assertNotIn("- test\n", updated)
        self.assertNotIn("test_ssl_certificates:/etc/letsencrypt/test", updated)
        self.assertNotIn("# test:\n", updated)
        self.assertNotIn("# test_ssl_certificates:\n", updated)

    def test_activate_does_not_enable_adjacent_disabled_site(self):
        self.write_fixture(slugs=("test", "paused", "test2"), disabled=("test", "paused"))
        original = self.compose.read_text()
        updated = self.edit("activate")
        self.assertIn("    - test\n", updated)
        self.assertIn("      - test_ssl_certificates:/etc/letsencrypt/test\n", updated)
        self.assertIn("  test:\n", updated)
        self.assert_other_sites_preserved(original, updated)
        self.assertEqual(self.edit("activate"), updated)

    def test_last_site_can_be_deactivated_and_reactivated(self):
        self.write_fixture(slugs=("test",), disabled=())
        original = self.compose.read_text()
        updated = self.edit("deactivate")
        self.assertIn("  networks: []\n", updated)
        self.assertIn("networks: {}\n", updated)
        self.assertIn("volumes: {}\n", updated)
        self.assertEqual(self.edit("activate"), original)

    def test_removing_last_site_leaves_valid_empty_collections(self):
        self.write_fixture(slugs=("test",), disabled=())
        updated = self.edit("remove")
        self.assertIn("  networks: []\n", updated)
        self.assertIn("networks: {}\n", updated)
        self.assertIn("volumes: {}\n", updated)

    def test_deactivation_applies_compose_before_restarting_proxy(self):
        self.write_fixture()
        result = self.bash('''
docker() { printf '%s:%s\\n' "$PWD" "$*" >> "$TEST_DIR/docker.log"; }
restart_nginxproxy
''', source="deactivate.sh")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.directory / "docker.log").read_text().splitlines(), [
            str(self.proxy) + ":compose up -d",
            str(ROOT) + ":restart nginxproxy",
            str(ROOT) + ":exec nginxproxy nginx -t",
        ])

    def test_failed_proxy_apply_does_not_restart(self):
        self.write_fixture()
        result = self.bash('''
docker() { printf '%s\\n' "$*" >> "$TEST_DIR/docker.log"; return 42; }
restart_nginxproxy
''', source="deactivate.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.directory / "docker.log").read_text(), "compose up -d\n")


class ProxyEditorTests(unittest.TestCase):
    def test_unindented_list_comments_do_not_hide_active_neighbors(self):
        original = proxy_fixture().replace("  networks:\n", "  networks:\n# Shared network notes\n", 1)
        updated = PROXY.transform(original, "test", "deactivate")
        self.assertIn("  networks:\n# Shared network notes\n", updated)
        self.assertIn("    - test2\n", updated)

    def test_roundtrip_preserves_comments_inside_owned_block(self):
        original = proxy_fixture(slugs=("test",), disabled=()).replace(
            "    name: test\n", "    # Administrator note\n    name: test\n")
        disabled = PROXY.transform(original, "test", "deactivate")
        self.assertIn("    # # Administrator note\n", disabled)
        self.assertEqual(PROXY.transform(disabled, "test", "activate"), original)

    def test_invalid_arguments_are_rejected(self):
        for slug, action in (("../test", "remove"), ("nginxproxy", "remove"), ("test", "unknown")):
            with self.subTest(slug=slug, action=action), self.assertRaises(ValueError):
                PROXY.transform(proxy_fixture(), slug, action)

    def test_remove_cleans_duplicate_and_legacy_stale_references(self):
        content = proxy_fixture().replace("    - test\n", "    - test\n    - test\n")
        content = content.replace("  networks:\n", "  networks: []\n", 1)
        updated = PROXY.transform(content, "test", "remove")
        self.assertNotIn("- test\n", updated)
        self.assertIn("    - test2\n", updated)
        self.assertIn("  networks:\n", updated)


@unittest.skipUnless(os.environ.get("MOOSHIP_PROXY_COMPOSE_TESTS") == "1" and shutil.which("docker"),
                     "Opt-in Docker Compose lifecycle validation")
class ProxyComposeTests(unittest.TestCase):
    def test_compose_accepts_every_lifecycle_state(self):
        with tempfile.TemporaryDirectory(prefix="mooship-proxy-compose-") as directory:
            compose = Path(directory) / "docker-compose.yml"
            for slugs in (("paused", "test", "test2"), ("test",)):
                for action in ("deactivate", "activate", "remove"):
                    with self.subTest(slugs=slugs, action=action):
                        content = proxy_fixture(slugs=slugs, disabled=("paused",))
                        disabled = PROXY.transform(content, "test", "deactivate")
                        updated = PROXY.transform(disabled, "test", action)
                        compose.write_text(updated, encoding="utf-8")
                        result = subprocess.run(
                            ["docker", "compose", "-f", str(compose), "config", "--format", "json"],
                            text=True, capture_output=True, timeout=30,
                        )
                        self.assertEqual(result.returncode, 0, result.stderr)
                        config = json.loads(result.stdout)
                        service = config["services"]["nginxproxy"]
                        active = set(service.get("networks", {}))
                        self.assertEqual("test" in active, action == "activate")
                        self.assertEqual("test" in config.get("networks", {}), action == "activate")
                        self.assertEqual("test_ssl_certificates" in config.get("volumes", {}), action == "activate")
                        mounted = {mount["source"] for mount in service.get("volumes", [])}
                        self.assertEqual("test_ssl_certificates" in mounted, action == "activate")
                        self.assertNotIn("paused", active)
                        if "test2" in slugs:
                            self.assertIn("test2", active)


@unittest.skipUnless(os.environ.get("MOOSHIP_PROXY_INTEGRATION") == "1" and shutil.which("docker"),
                     "Opt-in Docker proxy lifecycle integration")
class ProxyDockerTests(unittest.TestCase):
    def docker(self, *arguments):
        return subprocess.run(["docker", *arguments], check=True, capture_output=True,
                              text=True, timeout=60).stdout.strip()

    def test_proxy_detaches_target_and_keeps_other_site_available(self):
        slug = "mooship_proxy_" + uuid.uuid4().hex[:12]
        peer, paused = slug + "2", slug + "_paused"
        networks = (slug, peer, paused)
        volumes = (slug + "_ssl_certificates", peer + "_ssl_certificates")
        container = slug + "_proxy"

        def cleanup():
            subprocess.run(["docker", "rm", "--force", container], capture_output=True, timeout=30)
            for kind, resources in (("volume", volumes), ("network", networks)):
                for name in resources:
                    subprocess.run(["docker", kind, "rm", name], capture_output=True, timeout=30)

        temporary = tempfile.TemporaryDirectory(prefix=".mooship-proxy-test-", dir=str(ROOT))
        directory = Path(temporary.name).resolve()
        self.assertEqual(directory.parent, ROOT.resolve())
        self.assertTrue(directory.name.startswith(".mooship-proxy-test-"))
        self.addCleanup(temporary.cleanup)
        self.addCleanup(cleanup)
        sites = directory / "sites"
        sites.mkdir()
        for name in networks:
            self.docker("network", "create", "--internal", "--label", "org.mooship.test=proxy", name)
        for name in volumes:
            self.docker("volume", "create", "--label", "org.mooship.test=proxy", name)
        (directory / "nginx.conf").write_text(
            "pid /tmp/nginx.pid;\nevents {}\nhttp { include /etc/nginx/sites/*.conf; }\n",
            encoding="utf-8")
        compose = directory / "docker-compose.yml"
        content = proxy_fixture(slugs=(paused, slug, peer), disabled=(paused,))
        content = content[:content.index("  unrelated:\n")] + content[content.index("networks:\n", content.index("services:\n")):]
        content = content.replace("    image: nginx:1.29.1-alpine\n", "\n".join([
            "    image: nginx:1.29.1-alpine", "    container_name: " + container,
            "    user: '1000:1000'", "    read_only: true", "    cap_drop: [ALL]",
            "    security_opt: [no-new-privileges:true]",
            "    tmpfs: ['/tmp:rw,uid=1000,gid=1000', '/var/cache/nginx:rw,uid=1000,gid=1000']",
            "",
        ]))
        content = content.replace("    volumes:\n", "    volumes:\n      - ./nginx.conf:/etc/nginx/nginx.conf:ro\n", 1)
        compose.write_text(content, encoding="utf-8")
        for name in (slug, peer):
            (sites / (name + ".conf")).write_text(
                "server { listen 8080; server_name " + name + ".example; location / { return 200 '" + name + "'; } }\n",
                encoding="utf-8")

        def verify(active):
            self.docker("compose", "-p", slug, "-f", str(compose), "up", "-d", "--no-build", "--pull", "never")
            self.docker("restart", container)
            self.docker("exec", container, "nginx", "-t")
            state = json.loads(self.docker("inspect", container))[0]
            self.assertEqual(set(state["NetworkSettings"]["Networks"]), {peer, slug} if active else {peer})
            mounted = {mount.get("Name") for mount in state["Mounts"]}
            self.assertEqual(volumes[0] in mounted, active)
            self.assertIn(volumes[1], mounted)
            for attempt in range(10):
                try:
                    body = self.docker("exec", container, "wget", "-qO-", "--header=Host: " + peer + ".example",
                                       "http://127.0.0.1:8080/")
                    break
                except subprocess.CalledProcessError:
                    if attempt == 9:
                        raise
                    time.sleep(0.2)
            self.assertEqual(body, peer)

        verify(True)
        # Remove an active site, then remove a previously deactivated site.
        for actions in (("deactivate", "activate", "remove"), ("deactivate", "remove")):
            compose.write_text(content, encoding="utf-8")
            (sites / (slug + ".conf")).write_text(
                "server { listen 8080; server_name " + slug + ".example; location / { return 200 'target'; } }\n",
                encoding="utf-8")
            for action in actions:
                with self.subTest(action=action, actions=actions):
                    compose.write_text(PROXY.transform(compose.read_text(encoding="utf-8"), slug, action), encoding="utf-8")
                    enabled = sites / (slug + ".conf")
                    disabled = sites / (slug + ".conf.disabled")
                    if action == "deactivate":
                        enabled.rename(disabled)
                    elif action == "activate":
                        disabled.rename(enabled)
                    else:
                        for path in (enabled, disabled):
                            if path.exists():
                                path.unlink()
                    verify(action == "activate")


if __name__ == "__main__":
    unittest.main()
