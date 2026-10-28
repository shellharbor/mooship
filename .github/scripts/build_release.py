"""Build a deterministic native toolkit archive from Git's runtime-file inventory."""

import argparse
import gzip
import hashlib
import io
from pathlib import Path
import re
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[2]
FILES = {"VERSION", "LICENSE", "README.md", "deploy-moodle.sh", "activate.sh", "deactivate.sh",
         "remove.sh", "list-projects.sh", "backup.sh", "restore.sh", "schedule-backup.sh", "doctor.sh"}
DIRECTORIES = {"lib", "moodle", "nginxproxy"}


def build(root: Path, output: Path) -> Path:
    version = (root / "VERSION").read_text(encoding="ascii").strip()
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("VERSION must contain an exact X.Y.Z release")
    inventory = subprocess.run(["git", "-C", str(root), "ls-files", "-z"],
                               check=True, capture_output=True, timeout=30).stdout
    names = sorted(name for name in inventory.decode("utf-8").split("\0") if name
                   and (name in FILES or name.split("/", 1)[0] in DIRECTORIES))
    if not FILES.issubset(names):
        raise ValueError("Required toolkit files are missing from Git's inventory")
    output.mkdir(parents=True, exist_ok=True)
    archive = output / f"mooship-{version}.tar.gz"
    # Exclusive output prevents an accidental local overwrite; retries use a fresh directory.
    with archive.open("xb") as destination, gzip.GzipFile(fileobj=destination, mode="wb", mtime=0, filename="") as gz:
        with tarfile.open(fileobj=gz, mode="w|") as tar:
            for name in names:
                path = root / name
                if path.is_symlink() or not path.is_file():
                    raise ValueError(f"Toolkit source must be a regular file: {name}")
                content = path.read_bytes()
                if path.suffix == ".sh":
                    content = content.replace(b"\r\n", b"\n")
                member = tarfile.TarInfo(f"mooship-{version}/{name}")
                member.size = len(content)
                member.mode = 0o755 if path.suffix == ".sh" else 0o644
                tar.addfile(member, io.BytesIO(content))
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    archive.with_name(archive.name + ".sha256").write_text(
        f"{digest}  {archive.name}\n", encoding="ascii",
    )
    return archive


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    print(build(ROOT, args.output))


if __name__ == "__main__":
    main()
