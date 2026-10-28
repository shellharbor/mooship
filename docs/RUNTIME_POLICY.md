# Moodle and PHP security policy

Mooship permits Moodle **4.3 or newer**, including 4.3, only on explicitly verified branches. PHP 8.1 and older are prohibited. Each permitted PHP branch must meet its own minimum patch version:

| PHP branch | Minimum patch | Current Moodle branches permitted by Mooship |
|---|---|---|
| 8.2 | 8.2.35 | 4.3, 4.4, 4.5, 5.0, 5.1 |
| 8.3 | 8.3.36 | 4.4, 4.5, 5.0, 5.1, 5.2, 5.3 |
| 8.4 | 8.4.27 | 5.0, 5.1, 5.2, 5.3 |
| 8.5 | 8.5.12 | None verified yet; do not deploy this branch |

The patch floors address CVE-2026-109618 and CVE-2026-109619. See the [PHP changelog](https://www.php.net/ChangeLog-8.php) and [AWS security bulletin](https://aws.amazon.com/security/security-bulletins/2026-143-aws/). The compatibility matrix follows the [official Moodle PHP policy](https://moodledev.io/general/development/policies/php) and individual release requirements. A security-patched PHP version still needs Moodle compatibility. Newer unknown branches and prereleases fail closed until reviewed. This compatibility list does not guarantee ongoing upstream support for every Moodle branch; use a maintained Moodle release and current plugins.

## Enforcement

- The canonical machine-readable policy is [runtime-policy.json](../moodle/.docker/php/runtime-policy.json). [runtime_policy.py](../lib/runtime_policy.py) validates installer arguments before creating resources and checks the actual PHP patch version.
- Host templates pin PHP 8.2.35, 8.3.36 and 8.4.27 by tag and digest. PHP 7.4/8.0/8.1 templates and INI files have been removed. `--php-version` selects an allowed branch (`8.2` or `82`), never an arbitrary image or patch override.
- Host PHP/cron images and the standalone image run [check-runtime.php](../moodle/.docker/php/check-runtime.php) during build and startup. It reads the real `PHP_VERSION`; environment variables cannot lower the floor. Standalone builds also validate the pinned Moodle/PHP pair, including when `PHP_IMAGE` is overridden.
- Activation rebuilds PHP/cron with `--pull` and probes actual PHP before starting the site's services. Restoration validates saved Moodle/PHP metadata before confirmation or database creation/import, then builds and probes PHP before import/startup. Both read the actual Moodle release from `public_html/version.php` or `public_html/public/version.php` as data and reject source/metadata disagreement; update `.env` after a reviewed manual upgrade. Missing metadata/source is rejected. Pure HTML sites remain supported.
- The Python adapter refuses deploy/activate/restore with toolkits that lack the policy. Backup, diagnostics, deactivation and removal remain available for migration. No command upgrades Moodle core or an existing database automatically.

## Existing installations and published artifacts

The published Mooship **1.2.0** PHP image and native toolkit predate this policy. Do not use them for a new installation. The 1.2.0 nginx-r1 health-check correction does not update PHP. PyPI 1.2.0 likewise does not enforce this policy; use the updated source until a security release is published. Version **1.2.1 in this checkout is a release candidate**, not evidence of publication.

For a standalone installation, build and test both updated targets using [the Docker guide](DOCKER.md), back up the database and data, then replace the matching PHP/nginx pair. Confirm `php -r 'echo PHP_VERSION;'` and readiness on the replacement. Upgrading PHP alone does not require or authorize a Moodle schema upgrade.

For host-managed sites, make a verified backup first. Update the site's saved `.docker/php/` templates and policy/entrypoint files from the reviewed toolkit, and keep `.env`, the PHP Dockerfile and INI selection consistent with its Moodle branch. Build PHP and cron with `docker compose build --pull php cron`, verify the runtime, then perform a controlled restart and readiness checks. Existing backups retain their saved templates; restore refuses unsafe runtimes. Migrate unsupported Moodle versions using Moodle's supported upgrade path before activating them with this toolkit. Keep backup/diagnostic access available throughout migration.

## Maintaining the rule

Never lower these floors or restore PHP 8.1/older or Moodle below 4.3. For a PHP update, verify official patch releases and Moodle compatibility, update the policy plus all affected Dockerfile tags/digests, test rejection boundaries and lifecycle gates, rebuild affected PHP/cron/app/web targets, and run real runtime/installation checks. Keep documentation, AI instructions and distribution artifacts synchronized; publication is a separate step. See [ADR-0007](adr/0007-runtime-security-baseline.md).
