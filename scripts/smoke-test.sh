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
  depictions/markfont/icon.png depictions/markfont/index.html \
  depictions/markfont/sileo.json; do
  [[ -f "$repo_dir/$expected_file" ]] || {
    printf 'Smoke test failed: missing %s\n' "$expected_file" >&2
    exit 65
  }
done

python3 -m json.tool "$repo_dir/depictions/markfont/sileo.json" >/dev/null
grep -Fq 'MarkFont 0.3.0' "$repo_dir/depictions/markfont/sileo.json"
python3 - "$repo_dir/depictions/markfont/sileo.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as depiction_file:
    depiction = json.load(depiction_file)

details = depiction["tabs"][0]
first_view = details["views"][0]
if first_view.get("class") != "DepictionSubheaderView" or first_view.get("title") != "全局字体管理":
    raise SystemExit("Smoke test failed: Sileo details must start with the feature summary.")

duplicate_header_classes = {"DepictionImageView", "DepictionHeaderView"}
if any(view.get("class") in duplicate_header_classes for view in details["views"]):
    raise SystemExit("Smoke test failed: Sileo details duplicate the native package header.")
PY
if grep -Fq 'github.com/Hmmzzz/MarkFont' \
    "$repo_dir/depictions/markfont/sileo.json"; then
  printf 'Smoke test failed: unreleased MarkFont source link is public.\n' >&2
  exit 65
fi

cmp "$repo_dir/Packages" <(gzip -dc "$repo_dir/Packages.gz")
cmp "$repo_dir/Packages" <(bzip2 -dc "$repo_dir/Packages.bz2")
cmp "$repo_dir/Packages" <(xz -dc "$repo_dir/Packages.xz")
cmp "$repo_dir/Packages" <(zstd -q -dc "$repo_dir/Packages.zst")

python3 "$script_dir/verify-index.py" "$repo_dir"
printf 'Repository smoke test passed.\n'
