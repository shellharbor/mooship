---
name: mooship
description: Develop, review, test, and operate Mooship's Moodle deployment toolkit and standalone runtime images. Use for its scripts, templates, container builds, site lifecycle, backup and restore, diagnostics, and CI; not for general Moodle plugin development.
---

# Mooship

Work on `shellharbor/mooship`. The host installer downloads Moodle during deployment; the separate root Dockerfile downloads pinned Moodle during build and bakes it into portable PHP/nginx images. There is no vendored Moodle core checkout. Runtime Python helpers use Python 3.8+ and the standard library. Host installer operations target Ubuntu 20.04+ with root privileges, Docker Engine, and the Compose plugin.

Resolve paths below against the Mooship repository root, even if this skill is loaded from another location. Keep the checkout available; this file is a guide to the project, not a replacement for its scripts and templates. A root `SKILL.md` can be supplied directly to another AI; automatic discovery depends on that AI's integration.

## Start with the task

- Distinguish source changes, read-only review, and operations on a specific server. A review request does not authorize running a deployment or deleting resources.
- Follow `AGENTS.md` when present. Consult `PROJECT_CONTEXT.md` and `WIKI.md` when available, but verify important claims against current files and checks. These local AI-KIT files may be absent from a Git clone; the public documentation below remains usable without them.
- Read the relevant parts of [README.md](README.md), [backup and restore](docs/BACKUP.md), and [CI](docs/CI.md). Check each script's parser or supported `--help` before proposing flags; do not assume every lifecycle script implements help or dry-run mode.
- Author project files, comments, tests, logs, release notes, and Git text in English. Communicate with the user in Russian unless they request another chat language.
- Keep existing user edits and secrets intact. Local changes should remain within the requested scope; a code change does not imply permission to deploy, publish, or push it.

## Find the right implementation

| Area | Files and responsibilities |
| --- | --- |
| Deployment | `deploy-moodle.sh`: arguments, preflight, version/PHP selection, project generation, database creation, Moodle CLI installation, mail, profiles, SSL, proxy registration |
| Site lifecycle | `activate.sh`, `deactivate.sh`, `remove.sh`, `list-projects.sh` |
| Backup operations | `backup.sh`, `restore.sh`, `schedule-backup.sh`; archive contract in `docs/BACKUP.md` |
| Diagnostics | `doctor.sh`: read-only health checks; exit codes 0 OK, 1 WARNING, 2 CRITICAL |
| Shared shell contracts | `lib/common.sh`: paths, identifiers, database ownership/readiness, schedules |
| Deployment preflight | `lib/preflight.sh`, `lib/check-database.php`, `lib/install-dependencies.sh`, `docs/PREFLIGHT.md`: ports, native routing, PHP DB/dependency probes, bounded readiness |
| State and archives | `lib/state.py`: environment parsing, manifests, checksums, safe extraction |
| HTTP configuration | `lib/web.py`, `moodle/.config/nginx/_site.conf`, `nginxproxy/site-template.conf` |
| Proxy lifecycle edits | `lib/proxy.py`, exercised by `tests/test_proxy_lifecycle.py` |
| Project templates | `moodle/docker-compose.yml`, `moodle/.docker/`, `moodle/.config/php/` |
| Standalone images | Root `Dockerfile`, `docker/`, `deploy/k8s/`, `docs/DOCKER.md`, `tests/test_runtime_image.py`, `.github/workflows/image.yml` |
| Python CLI and releases | `src/mooship/`, `pyproject.toml`, `VERSION`, `docs/PYTHON.md`, `docs/RELEASING.md`, `.github/workflows/python-package.yml`, `.github/workflows/release.yml` |
| Shared proxy template | `nginxproxy/`; deployed separately under `/var/www/nginxproxy` |
| Validation | `tests/`, `.github/scripts/`, `.github/workflows/`, `.github/requirements.txt`, `.coveragerc` |

Prefer existing shared helpers over new inline parsers. When editing generated configuration, check both the template and every script that transforms it. A template change does not automatically update an already deployed site or an existing proxy's copied template.

## Assess image impact

- Before changing behavior, dependencies, or configuration, follow [the image update procedure](docs/DOCKER.md#keeping-images-in-sync). Trace the actual build inputs and assess both host installation and standalone runtime behavior; their source layouts and supported versions differ.
- If affected, synchronize image sources/build definitions, runtime configuration, manifests, tests and documentation in the same task. Rebuild affected `app`/`web` targets and run relevant runtime tests; shared Moodle source or plugins require matching changes in both images. An already copied source needs no cosmetic Dockerfile edit. Host-only or documentation changes need no rebuild when verified to have no image impact.
- Report the impact, affected targets, builds and tests actually run, and any unavailable checks. Source changes, local image builds, registry publication and deployment are separate outcomes; publication/deployment stay within the user's authorized scope.

## Preserve operational contracts

- **Python distribution:** follow [the CLI guide](docs/PYTHON.md). Package installation does not deploy or install Docker. Native toolkit installation requires an exact official release, checksum and safe archive validation, a new destination and matching VERSION. Existing scripts retain their permissions, prompts, signals and exit codes. Application images are not a Docker-controller backend. Release publication requires matching VERSION/tag and successful exact-commit checks; report actual registry evidence separately.

- **Standalone images:** consult [the runtime guide](docs/DOCKER.md). Preserve the matching pinned source in PHP/nginx targets, non-root UID/GID 1000, immutable code and external data/config/secrets. Installation and upgrades stay explicit; process liveness is independent of DB readiness. Host installer lifecycle/backup utilities do not manage this stack. Image tests opt in with `MOOSHIP_IMAGE_TESTS=1`; build both tags and pull the documented DB images first. A local build is not Docker Hub publication or a verified Kubernetes deployment.

- **New installations:** reject occupied project directories and leftover resources. `nginxproxy` is a reserved slug. Keep resolved paths under `/var/www`, reject project-directory symlinks, and match slugs exactly: an operation on `lms` must not affect `lms2`.
- **Native databases:** do not reuse existing databases/users or drop them based only on a name. Removal requires a matching `.mooship-native-database` ownership marker. Failed creation or an older project without that marker does not establish ownership.
- **Deployment gates:** validate ports before creating resources; exempt the selected native DB listener from free-port checks. Native `--db-host` controls the application's route to the locally managed DB. Preserve PHP-side TCP/authentication probes, bounded service waits, refusal to initialize unknown/partial DB states, nginx reload after document-root changes, and cron startup after installation/restore. See `docs/PREFLIGHT.md`.
- **Database branches:** keep templates and integration checks on the tested branches documented in `docs/CI.md`. A branch change requires coordinated data-volume, migration, and backup/restore validation. Updating a template never authorizes downgrading an existing project's database files.
- **Host installer secrets:** preserve `umask 077`, mode `600` for `.env`, `config.php`, and archives, and localhost-only database, Redis, and PHP-FPM publications. Use the existing environment parser rather than executing `.env` as shell code. The standalone image's baked `config.php` contains no secrets; mounted secret files must be readable by UID 1000. Never print credentials or private certificate material in reports; endpoints receiving secrets require HTTPS.

- **Locked PHP dependencies:** preserve the conditional Composer gate for Moodle's declared OAuth2 dependency. Verify the pinned tool's checksum before execution, install from the lockfile without dev packages/scripts/plugins, preserve platform checks and verify autoloading. Do not replace install with update or hide dependency failures.
- **Shared proxy:** other sites depend on `/var/www/nginxproxy`. Use `lib/proxy.py` for lifecycle edits; it targets Mooship's generated configuration format, not arbitrary YAML. Preserve neighboring entries, comments, disabled declarations, and valid empty collections. Deactivation must apply Compose changes so the site's network and certificate volume detach.
- **Routing:** preserve per-request Docker DNS resolution of project upstreams so a stopped site cannot prevent proxy startup. Trust the client-address entry appended by the shared proxy. Keep ACME reachable when Basic Auth is enabled, and retain Moodle routing/X-Sendfile behavior, including the `public/` layout for Moodle 5.1+.
- **Protocol:** HTTPS is the default. `--no-ssl` must configure HTTP consistently through both nginx layers and Moodle's `wwwroot`. Persist `SITE_SCHEME`; restore older archives without it as HTTPS. Redeploying an occupied slug is not an HTTP-to-HTTPS migration or a Moodle upgrade.
- **Backups:** preserve the full v1 archive contract, validation before extraction, refusal to overwrite archives, and publication only after writing completes. Resume only services that were running before the snapshot, including on error. Keep archives when removing a site. Backup hooks run as root and must satisfy the existing ownership/permission checks.
- **Restore:** accept a trusted Mooship v1 archive into an unused matching slug. Keep manifest, path, symlink, checksum, and native database checks. Archive validation does not make arbitrary source or Compose definitions safe to execute. Preserve the script's interactive confirmation; never pipe an answer into it without user authorization.

Redis is configured for Moodle sessions in new projects; automatic MUC application-cache configuration is separate. Resource profiles tune workers and database settings without enforcing container CPU/memory limits. Native database access currently depends on host bridge configuration. Verify these details before promising caching, resource isolation, or portability.

## Operate a server within the requested scope

Use the identified Ubuntu server, not the local Windows workstation, for live operations. Confirm the checkout location, explicit slug, domain, database mode, and requested action from available context; ask only for missing information that changes the operation. Reuse authorization already supplied by the user.

For a new installation, check the documented OS/runtime requirements, DNS and ports 80/443 for HTTPS, outbound connectivity, and absence of conflicting project resources. Check the host database configuration separately for `--db-native`. Use `--moodle-version X.Y` for the latest stable release in that branch or `X.Y.Z` for an exact release; use the implementation's PHP compatibility selection.

Prepare commands from the repository root, substituting the actual target values. For example, a new site uses:

```bash
sudo bash deploy-moodle.sh \
  --slug lms \
  --domain lms.example.com \
  --db-type postgres \
  --ssl-email admin@example.com
```

For an existing site, choose the appropriate lifecycle script rather than rerunning installation. Use `backup.sh` for a complete snapshot, `schedule-backup.sh` for its systemd timer, and `doctor.sh --slug lms` for diagnostics. See the README and backup guide for exact commands and options. Do not invent an upgrade script or bypass deletion/restore confirmations.

After a failed operation, inspect the project's state and relevant logs before retrying. Deployment and restore can retain partially created resources; do not erase them automatically or treat a retry as safe reuse. Report the retained state and the recovery action needed within the user's scope.

## Validate the change

Documentation and skill edits need content, frontmatter, and link checks; they do not require Docker. For container-dependent work, first check `docker info` on the machine that will execute the checks. If the daemon is stopped, ask the user to start it and continue independent work while waiting.

The following commands run from the repository root in a Linux shell. Windows development needs an appropriate Linux environment for Bash-based tests. Containerized tests that execute temporary hook scripts need an executable temporary filesystem.

For shell changes, check tracked scripts:

```bash
mapfile -d '' shell_files < <(git ls-files -z '*.sh')
for shell_file in "${shell_files[@]}"; do bash -n "$shell_file"; done
shellcheck -S warning "${shell_files[@]}"
```

For Python/helpers or script behavior, run the relevant regressions, then the full set when justified:

```bash
python3 -B -m unittest discover -s tests -v
```

For documentation, run:

```bash
python3 -B .github/scripts/check_docs.py
```

The documentation checker uses Git's inventory: tracked Markdown remains checked even when ignored, and pending non-ignored documents are included. Public links must target repository files or directories containing them; ignored local files cannot satisfy those links. Describe optional local AI-KIT resources as code paths. Check ignored local skills separately when editing them.

For Compose or proxy edits, validate generated variants rather than running the raw placeholder template:

```bash
MOOSHIP_COMPOSE_TESTS=1 MOOSHIP_PROXY_COMPOSE_TESTS=1 PYTHONPATH=tests \
  python3 -B -m unittest \
  test_scripts.ScriptTests.test_generated_compose_variants_have_safe_ports_and_restart_policy \
  test_proxy_lifecycle.ProxyComposeTests -v
```

Also check raw template parsing when changing placeholders or image references. Keep `{SLUG}` placeholders YAML-readable and preserve quoted/unquoted database-key handling.

Use [docs/CI.md](docs/CI.md) and the matching workflow for optional checks:

- Database round trips: `MOOSHIP_DOCKER_TESTS=1`.
- HTTP/HTTPS routing: `MOOSHIP_HTTP_INTEGRATION=1`.
- Real proxy lifecycle: `MOOSHIP_PROXY_INTEGRATION=1`.
- Native DB routing/state probes: `MOOSHIP_NATIVE_PREFLIGHT_TESTS=1`, with `MOOSHIP_PREFLIGHT_PHP_IMAGE` set to an existing PHP image with both PDO drivers and `MOOSHIP_PREFLIGHT_DB=postgres` or `mysql`. This uses disposable databases; see `docs/PREFLIGHT.md` and the E2E workflow.
- Pre-pull the component images listed in `.github/workflows/integration.yml`; the tests themselves do not pull them. Use its exact test selectors and environment settings.
- Install pinned development tools from `.github/requirements.txt` in a separate environment when needed. Keep runtime helpers dependency-free. The combined statement/branch coverage gate is 90% for `lib/`, including subprocesses; it does not measure Bash or Moodle/PHP.

New Dockerfiles or changed container workloads must follow the project's container standard when available, including external configuration, graceful shutdown, and suitable health checks. Do not claim Kubernetes support from Compose validation alone.

## Finish with evidence

Review the diff and report the changed behavior, checks actually run, skipped checks, and any remaining limitation. Distinguish regressions and component tests from a complete Moodle installation. Full E2E, real SMTP delivery, systemd execution, production DNS, and Let's Encrypt issuance need evidence from the corresponding environment; workflow definitions and historical results alone do not prove them.

Update `CHANGELOG.md` under `Unreleased` after file changes. When local context files exist, keep `PROJECT_CONTEXT.md`, `WIKI.md`, and the continuity skill synchronized with lasting facts. Record significant architectural choices through the project's decision-log convention when present.

This root `SKILL.md` is versioned and linked from README, so it is available on GitHub and in a normal clone. Local `ai-kit/`, `.agents/`, and `.claude/` resources remain ignored; do not force-add them, install skills globally, or change their ignore rules unless the user requests that action. Already tracked context and wiki files remain subject to public documentation checks even when they match ignore rules. The local Claude adapter at `.claude/skills/deploy-moodle/SKILL.md`, when present, delegates to this file; keep it as an adapter rather than a second copy of these instructions.
