#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
  printf 'Usage: %s <empty-output-directory>\n' "$0" >&2
  exit 64
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
output_dir=$1

for required_tool in apt-ftparchive gzip bzip2 xz zstd; do
  command -v "$required_tool" >/dev/null 2>&1 || {
    printf 'Required command is missing: %s\n' "$required_tool" >&2
    exit 69
  }
done

mkdir -p "$output_dir"
if [[ -n $(find "$output_dir" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
  printf 'Output directory must be empty: %s\n' "$output_dir" >&2
  exit 73
fi

"$script_dir/validate-debs.sh" "$repo_root/pool"

cp -R "$repo_root/site/." "$output_dir/"
mkdir -p "$output_dir/pool"
cp -R "$repo_root/pool/." "$output_dir/pool/"

(
  cd "$output_dir"
  apt-ftparchive packages pool > Packages
  gzip -9 -n -c Packages > Packages.gz
  bzip2 -9 -c Packages > Packages.bz2
  xz -9 -c Packages > Packages.xz
  zstd -q -19 -c Packages > Packages.zst
)

release_temp=$(mktemp "${TMPDIR:-/tmp}/hmmzzz-release.XXXXXX")
cleanup() {
  if [[ "$release_temp" == "${TMPDIR:-/tmp}/hmmzzz-release."* && -f "$release_temp" ]]; then
    rm -f -- "$release_temp"
  fi
}
trap cleanup EXIT INT TERM

(
  cd "$output_dir"
  apt-ftparchive \
    -o APT::FTPArchive::Release::Origin="Hmmzzz" \
    -o APT::FTPArchive::Release::Label="Hmmzzz Repo" \
    -o APT::FTPArchive::Release::Suite="stable" \
    -o APT::FTPArchive::Release::Version="1.0" \
    -o APT::FTPArchive::Release::Codename="ios" \
    -o APT::FTPArchive::Release::Architectures="iphoneos-arm64 iphoneos-arm64e" \
    -o APT::FTPArchive::Release::Components="main" \
    -o APT::FTPArchive::Release::Description="Rootless and RootHide packages by Hmmzzz" \
    release .
) > "$release_temp"

mv "$release_temp" "$output_dir/Release"
trap - EXIT INT TERM

python3 "$script_dir/render-site.py" "$repo_root" "$output_dir"

printf 'Built APT repository: %s\n' "$output_dir"
