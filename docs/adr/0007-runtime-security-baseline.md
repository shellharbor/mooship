# ADR-0007: Enforce a shared Moodle/PHP security baseline

Status: accepted, 2026-10-28.

## Context

CVE-2026-109618 and CVE-2026-109619 require PHP patch floors 8.2.35, 8.3.36, 8.4.27 and 8.5.12. The owner prohibits PHP 8.1 and older and Moodle below 4.3. Previously, old templates and manual PHP selection could bypass compatibility recommendations; activation and restoration reused saved runtimes. Published 1.2.0 artifacts predate these requirements.

## Decision

Store floors, allowed Moodle/PHP pairs and defaults in one JSON policy distributed with both the host toolkit and standalone images. Enforce selection in the installer and lifecycle operations using standard-library Python; enforce the actual PHP runtime at build and startup using PHP. Pin all host bases by patch and digest. Remove prohibited legacy templates. Reject unknown branches and incompatible pairs, including patched PHP 8.5 until Moodle supports it. Keep backup/diagnostic/deactivation/removal access available for migration. Require updated toolkit policy assets from the Python adapter for deployment, activation and restore.

## Alternatives and consequences

Documentation alone leaves unsafe execution paths. Floating minor tags can retain vulnerable cached runtimes. Checking only `.env` misses stale images. A flat numeric minimum would incorrectly admit PHP 8.3.35 because it is greater than 8.2.35. Per-branch floors plus probes avoid these failures; build/startup guards cover direct image use.

Unknown future branches require an explicit policy update. Existing installations and backups need a reviewed migration and rebuild; they are not silently rewritten. The policy does not assert security support for old Moodle branches or patch downloaded Moodle core. Published immutable artifacts need a new release. Tests cover negative boundaries and lifecycle order as well as successful real installs. See [the operational policy](../RUNTIME_POLICY.md).
