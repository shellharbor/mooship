# ADR-0005: Validate deployment boundaries and probe readiness from the application

- Date: 2026-10-15
- Status: Accepted

## Context

Explicit port values reached Compose without complete validation. Native DB connections assumed a fixed default-bridge IP. A running container and a fixed startup delay did not establish that PHP, nginx, Redis or the database could serve the application.

## Decision

Validate port syntax before side effects; normalize decimal values, reserve shared proxy ports, prevent duplicates and exclude selected ports from automatic allocation. Check both loopback TCP bind and Docker NAT publications. Native DB listeners are expected to occupy their port. This is a preflight check, not an atomic reservation.

Use a configurable native application endpoint, defaulting to host.docker.internal with PHP/cron host-gateway mappings. Keep administrative CREATE operations local and preserve DB ownership safeguards. Do not rewrite shared DB listeners, authentication rules or firewall settings. Probe TCP reachability from the actual PHP container before native CREATE, and authenticate/execute SQL afterward. Passwords travel through Docker client environment variables, not command arguments or error output.

Add process health for FPM/nginx/Redis, bounded waits, and explicit DB authentication. Start cron only after installation or restoration. Use structured DB installation states instead of parsing foreign help text. Keep compatibility paths for archived configurations without health metadata or a stored native endpoint.

Validate and reload nginx after Moodle configuration selects the document root. Preserve the configuration inode because nginx uses a single-file bind mount; replacing it leaves the container reading the old file. Health of the nginx process alone cannot prove that its loaded configuration matches a changed file. Wait for resumed service health before E2E runs doctor after backups.

## Alternatives and consequences

- A detected bridge IP alone still couples generated settings to host topology; host-gateway plus an explicit override permits controlled configuration changes.
- Automatically changing PostgreSQL/MySQL/firewall settings can affect unrelated databases and is outside deployment scope.
- A TCP connection alone is insufficient: Docker proxies may accept it after their backend stops. SQL probes are required.
- Liveness should not restart PHP/nginx for an unrelated DB outage; DB authentication is a separate deployment gate.
- Partial deployment resources remain for explicit recovery. Automatic destructive cleanup is not introduced.
- Old archives retain their original endpoint; migrating it requires an explicit change, not a silent restore rewrite.

See [preflight operations](../PREFLIGHT.md) and the regression/host-gateway tests for the contract and verification limits.
