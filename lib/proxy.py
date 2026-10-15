"""Edit Mooship-generated proxy Compose entries without reformatting other sites.

This handles the block lists/mappings and commented entries emitted by Mooship,
including explicit empty collections. It is not a general-purpose YAML parser.
"""

import argparse
from pathlib import Path
import re


KEY = re.compile(r"^( *)([A-Za-z0-9_.-]+|<<):(.*)$")
COLLECTIONS = {
    ("x-common-networks", "networks"): "[]",
    ("services", "nginxproxy", "volumes"): "[]",
    ("networks",): "{}",
    ("volumes",): "{}",
}


def indentation(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def uncomment(line: str) -> str:
    indent = indentation(line)
    body = line[indent:]
    if body.startswith("#"):
        body = body[1:]
        if body.startswith(" "):
            body = body[1:]
    return line[:indent] + body


def comment(line: str) -> str:
    if not line.strip():
        return line
    indent = indentation(line)
    return line[:indent] + "# " + line[indent:]


def block_end(lines: list, start: int, collection: bool = False) -> int:
    """Stop at the next sibling, including a disabled sibling's header."""
    indent = indentation(lines[start])
    end = start + 1
    while end < len(lines):
        boundary = lines[end].strip() and indentation(lines[end]) <= indent
        if boundary and not (collection and lines[end].lstrip().startswith("#")):
            break
        end += 1
    return end


def normalize_collections(lines: list) -> list:
    """Keep comment-only collections valid and reopen them on activation."""
    stack = []
    for index, line in enumerate(lines):
        match = KEY.match(line)
        if not match:
            continue
        indent, key, value = match.groups()
        depth = len(indent)
        stack = [(level, name) for level, name in stack if level < depth]
        stack.append((depth, key))
        empty = COLLECTIONS.get(tuple(name for _, name in stack))
        value, separator, note = value.partition("#")
        if empty is None or value.strip() not in ("", "[]", "{}"):
            continue
        children = lines[index + 1:block_end(lines, index, collection=True)]
        populated = any(child.strip() and not child.lstrip().startswith("#") for child in children)
        suffix = "" if populated else " " + empty
        if separator:
            suffix += " #" + note
        lines[index] = indent + key + ":" + suffix
    return lines


def transform(content: str, slug: str, action: str) -> str:
    """Activate, deactivate, or remove only the target site's proxy resources."""
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]*", slug) or slug.lower() == "nginxproxy":
        raise ValueError("Invalid or reserved slug")
    if action not in ("activate", "deactivate", "remove"):
        raise ValueError("Unknown proxy action")
    lines = content.splitlines()
    result = []
    stack = []
    index = 0
    while index < len(lines):
        line = lines[index]
        depth = indentation(line)
        plain = uncomment(line)
        body = plain.strip()
        parent = tuple(name for level, name in stack if level < depth)
        disabled = line.lstrip().startswith("#")
        key = KEY.match(plain)
        resource = slug if parent == ("networks",) else slug + "_ssl_certificates"
        declaration = parent in (("networks",), ("volumes",)) and key and key.group(2) == resource
        if declaration:
            end = block_end(lines, index)
            block = lines[index:end]
            if action == "activate" and disabled:
                result.extend(uncomment(child) for child in block)
            elif action == "deactivate" and not disabled:
                # Add one layer to existing comments too, preserving them on activation.
                result.extend(comment(child) for child in block)
            elif action != "remove":
                result.extend(block)
            index = end
            continue
        network = parent == ("x-common-networks", "networks") and re.fullmatch(
            r"-\s+" + re.escape(slug) + r"(?:\s+#.*)?", body)
        volume = parent == ("services", "nginxproxy", "volumes") and re.match(
            r"-\s+" + re.escape(slug + "_ssl_certificates") + r":", body)
        if network or volume:
            if action == "activate":
                result.append(plain)
            elif action == "deactivate":
                result.append(line if disabled else comment(line))
        else:
            result.append(line)
        if not disabled and key:
            stack = [(level, name) for level, name in stack if level < depth]
            stack.append((depth, key.group(2)))
        index += 1
    return "\n".join(normalize_collections(result)) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("activate", "deactivate", "remove"))
    parser.add_argument("compose_file", type=Path)
    parser.add_argument("slug")
    args = parser.parse_args()
    content = args.compose_file.read_text(encoding="utf-8")
    updated = transform(content, args.slug, args.action)
    if updated != content:
        args.compose_file.write_text(updated, encoding="utf-8")


if __name__ == "__main__":
    main()
