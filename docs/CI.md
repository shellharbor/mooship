# Continuous integration

Mooship separates fast regression checks, component tests, and full Moodle deployments. Workflow definitions live in [`.github/workflows`](../.github/workflows). They use read-only repository permissions by default, bounded execution times, cancellation of superseded runs, and Actions pinned to verified commit SHAs.

## Workflows

| Workflow | Checks | Trigger |
| --- | --- | --- |
| [CI](../.github/workflows/ci.yml) | Bash syntax and ShellCheck including examples; Ruff; YAML syntax/duplicate keys; actionlint; zizmor; Python regression matrix; branch coverage | Push to `main`, PR, manual |
| [Configuration](../.github/workflows/configuration.yml) | Raw Compose YAML/image references for Dependabot; generated PostgreSQL/MySQL Compose files with native/container databases; proxy lifecycle states; all PHP/nginx Dockerfiles with Hadolint | Push to `main`, PR, manual |
| [Component integration](../.github/workflows/integration.yml) | Separate PostgreSQL 17, MySQL 8.4, HTTP/HTTPS, and proxy lifecycle jobs | Push to `main`, PR, manual |
| [Security](../.github/workflows/security.yml) | Bandit on Python helpers; Gitleaks on repository files and Git history, with redacted output | Push to `main`, PR, Wednesday, manual |
| [CodeQL](../.github/workflows/codeql.yml) | Python and GitHub Actions security analysis | Push to `main`, PR, Wednesday, manual |
| [Dependency review](../.github/workflows/dependency-review.yml) | Reject newly introduced high/critical dependency vulnerabilities reported by GitHub | PR |
| [Documentation](../.github/workflows/docs.yml) | Local inline Markdown links, heading anchors, and endpoint JSON example syntax | Push to `main`, PR, manual |
| [E2E](../.github/workflows/e2e.yml) | Real Moodle 4.5/5.3 deployment with PostgreSQL/MySQL, Redis sessions, SMTP, cron, backups, schedules, and doctor | Monday, manual |

The regression matrix uses Python 3.8, 3.12, and 3.14 on Ubuntu 24.04, plus Python 3.12 on Ubuntu 22.04. Python 3.8 verifies the existing minimum runtime contract; development tools run on Python 3.12. These jobs exercise synthetic data without installing Moodle.

## Coverage

[`.coveragerc`](../.coveragerc) measures statement and branch coverage of `lib/`, including Python child processes launched through Bash. The gate requires at least 90% combined coverage. The locally verified starting level is 92%; coverage does not measure Bash or Moodle/PHP code. The workflow stores `coverage.xml` as an artifact for 14 days.

## Security and dependency updates

[Dependabot](../.github/dependabot.yml) checks GitHub Actions, [Python CI tools](../.github/requirements.txt), Dockerfiles, and the Moodle Compose template weekly. Version updates use a seven-day cooldown; GitHub security updates are not delayed by this cooldown. PHP major/minor image changes require a coordinated update to version selection and matching Dockerfile/ini templates, so Dependabot only proposes PHP patch updates. Pull requests are reviewed and tested; automatic merging is not configured.

Database images stay on the tested MySQL 8.4 LTS and PostgreSQL 17 branches. Dependabot ignores MySQL major/minor updates and PostgreSQL major updates; updates within these branches remain eligible. Changing branches requires coordinated template, data-volume, backup/restore, and integration-test validation. In particular, [PostgreSQL 18 changes its default data directory and volume layout](https://github.com/docker-library/postgres/blob/master/18/trixie/Dockerfile), so changing only the image tag is insufficient. Generated Compose checks verify both database images and PostgreSQL's data mount.

The runtime uses Python's standard library. CI packages are installed separately from `.github/requirements.txt`. Inline image names in Bash scripts, CI scanner image tags, and downloaded Moodle core releases require manual maintenance.

CodeQL analyzes Python and workflow code. Bash is checked by ShellCheck and behavioral tests. Only CodeQL jobs request `security-events: write`; PR dependency review does not post comments. The public repository supports these GitHub features; local validation cannot confirm their server-side configuration or successful runs.

Hadolint errors fail CI. Existing package pinning and `apt` style warnings remain visible until the legacy Dockerfiles are improved. [Bandit configuration](../.github/bandit.yml) suppresses subprocess import/argument-list warnings for the fixed, shell-free repository inspection command; shell execution checks remain active. [Gitleaks configuration](../.gitleaks.toml) excludes local tool/report directories and exactly matches the deterministic database fixture passwords in their test file. Other findings fail CI.

Secret scanning explicitly trusts only the mounted checkout and checks that Git can read a nonempty history before scanning all refs. This prevents a runner/container ownership mismatch from producing a misleading successful scan of zero commits.

## Run checks locally

On Linux, use a separate environment for development tools:

```bash
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -r .github/requirements.txt
python -m ruff check lib tests .github/scripts
python -m yamllint .github
zizmor --offline --strict-collection .github
python -m bandit -r lib .github/scripts -c .github/bandit.yml
python -B .github/scripts/check_docs.py
python -m coverage run -m unittest discover -s tests -v
python -m coverage combine
python -m coverage report
python -m coverage xml
```

Compose validation requires the Docker Compose CLI:

```bash
MOOSHIP_COMPOSE_TESTS=1 MOOSHIP_PROXY_COMPOSE_TESTS=1 PYTHONPATH=tests \
  python -B -m unittest \
  test_scripts.ScriptTests.test_generated_compose_variants_have_safe_ports_and_restart_policy \
  test_proxy_lifecycle.ProxyComposeTests -v
```

Component tests require a running Docker daemon and locally available images. Workflows pull their component's images before enabling the opt-in tests; tests themselves never pull images or publish host ports. See the [development checks](../README.md#development-checks) and the integration workflow for exact image lists and commands.

Full deployments run on disposable GitHub runners and use HTTP and a synthetic domain. DNS and actual Let's Encrypt issuance require separate target-server checks. The workflow definitions and locally executed checks do not establish a production deployment or branch protection policy.
