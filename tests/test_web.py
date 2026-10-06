import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("mooship_web", ROOT / "lib/web.py")
WEB = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(WEB)


class WebConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.template = (ROOT / "moodle/.config/nginx/_site.conf").read_text(encoding="utf-8")

    def test_http_serves_all_application_routes_without_tls_or_hsts(self):
        result = WEB.http_configuration(self.template)
        blocks = WEB.server_blocks(result.splitlines())
        active = [body for _, _, body, commented in blocks if not commented]
        self.assertEqual(len(active), 1)
        content = "\n".join(active[0])
        self.assertIn("listen 80;", content)
        self.assertIn("root /var/www/html;", content)
        self.assertIn("fastcgi_pass             {SLUG}_php:9000;", content)
        self.assertIn("location /dataroot/", content)
        self.assertIn("client_max_body_size 2048M;", content)
        self.assertIn("location ~ /\\.", content)
        self.assertNotIn("ssl_certificate", content)
        self.assertNotIn("Strict-Transport-Security", content)
        self.assertTrue(blocks[1][3])
        self.assertIn("ssl_certificate", "\n".join(blocks[1][2]))

    def test_basic_auth_and_public_acme_routes_are_preserved(self):
        template = self.template.replace('#        auth_basic ', '        auth_basic ')
        template = template.replace('#        auth_basic_user_file ', '        auth_basic_user_file ')
        active = WEB.server_blocks(WEB.http_configuration(template).splitlines())[0][2]
        content = "\n".join(active)
        self.assertIn('auth_basic "Restricted Access";', content)
        self.assertIn("auth_basic_user_file /etc/nginx/.htpasswd;", content)
        self.assertIn("location ^~ /.well-known/acme-challenge/", content)
        self.assertIn("auth_basic off;", content)

    def test_moodle_51_document_root_and_repeated_configuration_are_preserved(self):
        template = self.template.replace("root /var/www/html;", "root /var/www/html/public;")
        result = WEB.http_configuration(template)
        self.assertIn("root /var/www/html/public;", result)
        self.assertEqual(WEB.http_configuration(result), result)

    def test_commented_tls_template_can_be_restored_as_http(self):
        lines = self.template.splitlines()
        tls = WEB.server_blocks(lines)[1]
        lines[tls[0]:tls[1]] = ["#" + line for line in tls[2]]
        result = WEB.http_configuration("\n".join(lines))
        self.assertEqual(result, WEB.http_configuration(self.template))

    def test_unsupported_or_unterminated_configuration_is_rejected(self):
        for template in ("server {\n listen 80;\n}\n", self.template[:-2]):
            with self.subTest(template=template):
                with self.assertRaises(ValueError):
                    WEB.http_configuration(template)


if __name__ == "__main__":
    unittest.main()
