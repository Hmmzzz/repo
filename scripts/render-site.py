#!/usr/bin/env python3

from __future__ import annotations

import html
import re
import subprocess
import sys
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime
from functools import cmp_to_key
from pathlib import Path
from urllib.parse import quote


UPDATE_MARKER = "<!-- GENERATED:UPDATE_ITEMS -->"
PACKAGE_MARKER = "<!-- GENERATED:PACKAGE_ITEMS -->"

ARCHITECTURES = {
    "iphoneos-arm64": ("Rootless", 0),
    "iphoneos-arm64e": ("RootHide", 1),
}


def fail(message: str) -> None:
    raise SystemExit(f"Site rendering failed: {message}")


def parse_stanzas(text: str) -> list[dict[str, str]]:
    stanzas: list[dict[str, str]] = []
    for raw_stanza in text.strip().split("\n\n") if text.strip() else []:
        fields: dict[str, str] = {}
        current_key: str | None = None
        for line in raw_stanza.splitlines():
            if line.startswith((" ", "\t")) and current_key:
                fields[current_key] += "\n" + line[1:]
                continue
            if ":" not in line:
                fail(f"malformed Packages line: {line}")
            current_key, value = line.split(":", 1)
            fields[current_key] = value.lstrip()
        stanzas.append(fields)
    return stanzas


def clean_multiline(value: str) -> str:
    lines = [line.strip() for line in value.splitlines()]
    return " ".join(line for line in lines if line and line != ".")


def format_size(raw_size: str) -> str:
    try:
        size = int(raw_size)
    except ValueError:
        return raw_size
    units = ("B", "KB", "MB", "GB")
    amount = float(size)
    unit = units[0]
    for candidate in units:
        unit = candidate
        if amount < 1000 or candidate == units[-1]:
            break
        amount /= 1000
    if unit == "B":
        return f"{int(amount)} {unit}"
    precision = 0 if amount >= 100 else 1
    return f"{amount:.{precision}f} {unit}"


def natural_version_key(version: str) -> list[tuple[int, int | str]]:
    key: list[tuple[int, int | str]] = []
    for part in re.split(r"(\d+)", version.lower()):
        if not part:
            continue
        key.append((1, int(part)) if part.isdigit() else (0, part))
    return key


def compare_versions(left: str, right: str) -> int:
    if left == right:
        return 0
    try:
        if subprocess.run(
            ["dpkg", "--compare-versions", left, "gt", right],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        ).returncode == 0:
            return 1
        if subprocess.run(
            ["dpkg", "--compare-versions", left, "lt", right],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        ).returncode == 0:
            return -1
    except FileNotFoundError:
        pass
    left_key = natural_version_key(left)
    right_key = natural_version_key(right)
    return (left_key > right_key) - (left_key < right_key)


def first_published_at(repo_root: Path, filename: str) -> str:
    try:
        result = subprocess.run(
            [
                "git",
                "-C",
                str(repo_root),
                "log",
                "--diff-filter=A",
                "--follow",
                "--format=%aI",
                "--reverse",
                "--",
                filename,
            ],
            check=False,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError:
        return ""
    if result.returncode != 0:
        return ""
    dates = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    return dates[0] if dates else ""


def display_date(iso_date: str) -> str:
    if not iso_date:
        return "发布日期待记录"
    try:
        parsed = datetime.fromisoformat(iso_date.replace("Z", "+00:00"))
    except ValueError:
        return iso_date[:10]
    return parsed.strftime("%Y.%m.%d")


def escaped(value: str) -> str:
    return html.escape(value, quote=True)


def file_url(filename: str) -> str:
    return "./" + quote(filename, safe="/+~._-")


@dataclass(frozen=True)
class PackageRecord:
    package: str
    name: str
    version: str
    architecture: str
    architecture_name: str
    architecture_order: int
    filename: str
    size: str
    sha256: str
    description: str
    changelog: str
    published_at: str


def records_from_stanzas(
    stanzas: list[dict[str, str]], repo_root: Path
) -> list[PackageRecord]:
    records: list[PackageRecord] = []
    required = {"Package", "Version", "Architecture", "Filename", "Size", "SHA256"}
    for stanza in stanzas:
        missing = required.difference(stanza)
        if missing:
            fail(f"package stanza is missing: {', '.join(sorted(missing))}")
        architecture = stanza["Architecture"]
        architecture_info = ARCHITECTURES.get(architecture)
        if architecture_info is None:
            fail(f"unsupported package architecture: {architecture}")
        filename = stanza["Filename"]
        description = clean_multiline(stanza.get("Description", ""))
        changelog = clean_multiline(
            stanza.get("X-Changelog", stanza.get("Changelog", ""))
        )
        records.append(
            PackageRecord(
                package=stanza["Package"],
                name=stanza.get("Name", stanza["Package"]),
                version=stanza["Version"],
                architecture=architecture,
                architecture_name=architecture_info[0],
                architecture_order=architecture_info[1],
                filename=filename,
                size=stanza["Size"],
                sha256=stanza["SHA256"],
                description=description,
                changelog=changelog,
                published_at=first_published_at(repo_root, filename),
            )
        )
    return records


def newest_record(records: list[PackageRecord]) -> PackageRecord:
    def compare(left: PackageRecord, right: PackageRecord) -> int:
        version_result = compare_versions(left.version, right.version)
        if version_result:
            return version_result
        return (left.published_at > right.published_at) - (
            left.published_at < right.published_at
        )

    return max(records, key=cmp_to_key(compare))


def download_link(record: PackageRecord, compact: bool = False) -> str:
    label = record.architecture_name if compact else f"下载 {record.architecture_name} .deb"
    filename = escaped(record.filename)
    return (
        f'<a class="download-button" href="{escaped(file_url(record.filename))}" '
        f'download="{escaped(Path(record.filename).name)}" data-package-file="{filename}" '
        f'aria-label="{escaped(label)}，{escaped(record.name)} {escaped(record.version)}">'
        f'<span>{escaped(label)}</span>'
        '<svg viewBox="0 0 20 20" aria-hidden="true">'
        '<path d="M10 3v9m0 0 3.5-3.5M10 12 6.5 8.5M4 15.5h12"/>'
        "</svg></a>"
    )


def render_empty(kind: str, title: str, body: str) -> str:
    return (
        f'<div class="empty-state" data-empty-state="{escaped(kind)}">'
        '<span class="empty-mark" aria-hidden="true">'
        '<svg viewBox="0 0 24 24"><path d="M7 3.5h7l3 3v14H7z"/>'
        '<path d="M14 3.5v3h3M9.5 11h5M9.5 14.5h5"/></svg></span>'
        f"<strong>{escaped(title)}</strong><span>{escaped(body)}</span></div>"
    )


def render_updates(records: list[PackageRecord]) -> str:
    if not records:
        return render_empty(
            "updates",
            "还没有更新记录",
            "发布第一个软件包后，版本历史会自动显示在这里。",
        )

    grouped: dict[tuple[str, str], list[PackageRecord]] = defaultdict(list)
    for record in records:
        grouped[(record.package, record.version)].append(record)

    entries = []
    for grouped_records in grouped.values():
        grouped_records.sort(key=lambda item: item.architecture_order)
        representative = grouped_records[0]
        published_at = max(item.published_at for item in grouped_records)
        entries.append((representative, grouped_records, published_at))

    def compare_entries(left: tuple, right: tuple) -> int:
        left_record, _, left_date = left
        right_record, _, right_date = right
        if left_date != right_date:
            return -1 if left_date > right_date else 1
        name_result = (left_record.name.lower() > right_record.name.lower()) - (
            left_record.name.lower() < right_record.name.lower()
        )
        if name_result:
            return name_result
        return -compare_versions(left_record.version, right_record.version)

    entries.sort(key=cmp_to_key(compare_entries))
    items: list[str] = []
    for representative, grouped_records, published_at in entries:
        architectures = " · ".join(item.architecture_name for item in grouped_records)
        note = representative.changelog or representative.description or "发布此版本。"
        items.append(
            '<article class="timeline-item" '
            f'data-package-id="{escaped(representative.package)}">'
            '<div class="timeline-rail" aria-hidden="true"><span></span></div>'
            '<div class="timeline-content">'
            '<div class="timeline-heading">'
            f'<div><h3>{escaped(representative.name)}</h3>'
            f'<p class="package-id">{escaped(representative.package)}</p></div>'
            f'<time datetime="{escaped(published_at)}">{escaped(display_date(published_at))}</time>'
            "</div>"
            '<div class="release-meta">'
            f'<span class="version-label">v{escaped(representative.version)}</span>'
            f"<span>{escaped(architectures)}</span></div>"
            f'<p class="release-note">{escaped(note)}</p>'
            "</div></article>"
        )
    return '<div class="timeline">' + "".join(items) + "</div>"


def render_history(records: list[PackageRecord], selected: set[str]) -> str:
    historical = [record for record in records if record.filename not in selected]
    if not historical:
        return ""

    def compare(left: PackageRecord, right: PackageRecord) -> int:
        version_result = compare_versions(left.version, right.version)
        if version_result:
            return -version_result
        return left.architecture_order - right.architecture_order

    historical.sort(key=cmp_to_key(compare))
    rows = []
    for record in historical:
        rows.append(
            '<div class="history-row">'
            '<div><strong>'
            f"v{escaped(record.version)}</strong><span>{escaped(record.architecture_name)}"
            f" · {escaped(format_size(record.size))}</span></div>"
            f"{download_link(record, compact=True)}</div>"
        )
    return (
        '<details class="version-history">'
        f"<summary>历史版本 <span>{len(historical)}</span></summary>"
        '<div class="history-list">' + "".join(rows) + "</div></details>"
    )


def render_packages(records: list[PackageRecord]) -> str:
    if not records:
        return render_empty(
            "packages",
            "暂无可下载插件",
            "软件包发布后，Rootless 和 RootHide 下载入口会自动出现。",
        )

    grouped: dict[str, list[PackageRecord]] = defaultdict(list)
    for record in records:
        grouped[record.package].append(record)

    packages = []
    for package_records in grouped.values():
        by_architecture: dict[str, list[PackageRecord]] = defaultdict(list)
        for record in package_records:
            by_architecture[record.architecture].append(record)
        latest = [newest_record(items) for items in by_architecture.values()]
        latest.sort(key=lambda item: item.architecture_order)
        representative = newest_record(package_records)
        packages.append((representative.name.lower(), representative, package_records, latest))
    packages.sort(key=lambda item: item[0])

    items: list[str] = []
    for _, representative, package_records, latest in packages:
        versions = {record.version for record in latest}
        if len(versions) == 1:
            version_summary = "v" + next(iter(versions))
        else:
            version_summary = " · ".join(
                f"{record.architecture_name} v{record.version}" for record in latest
            )
        description = representative.description or "暂无插件说明。"
        links = "".join(download_link(record) for record in latest)
        selected = {record.filename for record in latest}
        items.append(
            '<article class="package-row" '
            f'data-package-id="{escaped(representative.package)}">'
            '<div class="package-copy">'
            '<div class="package-heading"><div>'
            f'<h3>{escaped(representative.name)}</h3>'
            f'<p class="package-id">{escaped(representative.package)}</p>'
            f'</div><span class="latest-version">{escaped(version_summary)}</span></div>'
            f'<p class="package-description">{escaped(description)}</p>'
            f'<div class="download-actions">{links}</div>'
            f"{render_history(package_records, selected)}"
            "</div></article>"
        )
    return '<div class="package-list">' + "".join(items) + "</div>"


def main() -> None:
    if len(sys.argv) != 3:
        fail("usage: render-site.py <repository-root> <publish-directory>")

    repo_root = Path(sys.argv[1]).resolve()
    publish_dir = Path(sys.argv[2]).resolve()
    packages_path = publish_dir / "Packages"
    index_path = publish_dir / "index.html"
    if not packages_path.is_file() or not index_path.is_file():
        fail("Packages or index.html is missing")

    template = index_path.read_text(encoding="utf-8")
    if template.count(UPDATE_MARKER) != 1 or template.count(PACKAGE_MARKER) != 1:
        fail("index.html does not contain the expected generation markers")

    records = records_from_stanzas(
        parse_stanzas(packages_path.read_text(encoding="utf-8")), repo_root
    )
    rendered = template.replace(UPDATE_MARKER, render_updates(records))
    rendered = rendered.replace(PACKAGE_MARKER, render_packages(records))
    index_path.write_text(rendered, encoding="utf-8")
    print(f"Rendered repository homepage with {len(records)} package artifact(s).")


if __name__ == "__main__":
    main()
