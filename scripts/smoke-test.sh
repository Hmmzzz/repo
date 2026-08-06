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
  depictions/markfont/sileo.json; do
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
    if color_type not in {4, 6} and b"tRNS" not in data:
        raise SystemExit(
            f"Smoke test failed: {filename} must retain transparency for its rounded corners."
        )
PY

python3 -m json.tool "$repo_dir/depictions/markfont/sileo.json" >/dev/null
grep -Fq 'MarkFont 0.3.0' "$repo_dir/depictions/markfont/sileo.json"
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

cmp "$repo_dir/Packages" <(gzip -dc "$repo_dir/Packages.gz")
cmp "$repo_dir/Packages" <(bzip2 -dc "$repo_dir/Packages.bz2")
cmp "$repo_dir/Packages" <(xz -dc "$repo_dir/Packages.xz")
cmp "$repo_dir/Packages" <(zstd -q -dc "$repo_dir/Packages.zst")

python3 "$script_dir/verify-index.py" "$repo_dir"
printf 'Repository smoke test passed.\n'
