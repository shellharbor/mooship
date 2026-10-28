# WIKI

Project knowledge map. Public links target files included in the repository. Optional local AI-KIT paths are listed as code because they may be absent from a clone. Keep current facts in [PROJECT_CONTEXT.md](PROJECT_CONTEXT.md).

## Getting started

- [README and operations guide](README.md)
- [Standalone Moodle images, Compose, Kubernetes, and Docker Hub](docs/DOCKER.md)
- [Image impact assessment, synchronization, rebuilds, and checks](docs/DOCKER.md#keeping-images-in-sync)
- [Python CLI, pip/pipx installation, and PyPI](docs/PYTHON.md)
- [Release publication and account setup](docs/RELEASING.md)
- [Public Mooship AI skill](SKILL.md)
- [Project context](PROJECT_CONTEXT.md)
- [Git exclusions](.gitignore)

## Local AI-KIT (optional)

These local resources are not distributed with the repository. Use them when provided in the working checkout:

- Agent instructions: `AGENTS.md`.
- Context maintenance: `.agents/skills/project-continuity/SKILL.md`.
- Model routing and engineering: `ai-kit/MODELS.md`, `ai-kit/ENGINEERING.md`.
- Intent, adapters, and skill registry: `ai-kit/INTENT.md`, `ai-kit/ADAPTERS.md`, `ai-kit/SKILLS.md`.
- Stack guides: `ai-kit/stacks/LARAVEL.md`, `ai-kit/stacks/GO.md`, `ai-kit/stacks/PYTHON.md`, `ai-kit/stacks/MOODLE.md`.
- Container standard: `ai-kit/CONTAINERS.md`.
- Local decision log and ADR template: `docs/DECISIONS.md`, `docs/adr/0000-template.md`.

## Decisions and history

- [Published architecture decisions](docs/adr/)
- [Standalone Moodle runtime decision](docs/adr/0004-standalone-moodle-images.md)
- [Python CLI and release distribution decision](docs/adr/0006-python-cli-and-release-distribution.md)

- [Deployment preflight and readiness decision](docs/adr/0005-deployment-preflight.md)
- [Changelog](CHANGELOG.md)

## Mooship

- [README, live workflow/release badges, and operations guide](README.md)
- [Public Mooship AI skill](SKILL.md); optional local Claude Code adapter: `.claude/skills/deploy-moodle/SKILL.md`.
- [Installation](deploy-moodle.sh)
- [Host deployment preflight implementation (draft PR #6)](https://github.com/shellharbor/mooship/pull/6)

- [Port preflight, native DB access, and readiness](docs/PREFLIGHT.md)
- [Locked production dependency gate](lib/install-dependencies.sh) and [failure-path tests](tests/test_dependencies.py)
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
