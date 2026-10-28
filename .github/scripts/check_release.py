"""Require matching release metadata and successful checks on this exact commit."""

import json
import os
from pathlib import Path
import re
import subprocess

REQUIRED = {"CI", "Configuration", "Component integration", "Security", "CodeQL", "Documentation",
            "Moodle images", "Python package"}


def validate_tag(tag: str, version: str) -> None:
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag) or tag != f"v{version}":
        raise ValueError("Release tag must be vX.Y.Z and match VERSION")


def check_runs(runs: list, commit: str) -> None:
    latest = {}
    for run in sorted(runs, key=lambda item: item["id"], reverse=True):
        if run["head_sha"] == commit:
            latest.setdefault(run["name"], run)
    failed = sorted(name for name in REQUIRED if name not in latest
                    or latest[name]["status"] != "completed" or latest[name]["conclusion"] != "success")
    if failed:
        raise ValueError("Missing successful exact-commit workflows: " + ", ".join(failed))


def command(*args: str) -> str:
    return subprocess.run(list(args), check=True, capture_output=True, text=True, timeout=60).stdout.strip()


def main() -> None:
    version = Path("VERSION").read_text(encoding="ascii").strip()
    validate_tag(os.environ["RELEASE_TAG"], version)
    commit = command("git", "rev-parse", "HEAD")
    tagged = command("git", "rev-parse", "--verify", f"refs/tags/{os.environ['RELEASE_TAG']}^{{commit}}")
    if tagged != commit:
        raise ValueError("Checkout does not match the exact release tag commit")
    runs = json.loads(command("gh", "api", f"repos/{os.environ['GITHUB_REPOSITORY']}/actions/runs?head_sha={commit}&per_page=100"))
    check_runs(runs["workflow_runs"], commit)
    source = Path("Dockerfile").read_text(encoding="utf-8")
    moodle = re.search(r"^ARG MOODLE_VERSION=([0-9.]+)$", source, re.MULTILINE).group(1)
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
        output.write(f"commit={commit}\nversion={version}\nmoodle={moodle}\n")


if __name__ == "__main__":
    main()
