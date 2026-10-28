# Release publication

Mooship 1.2.0 introduces a dependency-free Python CLI and the standalone Moodle/PHP and nginx images. The host toolkit, Python distribution and image metadata use root VERSION. A new version never changes old tags, existing installations, databases or volumes.

## Prepare and verify

1. Update VERSION and release documentation, keeping Docker image tags and the pinned Moodle/PHP pair consistent. Build/test the package and the affected images according to [Python](PYTHON.md) and [Docker](DOCKER.md).
2. Push a review branch and require successful **CI**, **Configuration**, **Component integration**, **Security**, **CodeQL**, **Documentation**, **Moodle images**, and **Python package** workflows on the exact commit being released. Dependency Review additionally needs GitHub's repository Dependency Graph; it is separate from the release gate.
3. Create a matching `vX.Y.Z` tag on that verified commit, push it, and publish a GitHub release with that tag. The **Release** workflow checks tag/VERSION and exact-commit workflow evidence before creating release assets or publishing packages.

The native archive contains tracked runtime files only: scripts, `lib/`, Moodle/proxy templates, VERSION, README and LICENSE. `.github/scripts/build_release.py` normalizes archive metadata and shell line endings, and generates a separate `.sha256` file. Local credentials, AI-KIT, working environments and test reports are excluded by the explicit runtime inventory. The Python installer rejects unsafe/mismatched archives, existing destinations and partial installations.

## Docker Hub

The Docker Hub repository is **shellharbor/mooship**. Configure repository variable `DOCKERHUB_USERNAME`, a read/write `DOCKERHUB_TOKEN` Secret, and variable `DOCKERHUB_PUBLISH=true` to enable the optional release job. The existing Moodle images workflow remains build/test-only. Local Docker Desktop login does not automatically configure GitHub Actions secrets.

The release job checks out the verified commit, builds Linux amd64 `app` and `web`, runs real Moodle installs with PostgreSQL and MySQL, then publishes:

```text
shellharbor/mooship:1.2.0-moodle4.5.15-php8.3
shellharbor/mooship:1.2.0-moodle4.5.15-nginx
```

PHP and nginx must use the matching Moodle source. No `latest` alias or untested architecture is published. Record the resulting digests and prefer digest references in production. The [Docker guide](DOCKER.md#tests-and-later-publication) also supports a checked manual publication using an existing local Docker login; always set MOOSHIP_VERSION and VCS_REF to the release version and exact source commit.

## PyPI

Configure the pending publisher described in [the Python guide](PYTHON.md#pypi-publication), create GitHub environment **pypi**, and set variable `PYPI_PUBLISH=true`. The isolated publish job receives only built distributions and short-lived OIDC credentials. No long-lived PyPI token or build-source checkout is needed in that job.

PyPI project name: **mooship**. Distributions contain the Python adapter; the separately checksummed GitHub archive supplies the native toolkit. The Docker images contain Moodle itself. These are separate distribution formats with different operational roles.

## Retry and verification

Use **Release → Run workflow**, select the reviewed workflow branch and enter the existing release tag. The tag must still match VERSION and have successful checks. Native asset retries compare content and refuse to replace conflicting files; PyPI skips existing distribution files. Docker publication refuses existing release image tags; disable `DOCKERHUB_PUBLISH` when retrying other formats after a successful image upload. Do not move an existing tag to publish changed code. Fixes require a new version.

After publication, verify the Docker Hub tags/digests, pull and smoke-test the images, and install the package from PyPI in a fresh environment. Also run `mooship install` against the real GitHub assets in an unused temporary destination, then check the toolkit VERSION. A workflow definition or local build alone is not publication evidence.
