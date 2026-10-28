"""Upload missing native release assets and refuse conflicting existing content."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def command(*args: str) -> str:
    return subprocess.run(list(args), capture_output=True, text=True, check=True, timeout=120).stdout


def main() -> None:
    tag = os.environ["RELEASE_TAG"]
    assets = json.loads(command("gh", "release", "view", tag, "--json", "assets"))["assets"]
    existing = {asset["name"] for asset in assets}
    for path in sorted(Path(sys.argv[1]).iterdir()):
        if not path.is_file() or not (path.name.endswith(".tar.gz") or path.name.endswith(".sha256")):
            continue
        if path.name in existing:
            with tempfile.TemporaryDirectory() as directory:
                command("gh", "release", "download", tag, "--pattern", path.name, "--dir", directory)
                actual = hashlib.sha256((Path(directory) / path.name).read_bytes()).digest()
                if actual != hashlib.sha256(path.read_bytes()).digest():
                    raise ValueError(f"Existing release asset differs; refusing to replace {path.name}")
        else:
            command("gh", "release", "upload", tag, str(path))
        print(f"Verified release asset: {path.name}")


if __name__ == "__main__":
    main()
