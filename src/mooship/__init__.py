"""Mooship's dependency-free installation and execution adapter."""

from pathlib import Path

_release_file = Path(__file__).with_name("_release.txt")
if not _release_file.is_file():
    _release_file = Path(__file__).resolve().parents[2] / "VERSION"
__version__ = _release_file.read_text(encoding="ascii").strip()
