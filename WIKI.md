# WIKI

Project knowledge map. Keep current facts in [PROJECT_CONTEXT.md](PROJECT_CONTEXT.md); use this file for links and brief explanations.

## Getting started

- [Agent instructions](AGENTS.md)
- [Project context](PROJECT_CONTEXT.md)
- [Context maintenance workflow](.agents/skills/project-continuity/SKILL.md)
- [Model routing](ai-kit/MODELS.md)
- [Engineering rules](ai-kit/ENGINEERING.md)
- [Intent and reconstructed context](ai-kit/INTENT.md)
- [Agent adapters](ai-kit/ADAPTERS.md)
- [Skill registry](ai-kit/SKILLS.md)
- [Git exclusions](.gitignore)

## Verified stack guides

- [Laravel](ai-kit/stacks/LARAVEL.md)
- [Go](ai-kit/stacks/GO.md)
- [Python](ai-kit/stacks/PYTHON.md)
- [Moodle](ai-kit/stacks/MOODLE.md)

## Decisions and history

- [Decision log](docs/DECISIONS.md)
- [ADR template](docs/adr/0000-template.md)
- [Changelog](CHANGELOG.md)

## Mooship

- [README, live workflow/release badges, and operations guide](README.md)
- [Public Mooship AI skill](SKILL.md) and [local Claude Code adapter](.claude/skills/deploy-moodle/SKILL.md)
- [Installation](deploy-moodle.sh)
- [Backup](backup.sh), [backup schedule](schedule-backup.sh), and [restore](restore.sh)
- [Health check (doctor)](doctor.sh) and its [tests with profiles, mail, and retention](tests/test_operations.py)
- [Full backup procedure](docs/BACKUP.md) and [data preservation decision](docs/adr/0001-safe-deploy-and-full-backups.md)
- [Archives and manifests](lib/state.py)
- [HTTP configuration](lib/web.py) and [protocol checks](tests/test_web.py)
- [Real HTTP/HTTPS routing checks](tests/test_http_roundtrip.py)
- [Shared proxy lifecycle editor](lib/proxy.py) and [regression, Compose, and Docker lifecycle checks](tests/test_proxy_lifecycle.py)
- [Site protocol decision](docs/adr/0002-http-site-protocol.md)
- [Proxy upstream resolution and client address decision](docs/adr/0003-proxy-resolution-and-client-addresses.md)
- [Proxy site template](nginxproxy/site-template.conf) and [project nginx template](moodle/.config/nginx/_site.conf)
- [CI workflow](.github/workflows/ci.yml) and [end-to-end deployment workflow](.github/workflows/e2e.yml)
- [CI, security, and database branch policy](docs/CI.md), [component integration](.github/workflows/integration.yml), and [configuration checks](.github/workflows/configuration.yml)
- [Security scans](.github/workflows/security.yml), [CodeQL](.github/workflows/codeql.yml), [dependency review](.github/workflows/dependency-review.yml), and [Dependabot](.github/dependabot.yml)
- [Documentation workflow](.github/workflows/docs.yml) and [its behavioral tests](tests/test_ci_checks.py)
- [License (MIT)](LICENSE)
- [Script checks](tests/test_scripts.py) and [archive checks](tests/test_state.py)
- [Real database round-trip checks](tests/test_database_roundtrip.py)
- [Compose template](moodle/docker-compose.yml)
- [PHP configuration example](moodle/.config/php/php83.ini); matching templates exist for each supported PHP version.
- [Moodle PHP overrides](moodle/.config/php/mooship.ini) and [PHP-FPM pool](moodle/.config/php/fpm-pool.conf), mounted after `phpXX.ini` for every PHP version.
