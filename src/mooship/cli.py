"""Install Mooship and run its existing Moodle deployment toolkit."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import shutil
import sys
import tarfile
from urllib.error import URLError

from . import __version__
from .install import absolute_path, install_native, installation_path, release_version

COMMANDS = {
    "deploy": "deploy-moodle.sh", "backup": "backup.sh", "restore": "restore.sh",
    "schedule-backup": "schedule-backup.sh", "doctor": "doctor.sh",
    "activate": "activate.sh", "deactivate": "deactivate.sh", "remove": "remove.sh",
    "list": "list-projects.sh",
}


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--version", action="version", version=f"mooship {__version__}")
    commands = result.add_subparsers(dest="command", required=True)
    install = commands.add_parser("install", help="Download and verify an official toolkit release")
    install.add_argument("--version", dest="release", default=__version__, help="Exact toolkit version")
    install.add_argument("--directory", default="/opt/mooship", help="New toolkit directory")
    install.add_argument("--dry-run", action="store_true", help="Preview without downloads or writes")
    for name in (*COMMANDS, "toolkit-version"):
        command = commands.add_parser(name, help=f"Run the existing {name} command")
        command.add_argument("--directory", default="/opt/mooship", help="Installed toolkit or reviewed checkout")
        command.add_argument("arguments", nargs=argparse.REMAINDER, help="Pass backend arguments after --")
    return result


def require_linux() -> None:
    if sys.platform != "linux":
        raise ValueError("Run installation and server operations on the target Linux server over SSH")


def toolkit_root(directory: str) -> Path:
    root = absolute_path(directory)
    if (root / ".mooship-installing").exists():
        raise ValueError("Toolkit installation is incomplete; inspect it before use")
    if not (root / "VERSION").is_file():
        raise ValueError("Toolkit is missing; run 'mooship install' or select --directory")
    release_version((root / "VERSION").read_text(encoding="ascii").strip())
    return root


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        if args.command == "install":
            version = release_version(args.release)
            destination = installation_path(args.directory)
            if args.dry_run:
                print(f"Would download and verify Mooship {version}, then install into {destination}")
                return 0
            require_linux()
            install_native(version, str(destination))
            print(f"Installed Mooship {version} into {destination}")
            return 0
        arguments = args.arguments[1:] if args.arguments[:1] == ["--"] else args.arguments
        root = toolkit_root(args.directory)
        if args.command == "toolkit-version":
            if arguments:
                raise ValueError("toolkit-version does not accept backend arguments")
            print((root / "VERSION").read_text(encoding="ascii").strip())
            return 0
        require_linux()
        script = root / COMMANDS[args.command]
        if not script.is_file():
            raise ValueError("Toolkit command is missing; select a complete toolkit with --directory")
        if not shutil.which("bash"):
            raise ValueError("Bash is required; install it on the target Linux server")
        # Fixed Bash executable and argv-only handoff preserve I/O, signals and status without printing secrets.
        os.execvp("bash", ["bash", str(script), *arguments])  # nosec B606
        return 0
    except KeyboardInterrupt:
        print("Mooship operation cancelled", file=sys.stderr)
        return 130
    except (ValueError, OSError, URLError, tarfile.TarError, shutil.Error) as exc:
        print(f"Mooship: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
