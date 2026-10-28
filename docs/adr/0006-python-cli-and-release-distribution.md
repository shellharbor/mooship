# ADR-0006: Python CLI and release distribution

- Date: 2026-10-28
- Status: Accepted

## Context

The user requested Docker Hub publication and a Python package for PyPI, using neighboring LaraShip as the reference. Mooship already has host administration scripts and separate immutable Moodle/PHP and nginx images. Reimplementing host deployment in Python or turning the application image into a privileged Docker controller would introduce unrelated operational changes.

## Decision

Publish a dependency-free Python 3.8+ adapter with the `mooship` console command. Follow LaraShip's exact-release installer design: HTTPS downloads of the official GitHub archive/checksum, bounded safe extraction, matching VERSION and a new installation directory. Forward native commands through an argument-list exec, preserving terminal input, signals, existing confirmations and backend exit codes.

Use a root VERSION shared by Python metadata, toolkit release assets and Docker OCI metadata. Generate reproducible native assets from an explicit tracked runtime inventory. Validate wheel/sdist installation and Python compatibility in CI. Gate release publication on matching tag/version and successful workflows for the exact source commit; publish checked distributions with PyPI OIDC from a separate job. Docker publication builds/tests both application targets before pushing versioned Linux amd64 tags. Account configuration and actual uploads remain separate, verified steps.

## Alternatives and consequences

- A full Python rewrite would duplicate mature deployment/lifecycle behavior and require its own full regression effort.
- Bundling the toolkit inside the wheel would simplify offline installation but couple server template files to site-packages. A verified native release keeps an explicit inspectable installation and existing script-relative paths.
- A Docker CLI backend like LaraShip's does not fit the chosen Mooship application images. This adapter manages native host scripts only; the standalone runtime uses Compose or Kubernetes.
- Checksums establish consistency with the official release assets rather than an independent signature. PyPI package installation itself performs no server deployment or release download.
- Existing release tags and published versions must not be rewritten to add packaging. Introduce a new release, initially 1.2.0, after checks pass.

See [the Python guide](../PYTHON.md) and [release publication](../RELEASING.md).
