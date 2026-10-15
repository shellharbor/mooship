"""Validate repository-local Markdown links and the synthetic endpoint JSON example."""

import json
from pathlib import Path
import re
import subprocess
import sys
from typing import List, Optional, Set
from urllib.parse import unquote, urlsplit


def prose_lines(text: str) -> List[str]:
    """Exclude fenced examples from link and heading discovery."""
    lines = []
    fence = None
    for line in text.splitlines():
        marker = re.match(r"^\s*(`{3,}|~{3,})", line)
        if marker:
            if fence is None:
                fence = marker.group(1)
            elif marker.group(1)[0] == fence[0] and len(marker.group(1)) >= len(fence):
                fence = None
            continue
        if fence is None:
            lines.append(line)
    return lines


def heading_anchors(text: str) -> Set[str]:
    anchors = set()
    counts = {}
    for line in prose_lines(text):
        heading = re.match(r"^#{1,6}\s+(.+?)\s*#*\s*$", line)
        if heading:
            parts = re.split(r"(`+[^`]*`+)", heading.group(1))
            title = "".join(part.strip("`") if part.startswith("`") else re.sub(r"<[^>]+>", "", part)
                            for part in parts).lower()
            slug = "".join(char for char in title if char.isalnum() or char in " _-").replace(" ", "-")
            count = counts.get(slug, 0)
            anchors.add(slug if count == 0 else slug + "-" + str(count))
            counts[slug] = count + 1
        anchors.update(re.findall(r'<a\s+(?:name|id)=[\"\']([^\"\']+)', line))
    return anchors


def list_repository_files(root: Path) -> Set[Path]:
    """Include tracked files and pending public files, but not ignored local tooling."""
    root = root.resolve()
    listing = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=str(root), check=True, capture_output=True,
    ).stdout.decode("utf-8").split("\0")
    return {root / name for name in listing if name}


def check_document(path: Path, root: Path, repository_files: Optional[Set[Path]] = None) -> List[str]:
    errors = []
    for line in prose_lines(path.read_text(encoding="utf-8")):
        line = re.sub(r"`+[^`]*`+", "", line)
        for raw in re.findall(r"\[[^\]]*\]\(([^)]+)\)", line):
            raw = raw.strip()
            if not raw:
                errors.append(f"{path.name}: empty link target")
                continue
            destination = raw[1:raw.index(">")] if raw.startswith("<") and ">" in raw else raw.split()[0]
            link = urlsplit(destination)
            if link.scheme or link.netloc:
                continue
            local = unquote(link.path)
            target = (root / local.lstrip("/")) if local.startswith("/") else (path.parent / local)
            target = target.resolve() if local else path.resolve()
            try:
                target.relative_to(root.resolve())
            except ValueError:
                errors.append(f"{path.name}: link leaves the repository: {destination}")
                continue
            if not target.exists():
                errors.append(f"{path.name}: missing link target: {destination}")
            elif repository_files is not None and not (
                target in repository_files or
                (target.is_dir() and any(target in candidate.parents for candidate in repository_files))
            ):
                errors.append(f"{path.name}: link target is not included in the repository: {destination}")
            elif link.fragment and target.suffix.lower() == ".md":
                if unquote(link.fragment) not in heading_anchors(target.read_text(encoding="utf-8")):
                    errors.append(f"{path.name}: missing heading anchor: {destination}")
    return errors


def main() -> int:
    root = Path(__file__).resolve().parents[2]
    repository_files = list_repository_files(root)
    documents = sorted(path for path in repository_files if path.suffix == ".md")
    errors = [error for path in documents for error in check_document(path, root, repository_files)]
    try:
        payload = json.loads((root / "examples/endpoint-payload.json").read_text(encoding="utf-8"))
        if not isinstance(payload, dict):
            errors.append("The endpoint payload example must be a JSON object")
    except (ValueError, OSError) as error:
        errors.append(f"Invalid endpoint payload example: {error}")
    for error in errors:
        print(error, file=sys.stderr)
    print(f"Checked {len(documents)} Markdown files and the endpoint JSON example")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
