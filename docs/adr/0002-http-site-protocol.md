# ADR-0002: Explicit HTTP mode and a persistent site protocol

- Date: 2026-10-04
- Status: accepted

## Context

The P2 review found that `--no-ssl` skipped certificate issuance but left Moodle's `wwwroot` on HTTPS and nginx's HTTP listener serving ACME only. The result was an installed, inaccessible site. Backup restoration also lacked an explicit site protocol.

## Options

1. Keep `--no-ssl` as preparation for a later certificate.
2. Maintain separate HTTP and HTTPS application templates.
3. Derive the HTTP application listener from the existing HTTPS listener and persist the protocol.

## Decision

Choose option 3. `lib/web.py` derives the port-80 listener from Mooship's two-server template, preserving application routes, PHP settings, Basic Auth, and the document root while removing TLS directives and HSTS. The HTTPS block stays commented for a later explicit migration. The shared proxy already forwards HTTP to project nginx.

Default deployment remains HTTPS. `--no-ssl` sets HTTP `wwwroot` and CLI URLs and records `SITE_SCHEME=http` in `.env`. Restore reads this setting; legacy archives without it default to HTTPS, and unknown protocols are rejected. ACME locations use `^~` and `auth_basic off` to avoid hidden-file denial and authentication.

## Consequences

HTTP requires no certificate but provides no transport encryption. It is an explicit deployment choice, never an automatic fallback after a required SSL failure. Existing servers are not rewritten. Moving an HTTP site to HTTPS requires updating Moodle's address, `.env`, and both nginx configurations.

The renderer supports Mooship's template structure, including its fully commented HTTPS block, rather than arbitrary nginx configurations. It validates the block structure before writing and is idempotent. Application routes remain defined once in the source template.

## Validation

`tests/test_web.py` checks rendering, Basic Auth/ACME, Moodle 5.1's document root, malformed input, and repeated runs. `tests/test_scripts.py` checks deployment URLs and HTTP/HTTPS/legacy/invalid-protocol restoration. `tests/test_http_roundtrip.py` checks real nginx → nginx → PHP routing with synthetic fixtures, authentication, ACME, internal paths, and HTTPS regression.

The Moodle address follows [the official configuration contract](https://github.com/moodle/moodle/blob/v4.5.0/config-dist.php); nginx route/authentication behavior follows [location matching](https://nginx.org/en/docs/http/ngx_http_core_module.html#location) and [Basic Auth inheritance](https://nginx.org/en/docs/http/ngx_http_auth_basic_module.html).
