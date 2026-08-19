#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
  printf 'Usage: %s <repository-directory>\n' "$0" >&2
  exit 64
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$1

for expected_file in \
  Packages Packages.gz Packages.bz2 Packages.xz Packages.zst Release index.html .nojekyll \
  CydiaIcon.png CydiaIcon@2x.png CydiaIcon@3x.png \
  depictions/markfont/icon.png depictions/markfont/index.html \
  depictions/markfont/sileo.json \
  depictions/marktheme/icon.png depictions/marktheme/index.html \
  depictions/marktheme/sileo.json \
  depictions/marktheme/screenshots/home.png \
  depictions/marktheme/screenshots/theme-detail.png; do
  [[ -f "$repo_dir/$expected_file" ]] || {
    printf 'Smoke test failed: missing %s\n' "$expected_file" >&2
    exit 65
  }
done

python3 - "$repo_dir" <<'PY'
import struct
import sys
from pathlib import Path

repo_dir = Path(sys.argv[1])
expected_sizes = {
    "CydiaIcon.png": (64, 64),
    "CydiaIcon@2x.png": (128, 128),
    "CydiaIcon@3x.png": (192, 192),
    "depictions/marktheme/icon.png": (512, 512),
    "depictions/marktheme/screenshots/home.png": (1179, 2556),
    "depictions/marktheme/screenshots/theme-detail.png": (1179, 2556),
}

for filename, expected_size in expected_sizes.items():
    data = (repo_dir / filename).read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise SystemExit(f"Smoke test failed: {filename} is not a valid PNG.")
    actual_size = struct.unpack(">II", data[16:24])
    if actual_size != expected_size:
        raise SystemExit(
            f"Smoke test failed: {filename} must be {expected_size[0]}x{expected_size[1]}, "
            f"found {actual_size[0]}x{actual_size[1]}."
        )
    color_type = data[25]
    if filename.startswith("CydiaIcon") and color_type not in {4, 6} and b"tRNS" not in data:
        raise SystemExit(
            f"Smoke test failed: {filename} must retain transparency for its rounded corners."
        )
PY

python3 -m json.tool "$repo_dir/depictions/markfont/sileo.json" >/dev/null
grep -Fq 'MarkFont 0.3.7' "$repo_dir/depictions/markfont/sileo.json"
python3 - \
  "$repo_dir/depictions/markfont/sileo.json" \
  "$repo_dir/depictions/markfont/index.html" <<'PY'
import json
import sys
from pathlib import Path

depiction_text = Path(sys.argv[1]).read_text(encoding="utf-8")
web_depiction = Path(sys.argv[2]).read_text(encoding="utf-8")
depiction = json.loads(depiction_text)

mount_warning = "如果安装过其他字体挂载插件并已挂载字体，请先取消挂载，再卸载对应插件。"
for name, content in (("Sileo", depiction_text), ("web", web_depiction)):
    if mount_warning not in content:
        raise SystemExit(f"Smoke test failed: {name} depiction is missing the mount warning.")
    if "选择正确的软件包" in content:
        raise SystemExit(f"Smoke test failed: {name} depiction still includes package selection help.")
    for required_release_note in ("专版", "改逗号", "SHA-256"):
        if required_release_note not in content:
            raise SystemExit(
                f"Smoke test failed: {name} depiction is missing {required_release_note}."
            )

details = depiction["tabs"][0]
first_view = details["views"][0]
if first_view.get("class") != "DepictionSubheaderView" or first_view.get("title") != "全局字体管理":
    raise SystemExit("Smoke test failed: Sileo details must start with the feature summary.")

warning_index = next(
    (
        index
        for index, view in enumerate(details["views"])
        if view.get("class") == "DepictionSubheaderView"
        and view.get("title") == "安装前请注意"
    ),
    None,
)
if warning_index is None or warning_index + 1 >= len(details["views"]):
    raise SystemExit("Smoke test failed: Sileo install warning is missing.")
warning_markdown = details["views"][warning_index + 1].get("markdown", "")
for number in range(1, 4):
    if f"\n\n**{number}.** " not in warning_markdown:
        raise SystemExit("Smoke test failed: Sileo install notes must use separate Markdown paragraphs.")
if "<br" in warning_markdown or "</br>" in warning_markdown:
    raise SystemExit("Smoke test failed: Sileo install notes must not contain HTML breaks.")

duplicate_header_classes = {"DepictionImageView", "DepictionHeaderView"}
if any(view.get("class") in duplicate_header_classes for view in details["views"]):
    raise SystemExit("Smoke test failed: Sileo details duplicate the native package header.")
PY
if grep -Fq 'github.com/Hmmzzz/MarkFont' \
    "$repo_dir/depictions/markfont/sileo.json" \
    "$repo_dir/depictions/markfont/index.html"; then
  printf 'Smoke test failed: unreleased MarkFont source link is public.\n' >&2
  exit 65
fi

python3 -m json.tool "$repo_dir/depictions/marktheme/sileo.json" >/dev/null
python3 - \
  "$repo_dir/depictions/marktheme/sileo.json" \
  "$repo_dir/depictions/marktheme/index.html" \
  "$repo_dir/Packages" <<'PY'
import json
import sys
from pathlib import Path

sileo_path, web_path, packages_path = map(Path, sys.argv[1:])
depiction_text = sileo_path.read_text(encoding="utf-8")
web_text = web_path.read_text(encoding="utf-8")
depiction = json.loads(depiction_text)

details = depiction["tabs"][0]
views = details["views"]
first_view = views[0]
if first_view.get("class") != "DepictionSubheaderView" or first_view.get("title") != "模块化主题管理":
    raise SystemExit("Smoke test failed: MarkTheme details must start with the feature summary.")
if any(view.get("class") in {"DepictionImageView", "DepictionHeaderView"} for view in views):
    raise SystemExit("Smoke test failed: MarkTheme Sileo details duplicate the native package header.")

screenshots = [view for view in views if view.get("class") == "DepictionScreenshotsView"]
if len(screenshots) != 1:
    raise SystemExit("Smoke test failed: MarkTheme Sileo depiction must have one screenshot gallery.")
gallery = screenshots[0]
if gallery.get("itemSize") != "{160, 347}" or gallery.get("itemCornerRadius") != 22:
    raise SystemExit("Smoke test failed: MarkTheme screenshot gallery has unexpected sizing.")
expected_screenshots = [
    "https://hmmzzz.github.io/repo/depictions/marktheme/screenshots/home.png",
    "https://hmmzzz.github.io/repo/depictions/marktheme/screenshots/theme-detail.png",
]
if [item.get("url") for item in gallery.get("screenshots", [])] != expected_screenshots:
    raise SystemExit("Smoke test failed: MarkTheme screenshot URLs are incomplete or out of order.")

for name, content in (("Sileo", depiction_text), ("web", web_text)):
    for phrase in (
        "系统原生外观",
        "状态栏",
        "Generation",
        "Respring",
        "https://github.com/Hmmzzz/MarkTheme",
    ):
        if phrase not in content:
            raise SystemExit(f"Smoke test failed: MarkTheme {name} depiction is missing {phrase}.")
for relative_screenshot in ("screenshots/home.png", "screenshots/theme-detail.png"):
    if relative_screenshot not in web_text:
        raise SystemExit(f"Smoke test failed: MarkTheme web depiction is missing {relative_screenshot}.")
if "MarkTheme 0.1.2" not in depiction_text or "MarkTheme 0.1.2" not in web_text:
    raise SystemExit("Smoke test failed: MarkTheme release version is missing from a depiction.")
for name, content in (("Sileo", depiction_text), ("web", web_text)):
    for phrase in ("诊断", "ABI 探测", "屏幕 scale"):
        if phrase not in content:
            raise SystemExit(f"Smoke test failed: MarkTheme {name} depiction is missing {phrase}.")
    for stale_phrase in (
        "系统 build 精确启用",
        "Runtime 严格匹配系统 build",
        "iOS 17.1 / 17.1.1",
        "不再按系统 build",
    ):
        if stale_phrase in content:
            raise SystemExit(f"Smoke test failed: MarkTheme {name} depiction retains {stale_phrase}.")

def parse_stanzas(text):
    stanzas = []
    for raw in text.strip().split("\n\n"):
        fields = {}
        current = None
        for line in raw.splitlines():
            if line.startswith((" ", "\t")) and current:
                fields[current] += "\n" + line
            else:
                current, value = line.split(":", 1)
                fields[current] = value.lstrip()
        stanzas.append(fields)
    return stanzas

marktheme = [
    stanza
    for stanza in parse_stanzas(packages_path.read_text(encoding="utf-8"))
    if stanza.get("Package") == "com.hmmzzz.marktheme"
]
expected_variants = {
    (version, architecture)
    for version in ("0.1.0", "0.1.1", "0.1.2")
    for architecture in ("iphoneos-arm64", "iphoneos-arm64e")
}
actual_variants = {
    (stanza.get("Version"), stanza.get("Architecture"))
    for stanza in marktheme
}
if len(marktheme) != len(expected_variants) or actual_variants != expected_variants:
    raise SystemExit("Smoke test failed: MarkTheme version/architecture variants are incomplete.")

expected_fields = {
    "Homepage": "https://github.com/Hmmzzz/MarkTheme",
    "Icon": "https://hmmzzz.github.io/repo/depictions/marktheme/icon.png",
    "Depiction": "https://hmmzzz.github.io/repo/depictions/marktheme/",
    "SileoDepiction": "https://hmmzzz.github.io/repo/depictions/marktheme/sileo.json",
}
for stanza in marktheme:
    for field, expected in expected_fields.items():
        if stanza.get(field) != expected:
            raise SystemExit(f"Smoke test failed: MarkTheme {field} does not match {expected}.")
    depends = stanza.get("Depends", "")
    for dependency in ("firmware (>= 17.0)", "uikittools", "ellekit (>= 1.2)"):
        if dependency not in depends:
            raise SystemExit(f"Smoke test failed: MarkTheme dependency is missing: {dependency}.")
PY

cmp "$repo_dir/Packages" <(gzip -dc "$repo_dir/Packages.gz")
cmp "$repo_dir/Packages" <(bzip2 -dc "$repo_dir/Packages.bz2")
cmp "$repo_dir/Packages" <(xz -dc "$repo_dir/Packages.xz")
cmp "$repo_dir/Packages" <(zstd -q -dc "$repo_dir/Packages.zst")

python3 "$script_dir/verify-index.py" "$repo_dir"
printf 'Repository smoke test passed.\n'
