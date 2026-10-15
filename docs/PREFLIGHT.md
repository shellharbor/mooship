# Deployment preflight and readiness

These checks apply to new host-installer deployments. Existing sites are not rewritten.

## Ports

Every explicit HTTP, HTTPS, PHP, Redis, PostgreSQL and MySQL port must be a decimal integer from 1 to 65535. Leading zeroes are normalized. Ports 80/443 are reserved for the shared proxy. Selected ports must be distinct; automatic allocation also excludes explicit assignments.

Published service ports must be available on loopback. Checks use a real TCP bind and Docker's publication inventory, including NAT mappings without a listening host process. Occupied native DB ports are expected and exempt from free-port checks. The race between checking and binding a port remains; startup errors are fatal.

## Native databases

Use `--db-native --db-host HOST`; the default is `host.docker.internal`. On Linux Docker Engine 20.10+, PHP and cron map that name to `host-gateway`. Custom addresses are used without that mapping. The address is persisted as `DB_HOST` and written into Moodle configuration.

Mooship creates the new database/user through the host's local administrative connection. `--db-host` selects the application's route to that same database; it is not remote provisioning. Do not select a different server from the one managed by the local database tools.

The DB must listen on an address reachable from the project's Docker network. Configure PostgreSQL `listen_addresses` and a narrowly scoped `pg_hba.conf` rule, or MySQL `bind-address`/grants, plus the firewall. Do not expose DB ports publicly to solve routing. Mooship does not rewrite shared database configuration or firewall rules.

Before native CREATE, PHP tests TCP reachability from its actual container. After CREATE, PHP authenticates with application credentials and executes `SELECT 1`. Containerized DBs use the same authentication probe. Errors do not print passwords or driver exceptions. Failure can leave a newly created owned DB/project for explicit recovery; automatic destructive cleanup is not performed.

New native archives retain their endpoint. Older archives without `DB_HOST` retain `172.17.0.1`, matching their archived `config.php`; migration is a separate operation.

## Readiness and installation

PHP-FPM uses a FastCGI ping; nginx serves `/mooship-healthz` without Moodle/Basic Auth; Redis uses authenticated `PING`. The installer waits for health instead of a fixed ten-second sleep. DB readiness is bounded separately. Each service gets 90 checks spaced two seconds apart, plus probe execution time. `MOOSHIP_READY_ATTEMPTS` adjusts the count; Docker health checks have five-second execution timeouts.

Process health is independent of DB availability. PHP's DB probe establishes authentication before initialization. Installation checks distinguish an empty DB (exit 3), a present `mdl_config.version` record (0), a populated DB without that record (4), and connection/probe failure (1). This classification is not a full schema audit. Partial/unknown state never silently skips or retries installation. The fixed `mdl_` prefix matches the host installer.

Cron starts after successful installation/mail configuration, or after restoring data. Older archives without health metadata use live FPM socket and nginx configuration checks. New templates include health checks; Compose parsing alone does not prove readiness.

After Moodle code/config generation, validate and reload nginx so a newly selected `public/` document root is active before publishing the site. Full E2E also waits for health after backup resumes services, before running doctor. Its one-off cron check uses `--keep-alive=0` to execute tasks without the administrator-configured idle polling period.

## Tests

`tests/test_preflight.py` covers invalid/occupied/duplicate ports, native endpoint selection, secret transport, bounded health transitions and installation refusal. Opt-in `tests/test_native_preflight.py` publishes a disposable synthetic PostgreSQL/MySQL DB on a random host port and checks real PHP host-gateway access, wrong credentials, empty/partial/installed states and an unavailable endpoint. Temporary host publications are needed for this test; these are not production databases.

The full E2E matrix installs Moodle 4.5/5.3 with PostgreSQL/MySQL and then checks native routing using its built PHP image. It also checks HTTP, Redis sessions, SMTP, cron, backup retention, systemd schedules and doctor. TLS issuance is outside the synthetic HTTP runner setup.
