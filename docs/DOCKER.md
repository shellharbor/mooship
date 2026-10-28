# Standalone Moodle images

The root Dockerfile builds a Moodle 4.5.15/PHP 8.3 runtime and a matching nginx companion published as `shellharbor/mooship`. PostgreSQL 17 or MySQL 8.4 runs separately. The existing host installer is an independent deployment option. These application images do not manage Docker or host directories.

The published 1.2.0 pair predates the [mandatory PHP security baseline](RUNTIME_POLICY.md) and must be replaced for new installations. It is `1.2.0-moodle4.5.15-php8.3` and `1.2.0-moodle4.5.15-nginx-r1`. Use the corrected `nginx-r1` companion: the original nginx tag contains a Windows CRLF health response that fails Docker's health check. The `dev-*` tags below identify local source builds. Runtime verification covers Linux amd64; other architectures require their own build and installation checks.

## Build and install with Compose

Run from the repository root on a Linux Docker host with Compose v2+. Docker Desktop can build/test the images; production secret-file ownership examples assume Linux. Select the updated local pair and copy the configuration example:

Build both updated local tags using the source-build commands below before running these examples. They are not published security-release tags.

```bash
export MOOSHIP_APP_IMAGE=shellharbor/mooship:dev-moodle4.5.15-php8.3
export MOOSHIP_WEB_IMAGE=shellharbor/mooship:dev-moodle4.5.15-nginx
cp docker/.env.example docker/.env
```

Alternatively, build the development tags from source without the above image overrides:

```bash
docker build --target app -t shellharbor/mooship:dev-moodle4.5.15-php8.3 .
docker build --target web -t shellharbor/mooship:dev-moodle4.5.15-nginx .
cp docker/.env.example docker/.env
```

Set `MOODLE_ADMIN_EMAIL` and the public `MOODLE_WWWROOT` in `docker/.env`. The URL must be an HTTP(S) origin without a subdirectory. Generate distinct passwords in ignored files, only for an initial deployment:

```bash
install -d -m 0700 .secrets
for name in db_password admin_password mysql_root_password; do
  test ! -e ".secrets/$name" || exit 1
  printf 'Aa9!%s\n' "$(openssl rand -hex 32)" > ".secrets/$name"
  chmod 0600 ".secrets/$name"
done
sudo chown 1000:1000 .secrets/*
```

Compose file secrets are bind mounts: their host permissions must allow the PHP process (UID/GID 1000) to read them. Do not make secrets world-readable as a production workaround. The database password is shared with the database; the admin password is mounted only into the installer. `mysql_root_password` is needed only for MySQL. Store the initial admin password securely before removing its file after installation.

For PostgreSQL, always use the base file and PostgreSQL overlay together:

```bash
docker compose --env-file docker/.env -f docker/compose.yml -f docker/compose.postgres.yml up -d db
docker compose --env-file docker/.env -f docker/compose.yml -f docker/compose.postgres.yml run --rm install
docker compose --env-file docker/.env -f docker/compose.yml -f docker/compose.postgres.yml up -d app cron web
```

For MySQL, set `MOODLE_DB_TYPE=mysqli` in `docker/.env` and replace the PostgreSQL overlay with `docker/compose.mysql.yml` in all three commands. Choose the engine before creating its volume; switching overlays does not migrate data. Installation requires an empty database and explicit license acceptance (`MOODLE_AGREE_LICENSE=true` in the installer service), takes an advisory DB lock, and refuses populated databases. Check installer success before starting services. Normal startup never installs or upgrades the schema.

The example binds `http://localhost:8080` on loopback; DB and FastCGI publish no host ports. On a server, place a trusted TLS reverse proxy before nginx. Set an HTTPS origin and `MOODLE_SSL_PROXY=true` when the proxy terminates TLS, and restrict backend access. Enable `MOODLE_REVERSE_PROXY` only when the topology requires Moodle's reverse-proxy mode. This nginx example does not trust arbitrary incoming `X-Forwarded-For` headers; configure trusted client-address forwarding for your network. Certificate management is external.

## Configuration and commands

| Setting | Default / requirement |
| --- | --- |
| `MOODLE_WWWROOT` | Required HTTP(S) origin |
| `MOODLE_DB_TYPE` | `pgsql` (default) or `mysqli` |
| `MOODLE_DB_HOST`, `MOODLE_DB_PORT` | `db`; engine port 5432/3306 |
| `MOODLE_DB_NAME`, `MOODLE_DB_USER`, `MOODLE_DB_PREFIX` | `moodle`, `moodle`, `mdl_` |
| `MOODLE_DB_PASSWORD` / `MOODLE_DB_PASSWORD_FILE` | Required; choose exactly one |
| `MOODLE_REVERSE_PROXY`, `MOODLE_SSL_PROXY` | `false`; explicit booleans |
| `MOODLE_REDIS_HOST`, `MOODLE_REDIS_PORT` | Optional session store; default port 6379 |
| `MOODLE_REDIS_PASSWORD` / `MOODLE_REDIS_PASSWORD_FILE` | Required if Redis is enabled |
| `PHP_FPM_MAX_CHILDREN` | `4`; at least 2 with the bundled dynamic pool |
| `MOOSHIP_FPM_UPSTREAM` | nginx only; `app:9000`, configurable hostname:port |
| `MOODLE_AGREE_LICENSE` | `true` required for installation |
| `MOODLE_ADMIN_EMAIL`, `MOODLE_ADMIN_PASSWORD[_FILE]` | Required for installation |
| `MOODLE_ADMIN_USER` | `admin` |
| `MOODLE_SITE_FULLNAME`, `MOODLE_SITE_SHORTNAME` | `Mooship Moodle`, `Mooship` |

Secret files must have absolute paths, be readable, and contain at most 64 KiB. Trailing line endings are removed; other characters are preserved. Passwords are not embedded in layers or generated PHP. The admin password is passed to Moodle in PHP memory, without adding it to the process command line. Environment passwords remain visible to container administrators; prefer files.

| Command | Behavior |
| --- | --- |
| `fpm` (default) | Validate settings and installed DB version, serve FastCGI on 9000 |
| `install` | Install into an empty database with an exclusive lock |
| `cron` | Run cron, wait 60 seconds after completion, repeat; exit on error |
| `cron-once` | Run cron once; suitable for a Kubernetes CronJob |
| `check` | Readiness: writable data/tmp, DB connection, matching installed version |
| `php ...` | Explicit CLI operation, including controlled schema upgrades |
| `--help` | Display commands without credentials |

Application code is immutable in `/opt/moodle`; `/var/moodledata` and `/tmp` are writable. Named Docker volumes inherit UID 1000; provision bind mounts/PVCs accordingly. Both images run as 1000:1000 with read-only roots and dropped capabilities, without privileged mode, source mounts, or a Docker socket. Logs go to stdout/stderr. nginx reads Moodle data only for internal X-Accel-Redirect responses; direct `/dataroot/` requests are denied. The images reuse the project's PHP/OPcache limits.

FPM liveness (`mooship-healthcheck`) uses a real FastCGI ping, independent of the database. nginx liveness is `/healthz`; `/readyz` checks PHP/DB readiness and returns 503 during DB failure or a version mismatch. Compose disables the FPM health check for install/cron roles. PHP and nginx use SIGQUIT for graceful Docker shutdown; Kubernetes pre-stop hooks request graceful shutdown within a 60-second termination budget.

File sessions persist in the data volume by default. Optional Redis sessions do not configure MUC. Multiple app replicas require shared data, compatible caches/sessions and capacity planning. Bake plugins into derived PHP/nginx images consistently; browser code installation is disabled. Uploaded files, caches and language packs remain runtime data.

## Backups and upgrades

Back up the database and `moodledata` together while writes/cron are stopped or under a consistent maintenance procedure. Retain exact image references, configuration, and separately protected secrets. The host installer's `backup.sh`/`restore.sh` expects a different layout and does not manage this stack.

Test upgrades against a restored copy. Enable maintenance with the old image, stop web/cron/app, take consistent backups, select matching new image tags, and run `php admin/cli/upgrade.php --non-interactive` as a one-off app container. Start services and disable maintenance after checks. Ordinary startup rejects mismatching schema versions. Rollback after schema changes requires restoring both DB and data with the old image; changing tags alone is insufficient. Do not downgrade database engines by switching overlays.

## Kubernetes

[config.yml](../deploy/k8s/config.yml) provides ConfigMap and RWX PVC. [runtime.yml](../deploy/k8s/runtime.yml) provides Service, a PHP/nginx Deployment and a separate CronJob. [install.yml](../deploy/k8s/install.yml) provides an explicit initialization Job. They use stable `v1`, `apps/v1`, and `batch/v1` APIs, non-root execution, read-only roots, dropped capabilities, startup/liveness/readiness probes, and temporary volumes. Resource values are initial estimates. The DB is external; the default Deployment has one replica and uses Recreate for controlled upgrades.

Verify the cluster/namespace, set available matching image tags (prefer release digests), edit the public origin and DB settings, and provision an RWX storage class supporting UID/GID 1000. The app and scheduler share the data PVC. Create Secrets in that namespace:

```bash
kubectl create secret generic mooship-db --from-file=password=.secrets/db_password
kubectl create secret generic mooship-admin --from-file=password=.secrets/admin_password
```

Initialize before starting the runtime:

```bash
kubectl apply -f deploy/k8s/config.yml
kubectl apply -f deploy/k8s/install.yml
kubectl wait --for=condition=complete --timeout=15m job/mooship-install
kubectl logs job/mooship-install
kubectl apply -f deploy/k8s/runtime.yml
```

Run the final command only after installation succeeds. Remove the admin Secret after success if no longer needed. A partial install needs investigation and an explicitly reset empty DB before retry; the Job has no automatic retry. Ingress/TLS, DB transport, network policy and backups depend on the target cluster. These manifests do not establish a tested production cluster deployment.

## Keeping images in sync

Keep container assets LF-only, including `docker/health.txt`; a CRLF response can pass a stripped HTTP assertion while failing Docker's exact liveness probe. The runtime suite checks the actual nginx Docker health state independently of the database. For a release build from Windows, export the tagged inputs using `git -c core.autocrlf=false archive` into a clean build context; ordinary Windows checkout/archive conversion can otherwise change the image bytes.

Assess image impact whenever behavior, dependencies, or configuration changes. The host installer and standalone runtime are separate implementations; inspect both when the same behavior applies to them, respecting their supported Moodle/PHP versions.

| Changed inputs | Image impact |
| --- | --- |
| Root `Dockerfile`, its downloaded Moodle source, base images or extension pins | Trace affected stages; shared Moodle code changes require matching `app` and `web` builds. Update Moodle version, commit and archive hash together. |
| `docker/*.php`, app entrypoint, cron, health check, FPM settings, `moodle/.config/php/mooship.ini` | These are copied into `app`; rebuild it when these inputs change. |
| `docker/nginx.conf.template`, `docker/web-entrypoint.sh`, `docker/health.txt` | These are copied into `web`; rebuild it when these inputs change. |
| `.dockerignore` or newly added runtime files | Verify the required inputs enter the build context and are copied into the correct target. |
| Compose, Kubernetes manifests, environment examples | Usually external to the images; validate configuration and runtime compatibility. Rebuild only if image contents or their startup contract also need changes. |
| Host installer, lifecycle utilities, `lib/`, other host templates, documentation | Not copied into the standalone images. Check whether the behavior also needs a corresponding runtime change; otherwise no image rebuild is needed. |

Update affected image sources, build definitions, configuration, manifests, tests and documentation in the same task. Editing a file already copied into an image can be sufficient at source level; do not change the Dockerfile merely to force a rebuild. Plugins and other shared Moodle code must stay consistent between PHP and nginx.

Check Docker availability, rebuild the affected targets using the commands above, and run the relevant [image tests](#tests-and-later-publication) on the resulting pair. Add or adjust behavioral tests when needed. Use an unchanged companion only when its contents and interface remain compatible. Validate Compose/Kubernetes configuration when touched; host installer E2E does not replace standalone image tests. Report unavailable checks explicitly. Documentation-only changes need content/link checks, without rebuilding images.

In the task report, state whether images are affected and why, which targets were rebuilt, and which checks ran. Distinguish a source update, a local build, runtime verification, registry publication and deployment. Existing published images do not acquire repository changes automatically; publication and rollout follow the user's authorized scope, with verified release tags/digests recorded separately.

## Tests and later publication

Build both tags, pull the test DB images, and run the isolated suite:

```bash
docker pull postgres:17-alpine
docker pull mysql:8.4
MOOSHIP_IMAGE_TESTS=1 PYTHONPATH=tests python3 -B -m unittest test_runtime_image -v
```

Tests use disposable uniquely labeled containers, a private network and volumes, publish no host ports, and clean up only their own resources. They cover secrets, non-root/immutable execution, invalid settings, real PostgreSQL/MySQL installs, repeated install/version refusal, HTTP login/protected paths, cron, DB failure/recovery, and graceful shutdown. The [image workflow](../.github/workflows/image.yml) builds/tests on PRs and `main`, without registry credentials or publication.

For Docker Hub, choose a confirmed Mooship release identifier and build/test that exact pair. Keep the Moodle version in both tags. `MOOSHIP_VERSION` sets OCI version metadata; `VCS_REF` identifies the source commit. The Dockerfile pins PHP/nginx digests and the Moodle commit/archive SHA-256. A Moodle update must deliberately change and verify its version, commit and hash together, for both targets.

```bash
read -r -p 'Confirmed Mooship release tag: ' RELEASE
REVISION=$(git rev-parse HEAD)
APP="shellharbor/mooship:${RELEASE}-moodle4.5.15-php8.3"
WEB="shellharbor/mooship:${RELEASE}-moodle4.5.15-nginx"
docker build --target app --build-arg "MOOSHIP_VERSION=$RELEASE" --build-arg "VCS_REF=$REVISION" -t "$APP" .
docker build --target web --build-arg "MOOSHIP_VERSION=$RELEASE" --build-arg "VCS_REF=$REVISION" -t "$WEB" .
MOOSHIP_APP_IMAGE="$APP" MOOSHIP_WEB_IMAGE="$WEB" MOOSHIP_IMAGE_TESTS=1 PYTHONPATH=tests \
  python3 -B -m unittest test_runtime_image -v
docker login --username shellharbor
docker push "$APP"
docker push "$WEB"
```

First create `shellharbor/mooship` on Docker Hub under an account you control. Use an access token at the login prompt. Publish both tags and record digests; set `MOOSHIP_APP_IMAGE`/`MOOSHIP_WEB_IMAGE` in Compose accordingly. Multi-platform publication needs explicit build/runtime tests per architecture; these commands publish the local platform only. Do not use the nginx tag as the PHP runtime.

Mooship wrapper code is MIT licensed; bundled Moodle/dependencies retain their upstream licenses, including Moodle's GPL-3.0-or-later terms. Moodle's `COPYING.txt` and dependency notices remain under `/opt/moodle`; the wrapper license is `/opt/mooship/LICENSE`. Distribute corresponding sources and notices when publishing. See [requirements](https://moodledev.io/general/releases/4.5) and the [pinned Moodle source](https://github.com/moodle/moodle/tree/0a694ba9b8b4183bf7a45094cfa7211030db3192).
