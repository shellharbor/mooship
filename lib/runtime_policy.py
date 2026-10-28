"""Enforce the PHP security floor and verified Moodle compatibility before deployment."""

import json
from pathlib import Path
import re
import sys
from typing import Any, Dict, Optional, Tuple

POLICY_PATH = Path(__file__).resolve().parents[1] / "moodle/.docker/php/runtime-policy.json"


def version(value: str) -> Tuple[int, ...]:
    if not re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:\.(?:0|[1-9][0-9]*))?", value):
        raise ValueError("Use a stable numeric version: X.Y or X.Y.Z")
    numbers = tuple(map(int, value.split(".")))
    return numbers + (0,) * (3 - len(numbers))


def select(moodle: str, php: str = "", policy: Optional[Dict[str, Any]] = None) -> str:
    policy = policy or json.loads(POLICY_PATH.read_text(encoding="utf-8"))
    if version(moodle) < version(policy["minimum_moodle"]):
        raise ValueError("Moodle below 4.3 is prohibited by the PHP security policy")
    branch = ".".join(moodle.split(".")[:2])
    if branch not in policy["moodle_php"]:
        raise ValueError("Unverified Moodle branch; update the compatibility policy before deployment")
    php = {"82": "8.2", "83": "8.3", "84": "8.4", "85": "8.5"}.get(php, php)
    php = php or policy["default_php"][branch]
    if php not in policy["minimum_php"]:
        raise ValueError("PHP 8.1 and older are prohibited; select a supported X.Y branch, not a patch override")
    if php not in policy["moodle_php"][branch]:
        raise ValueError(f"PHP {php} is not supported by Moodle {branch}")
    return php


def check_php(php: str, policy: Optional[Dict[str, Any]] = None) -> None:
    policy = policy or json.loads(POLICY_PATH.read_text(encoding="utf-8"))
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", php):
        raise ValueError("Cannot verify a stable PHP patch version")
    branch = ".".join(php.split(".")[:2])
    floor = policy["minimum_php"].get(branch)
    if floor is None or version(php) < version(floor):
        raise ValueError(f"PHP {php} is prohibited; required floors: " + ", ".join(policy["minimum_php"].values()))


def check_source(directory: Path, expected: str, php: str = "") -> str:
    """Read official release metadata as data, without executing project PHP."""
    candidates = (directory / "public/version.php", directory / "version.php")
    source = next((path for path in candidates if path.is_file() and not path.is_symlink()), None)
    if source is None:
        raise ValueError("Cannot verify installed Moodle: version.php is missing")
    text = source.read_text(encoding="utf-8")
    releases = re.findall(r"^\s*\$release\s*=\s*(['\"])([0-9]+\.[0-9]+(?:\.[0-9]+)?)(?:[ \t][^'\"\r\n]*)?\1\s*;", text, re.MULTILINE)
    if len(releases) != 1:
        raise ValueError("Cannot verify a stable Moodle release from version.php")
    actual = releases[0][1]
    select(actual, php)
    if version(actual) != version(expected):
        raise ValueError(f"Moodle source/metadata mismatch: source {actual}, .env {expected}; review the upgrade before startup")
    return actual


def main() -> int:
    try:
        if len(sys.argv) == 3 and sys.argv[1] == "check-php":
            check_php(sys.argv[2])
        elif len(sys.argv) == 4 and sys.argv[1] == "check-runtime":
            check_php(sys.argv[3])
            select(sys.argv[2], ".".join(sys.argv[3].split(".")[:2]))
        elif len(sys.argv) in (3, 4) and sys.argv[1] == "select":
            print(select(sys.argv[2], sys.argv[3] if len(sys.argv) == 4 else "").replace(".", ""))
        elif len(sys.argv) in (4, 5) and sys.argv[1] == "check-source":
            check_source(Path(sys.argv[2]), sys.argv[3], sys.argv[4] if len(sys.argv) == 5 else "")
        else:
            raise ValueError("Usage: runtime_policy.py select MOODLE [PHP] | check-php X.Y.Z | check-runtime MOODLE X.Y.Z")
    except (ValueError, OSError, KeyError) as error:
        print(f"[ERROR] {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
