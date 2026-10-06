"""Mooship backup metadata and safe, dependency-free archive extraction (Python 3.8+)."""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import posixpath
import re
import shutil
import sys
import tarfile
from typing import Dict


def read_env(path: Path) -> Dict[str, str]:
    """Read Mooship's plain key=value file as data; never execute its contents."""
    if path.is_symlink() or not path.is_file():
        raise ValueError("Expected a regular project .env file")
    values = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line or line.lstrip().startswith("#"):
            continue
        key, separator, value = line.partition("=")
        if not separator or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
            raise ValueError("Invalid project .env entry")
        values[key] = value
    return values


def digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def write_manifest(directory: Path, slug: str) -> None:
    values = read_env(directory / "project" / ".env")
    database = "postgres" if values.get("DB_POSTGRES_NAME") else "mysql"
    manifest = {
        "format": 1, "slug": slug, "database": database,
        "native": values.get("DB_NATIVE") == "true",
        "domain": values["SITE_HOST"],
        "moodle_version": values["MOODLE_VERSION"],
        "php_version": values["PHP_VERSION"],
        "sha256": {name: digest(directory / name)
                   for name in ("database.dump", "certificates.tar")},
    }
    (directory / "manifest.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


def checked_members(archive: tarfile.TarFile) -> Dict[str, tarfile.TarInfo]:
    members = {}
    for member in archive:
        path = PurePosixPath(member.name)
        if path.is_absolute() or ".." in path.parts or "\\" in member.name:
            raise ValueError("Unsafe archive member path")
        name = str(path)
        if name == "." and member.isdir():
            continue
        if name in members or not (member.isdir() or member.isfile() or member.issym()):
            raise ValueError("Duplicate or unsupported archive member")
        if member.issym():
            target = posixpath.normpath(posixpath.join(posixpath.dirname(name), member.linkname))
            if (posixpath.isabs(member.linkname) or target == ".." or
                    target.startswith("../") or "\\" in member.linkname):
                raise ValueError("Unsafe archive symlink")
        members[name] = member
    for name in members:
        for parent in PurePosixPath(name).parents:
            if str(parent) in members and not members[str(parent)].isdir():
                raise ValueError("Archive path traverses a symlink or file")
    return members


def extract_checked(path: Path, destination: Path) -> None:
    """Validate the complete member list before writing any payload."""
    with tarfile.open(path, "r:*") as archive:
        members = checked_members(archive)
        for name, member in members.items():
            target = destination / name
            target.parent.mkdir(parents=True, exist_ok=True)
            if member.isdir():
                target.mkdir(exist_ok=True)
            elif member.issym():
                target.symlink_to(member.linkname)
            else:
                with archive.extractfile(member) as source, target.open("xb") as output:
                    shutil.copyfileobj(source, output)
                target.chmod(member.mode & 0o777)


def extract_backup(path: Path, destination: Path, slug: str) -> None:
    if any(destination.iterdir()):
        raise ValueError("Restore staging directory must be empty")
    extract_checked(path, destination)
    manifest_path = destination / "manifest.json"
    if manifest_path.is_symlink():
        raise ValueError("Manifest must be a regular file")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if (not isinstance(manifest, dict) or manifest.get("format") != 1 or
            manifest.get("slug") != slug or not isinstance(manifest.get("sha256"), dict)):
        raise ValueError("Unsupported backup format or slug mismatch")
    values = read_env(destination / "project" / ".env")
    database = "postgres" if values.get("DB_POSTGRES_NAME") else "mysql"
    if (manifest.get("database") != database or
            manifest.get("native") != (values.get("DB_NATIVE") == "true") or
            manifest.get("domain") != values.get("SITE_HOST")):
        raise ValueError("Backup metadata does not match project configuration")
    for name in ("database.dump", "certificates.tar"):
        payload = destination / name
        if payload.is_symlink() or not payload.is_file() or payload.stat().st_size == 0:
            raise ValueError("Backup payload is missing or empty")
        if digest(payload) != manifest.get("sha256", {}).get(name):
            raise ValueError("Backup payload checksum mismatch")
    with tarfile.open(destination / "certificates.tar", "r:") as certificates:
        checked_members(certificates)
    for name in ("docker-compose.yml", "public_html/config.php"):
        required = destination / "project" / name
        if required.is_symlink() or not required.is_file():
            raise ValueError("Project configuration is missing or is a symlink")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    env = commands.add_parser("env")
    env.add_argument("path", type=Path)
    env.add_argument("key")
    manifest = commands.add_parser("manifest")
    manifest.add_argument("directory", type=Path)
    manifest.add_argument("slug")
    extract = commands.add_parser("extract")
    extract.add_argument("archive", type=Path)
    extract.add_argument("destination", type=Path)
    extract.add_argument("slug")
    args = parser.parse_args()
    try:
        if args.command == "env":
            print(read_env(args.path).get(args.key, ""))
        elif args.command == "manifest":
            write_manifest(args.directory, args.slug)
        else:
            extract_backup(args.archive, args.destination, args.slug)
    except (OSError, ValueError, KeyError, tarfile.TarError) as error:
        print("Mooship: {}".format(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
