# ADR-0001: Explicit data management and a complete recovery archive

- Date: 2026-10-04
- Status: accepted

## Context

Repeated deployment deleted the moodledata directory while retaining the old database volume. Zip backups contained only files, excluding the database and SSL. Continuing after Moodle or SSL failures produced false success messages. The user requested the P1 fixes and chose the name Mooship and repository shellharbor/mooship.

## Options

1. Keep recreating projects with automatic data deletion.
2. Automatically update or restore existing projects; this requires a separate contract for migrations, compatibility, and rollback.
3. Reject occupied resources and separate explicit removal from recovery using a complete archive.

Backup options considered were a file-only zip, separate manual dumps, and a single archive created while the application is stopped.

## Decision

The third option was chosen. Deploy and restore accept only free resources. Native preflight runs before creating the directory; native database removal requires a record that this project created it successfully. Shared functions validate the slug and path. Required operation failures terminate the script with a nonzero exit code; the application is published through the proxy after successful installation or restoration.

A v1 archive contains the directory, database dump, SSL, and manifest. The application and SSL renewal are paused during the snapshot; EXIT cleanup resumes services that were previously running. Restore validates the archive before applying it, requires entering the slug, and does not automatically roll back or replace existing projects. This is a simple, verifiable contract without new infrastructure or Python dependencies.

## Consequences

Repeated deployment is no longer an update mechanism. Temporary copy space and a downtime window are required. Resources left after a partial failure must be handled explicitly. Old zip archives cannot provide a complete restore; old native projects without a marker require manual database removal after ownership verification. Archives contain secrets, have mode 600, and are retained when a site is removed. Encryption, external storage, and retention policies remain separate tasks.

Current template changes do not alter a running server; required actions are documented in the README. The P2 HTTP mode `--no-ssl` is outside this decision's scope.

## Validation

Regression tests in `tests/test_scripts.py`, extraction checks in `tests/test_state.py`, real database round trips in `tests/test_database_roundtrip.py`, Bash syntax, ShellCheck, and `docker compose config` for four variants. User procedure: [BACKUP.md](../BACKUP.md).
