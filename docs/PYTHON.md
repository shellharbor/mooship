# Mooship Python CLI

Install Mooship through pip or pipx, then use one command for its existing Moodle deployment, backup, restore and diagnostics scripts. The Python package needs Python 3.8+ and has no runtime dependencies. It follows LaraShip's verified-release installer design. Installing the package does not deploy Moodle, install Docker or modify server resources.

## Install the CLI

Version 1.2.0 introduces Python packaging. Until it is published, install a reviewed checkout with `pipx install .` or `python -m pip install .` in a virtual environment. After publication:

```bash
pipx install mooship==1.2.0
mooship --version
mooship --help
```

Help and installation previews work without root. Server operations target Ubuntu 20.04+ with Bash, Python 3 and Docker/Compose; use SSH from Windows/macOS. Do not use `sudo pip` or bypass OS-managed Python protections.

## Install the native toolkit

The CLI downloads an exact official GitHub release archive and its SHA-256 file over HTTPS, verifies the checksum, archive paths/types/limits and embedded VERSION, then installs into a new directory. Existing files/directories/symlinks are refused. A failed copy remains marked for inspection and cannot silently be reused. Checksums establish consistency with the release assets rather than an independent signature.

```bash
mooship install --version 1.2.0 --directory /opt/mooship --dry-run
MOOSHIP_CLI="$(command -v mooship)"
sudo "$MOOSHIP_CLI" install --version 1.2.0
mooship toolkit-version
sudo "$MOOSHIP_CLI" deploy -- \
  --slug lms --domain lms.example.com --db-type postgres --ssl-email admin@example.com
sudo "$MOOSHIP_CLI" doctor -- --slug lms
sudo "$MOOSHIP_CLI" backup -- --slug lms
```

Default directory: `/opt/mooship`; its parent must exist. Use `--directory /absolute/path` before `--` for another installation or a complete reviewed checkout containing VERSION. The CLI never escalates privileges implicitly; underlying scripts retain their root checks, confirmation prompts and operational contracts.

## Commands and forwarding

```text
mooship --version
mooship install [--version X.Y.Z] [--directory PATH] [--dry-run]
mooship toolkit-version [--directory PATH]
mooship deploy|activate|deactivate|remove|list|backup|restore|schedule-backup|doctor [--directory PATH] -- [script arguments]
```

Arguments following `--` are forwarded unchanged as separate values. The adapter does not print them. Terminal input, signals and exit codes pass to the existing Bash process, including doctor's status 0/1/2. Argument parsing errors exit 2, installation/preflight errors exit 1, and interrupted installation exits 130. Check the [README](../README.md) and each script's supported flags before use.

The Docker Hub images contain the Moodle application and nginx, not these host administration scripts. There is no privileged Docker-controller backend in this CLI. Run the standalone stack using the separate [Docker guide](DOCKER.md).

Updating the Python package updates the adapter only. Install a new native toolkit into a new directory and select it explicitly; existing sites, data, backups and templates are not migrated. Uninstalling the package does not remove sites or toolkit files.

## Build and verify

```bash
python -m pip install -r requirements-python-build.txt
python -m unittest discover -s tests -p test_python_cli.py -v
python -m build
python -m twine check --strict dist/*
```

The package workflow also rebuilds the wheel from the source distribution, installs it in fresh Python environments, and runs installed CLI checks. Native toolkit archives are separate GitHub release assets generated from tracked runtime files by `.github/scripts/build_release.py`; no local secrets or AI-KIT files are included.

## PyPI publication

The Release workflow publishes checked distributions through [PyPI Trusted Publishing](https://docs.pypi.org/trusted-publishers/creating-a-project-through-oidc/), without a long-lived PyPI token. Configure a pending publisher in [your PyPI account](https://pypi.org/manage/account/publishing/): project **mooship**, owner **shellharbor**, repository **mooship**, workflow **release.yml**, environment **pypi**. A pending publisher does not reserve the package name. Create the matching GitHub environment and set repository variable `PYPI_PUBLISH=true` when configured.

See [release publication](RELEASING.md) for checked release tags, native assets, Docker Hub configuration, retries and evidence. Package version and toolkit release come from the same VERSION file.
