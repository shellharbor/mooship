"""Refuse to overwrite existing Docker Hub release tags before building/pushing."""

import os
import re
from urllib.error import HTTPError
from urllib.request import urlopen


def require_new_tag(tag: str) -> None:
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+-moodle[0-9.]+-(?:php8\.3|nginx)", tag):
        raise ValueError("Invalid Mooship release image tag")
    try:
        # Fixed HTTPS origin and validated tag prevent caller-supplied URL schemes.
        with urlopen(f"https://hub.docker.com/v2/repositories/shellharbor/mooship/tags/{tag}", timeout=30):  # nosec B310
            pass
    except HTTPError as exc:
        if exc.code == 404:
            return
        raise
    raise ValueError(f"Docker Hub tag already exists; refusing to overwrite {tag}")


def main() -> None:
    for suffix in ("php8.3", "nginx"):
        require_new_tag(f"{os.environ['VERSION']}-moodle{os.environ['MOODLE_VERSION']}-{suffix}")


if __name__ == "__main__":
    main()
