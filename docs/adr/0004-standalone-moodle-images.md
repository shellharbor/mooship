# ADR-0004: Immutable Moodle runtime and nginx companion

- Date: 2026-10-15
- Status: Accepted

## Context

The user requested a Moodle/PHP image for later Docker Hub publication, with separate nginx and DB services. The host installer manages Docker, host directories, certificates and shared proxy state; packaging it as a privileged Docker controller would not provide the chosen application runtime.

## Decision

Use one multi-stage root Dockerfile: default `app` target and `web` companion. Pin Moodle 4.5.15 by commit/archive SHA-256 and compatible PHP 8.3/nginx bases by digest. Both images contain matching immutable code, avoiding a shared mutable source volume or startup downloads. Use distinct tags in the future `shellharbor/mooship` repository. Publication remains separate.

Run as UID/GID 1000 with read-only roots, data/tmp mounts, external config, mounted secrets and graceful shutdown. Keep install/upgrade explicit; normal startup refuses an absent/incompatible schema. Installation requires an advisory DB lock and empty DB; the admin password is passed in PHP memory. Cron is an independent role. Readiness checks DB/schema availability; process liveness is independent of the DB.

Compose overlays provide PostgreSQL 17 or MySQL 8.4. Kubernetes combines PHP/nginx in one Deployment with RWX storage, an external DB, and separate install Job/CronJob. Start with one replica. CI builds and installs real Moodle on both DB engines without registry publication. Host installer templates and lifecycle commands remain independent.

## Alternatives and consequences

- A containerized host installer requires host filesystem/Docker access and conflicts with the requested runtime scope.
- An all-in-one PHP/nginx/DB image couples persistent state and unrelated lifecycles.
- Startup-populated shared code can leave PHP/nginx serving inconsistent versions during updates.
- Duplicated source increases registry storage, but keeps static assets consistent. Deploy matching tags/digests.
- Operators must back up DB/data and perform explicit tested upgrades; host installer backup tools expect a different layout.
- Bundled Moodle/dependencies retain their licenses; wrapper MIT terms do not replace Moodle's GPL terms.

See the [image operations guide](../DOCKER.md) for configuration, installation, health, storage, upgrades, tests and later publication.
