#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
  printf 'Usage: %s <repository-directory>\n' "$0" >&2
  exit 64
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$1

for expected_file in Packages Packages.gz Packages.bz2 Packages.xz Packages.zst Release index.html .nojekyll; do
  [[ -f "$repo_dir/$expected_file" ]] || {
    printf 'Smoke test failed: missing %s\n' "$expected_file" >&2
    exit 65
  }
done

cmp "$repo_dir/Packages" <(gzip -dc "$repo_dir/Packages.gz")
cmp "$repo_dir/Packages" <(bzip2 -dc "$repo_dir/Packages.bz2")
cmp "$repo_dir/Packages" <(xz -dc "$repo_dir/Packages.xz")
cmp "$repo_dir/Packages" <(zstd -q -dc "$repo_dir/Packages.zst")

python3 "$script_dir/verify-index.py" "$repo_dir"
printf 'Repository smoke test passed.\n'
