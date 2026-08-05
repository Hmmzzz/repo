#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import html
import sys
from pathlib import Path
from urllib.parse import quote


ALLOWED_ARCHITECTURES = {
    "iphoneos-arm64": "pool/rootless/",
    "iphoneos-arm64e": "pool/roothide/",
}


def fail(message: str) -> None:
    raise SystemExit(f"Index verification failed: {message}")


def parse_stanzas(text: str) -> list[dict[str, str]]:
    stanzas: list[dict[str, str]] = []
    for raw_stanza in text.strip().split("\n\n") if text.strip() else []:
        fields: dict[str, str] = {}
        current_key: str | None = None
        for line in raw_stanza.splitlines():
            if line.startswith((" ", "\t")) and current_key:
                fields[current_key] += "\n" + line
                continue
            if ":" not in line:
                fail(f"malformed Packages line: {line}")
            current_key, value = line.split(":", 1)
            fields[current_key] = value.lstrip()
        stanzas.append(fields)
    return stanzas


def release_sha256_entries(text: str) -> dict[str, tuple[str, int]]:
    entries: dict[str, tuple[str, int]] = {}
    in_sha256 = False
    for line in text.splitlines():
        if line == "SHA256:":
            in_sha256 = True
            continue
        if in_sha256 and not line.startswith(" "):
            break
        if in_sha256:
            parts = line.split()
            if len(parts) != 3:
                fail(f"malformed Release SHA256 entry: {line}")
            digest, size, filename = parts
            entries[filename] = (digest, int(size))
    return entries


def verify_file(root: Path, relative_name: str, digest: str, size: int) -> None:
    root_resolved = root.resolve()
    target = (root / relative_name).resolve()
    try:
        target.relative_to(root_resolved)
    except ValueError:
        fail(f"path escapes repository root: {relative_name}")
    if not target.is_file():
        fail(f"indexed file is missing: {relative_name}")
    data = target.read_bytes()
    if len(data) != size:
        fail(f"size mismatch for {relative_name}: expected {size}, found {len(data)}")
    actual_digest = hashlib.sha256(data).hexdigest()
    if actual_digest != digest:
        fail(f"SHA256 mismatch for {relative_name}")


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: verify-index.py <repository-directory>")

    root = Path(sys.argv[1])
    packages_path = root / "Packages"
    release_path = root / "Release"
    index_path = root / "index.html"
    if not packages_path.is_file() or not release_path.is_file() or not index_path.is_file():
        fail("Packages, Release, or index.html is missing")

    release_text = release_path.read_text(encoding="utf-8")
    architecture_line = "Architectures: iphoneos-arm64 iphoneos-arm64e"
    if architecture_line not in release_text.splitlines():
        fail("Release architectures are missing or out of order")

    expected_indexes = {
        "Packages",
        "Packages.gz",
        "Packages.bz2",
        "Packages.xz",
        "Packages.zst",
    }
    release_entries = release_sha256_entries(release_text)
    missing_indexes = expected_indexes.difference(release_entries)
    if missing_indexes:
        fail(f"Release SHA256 section is missing: {', '.join(sorted(missing_indexes))}")
    for filename in sorted(expected_indexes):
        digest, size = release_entries[filename]
        verify_file(root, filename, digest, size)

    seen: set[tuple[str, str, str]] = set()
    stanzas = parse_stanzas(packages_path.read_text(encoding="utf-8"))
    index_html = index_path.read_text(encoding="utf-8")
    for marker in ("<!-- GENERATED:UPDATE_ITEMS -->", "<!-- GENERATED:PACKAGE_ITEMS -->"):
        if marker in index_html:
            fail(f"homepage still contains generation marker: {marker}")
    for required_fragment in (
        'data-dialog-target="updates-dialog"',
        'data-dialog-target="packages-dialog"',
        'id="updates-dialog"',
        'id="packages-dialog"',
    ):
        if required_fragment not in index_html:
            fail(f"homepage is missing interaction hook: {required_fragment}")

    required_fields = {"Package", "Version", "Architecture", "Filename", "Size", "SHA256"}
    for stanza in stanzas:
        missing = required_fields.difference(stanza)
        if missing:
            fail(f"package stanza is missing: {', '.join(sorted(missing))}")

        architecture = stanza["Architecture"]
        expected_prefix = ALLOWED_ARCHITECTURES.get(architecture)
        if expected_prefix is None:
            fail(f"unsupported package architecture: {architecture}")
        filename = stanza["Filename"]
        if not filename.startswith(expected_prefix):
            fail(f"{architecture} package has wrong Filename: {filename}")

        key = (stanza["Package"], stanza["Version"], architecture)
        if key in seen:
            fail(f"duplicate package tuple: {' | '.join(key)}")
        seen.add(key)
        verify_file(root, filename, stanza["SHA256"], int(stanza["Size"]))

        escaped_filename = html.escape(filename, quote=True)
        if f'data-package-file="{escaped_filename}"' not in index_html:
            fail(f"homepage is missing package download: {filename}")
        encoded_url = "./" + quote(filename, safe="/+~._-")
        if f'href="{html.escape(encoded_url, quote=True)}"' not in index_html:
            fail(f"homepage has no valid download URL for: {filename}")

    if stanzas:
        if 'data-empty-state="packages"' in index_html:
            fail("homepage still shows the empty package state")
    elif not all(
        marker in index_html
        for marker in ('data-empty-state="updates"', 'data-empty-state="packages"')
    ):
        fail("homepage empty states are missing")

    print(f"Verified repository indexes, homepage, and {len(stanzas)} package stanza(s).")


if __name__ == "__main__":
    main()
