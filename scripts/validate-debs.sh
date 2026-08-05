#!/usr/bin/env bash

set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
pool_dir=${1:-"$repo_root/pool"}

fail() {
  printf 'Package validation failed: %s\n' "$*" >&2
  exit 65
}

command -v dpkg-deb >/dev/null 2>&1 || fail 'dpkg-deb is required'
command -v tar >/dev/null 2>&1 || fail 'tar is required'

if command -v sha256sum >/dev/null 2>&1; then
  sha256_command=(sha256sum)
elif command -v shasum >/dev/null 2>&1; then
  sha256_command=(shasum -a 256)
else
  fail 'sha256sum or shasum is required'
fi

[[ -d "$pool_dir/rootless" ]] || fail 'pool/rootless is missing'
[[ -d "$pool_dir/roothide" ]] || fail 'pool/roothide is missing'

package_count=0
seen_keys=()

while IFS= read -r deb_path; do
  [[ -n "$deb_path" ]] || continue
  [[ -f "$deb_path" && ! -L "$deb_path" ]] || fail "not a regular .deb: $deb_path"

  case "$deb_path" in
    "$pool_dir"/rootless/*.deb)
      package_scheme=rootless
      expected_architecture=iphoneos-arm64
      ;;
    "$pool_dir"/roothide/*.deb)
      package_scheme=roothide
      expected_architecture=iphoneos-arm64e
      ;;
    *)
      fail ".deb must be directly inside pool/rootless or pool/roothide: $deb_path"
      ;;
  esac

  dpkg-deb --info "$deb_path" >/dev/null

  package=$(dpkg-deb -f "$deb_path" Package | tr -d '\r')
  version=$(dpkg-deb -f "$deb_path" Version | tr -d '\r')
  architecture=$(dpkg-deb -f "$deb_path" Architecture | tr -d '\r')

  [[ "$package" =~ ^[a-z0-9][a-z0-9+.-]+$ ]] || fail "invalid Package in $deb_path: $package"
  [[ -n "$version" && "$version" != *[[:space:]/]* ]] || fail "invalid Version in $deb_path: $version"
  [[ "$architecture" == "$expected_architecture" ]] || \
    fail "$package_scheme directory requires $expected_architecture, found $architecture in $deb_path"

  expected_filename="${package}_${version}_${architecture}.deb"
  [[ $(basename -- "$deb_path") == "$expected_filename" ]] || \
    fail "expected filename $expected_filename, found $(basename -- "$deb_path")"

  package_key="${package}|${version}|${architecture}"
  for seen_key in "${seen_keys[@]-}"; do
    [[ "$seen_key" != "$package_key" ]] || fail "duplicate package tuple: $package_key"
  done
  seen_keys+=("$package_key")

  payload_seen=0
  rootless_payload_seen=0
  while IFS= read -r archive_path; do
    normalized_path=${archive_path#./}
    normalized_path=${normalized_path%/}
    case "$normalized_path" in
      ''|'.')
        continue
        ;;
      /*|..|../*|*/../*|*/..)
        fail "unsafe archive path in $deb_path: $archive_path"
        ;;
    esac

    payload_seen=1
    if [[ "$package_scheme" == rootless ]]; then
      case "$normalized_path" in
        var|var/jb|var/jb/*)
          [[ "$normalized_path" == var/jb || "$normalized_path" == var/jb/* ]] && rootless_payload_seen=1
          ;;
        *)
          fail "rootless package data escaped /var/jb in $deb_path: $archive_path"
          ;;
      esac
    else
      case "$normalized_path" in
        var/jb|var/jb/*)
          fail "RootHide package contains conventional rootless layout in $deb_path: $archive_path"
          ;;
      esac
    fi
  done < <(dpkg-deb --fsys-tarfile "$deb_path" | tar -tf -)

  [[ "$payload_seen" -eq 1 ]] || fail "package contains no data: $deb_path"
  if [[ "$package_scheme" == rootless ]]; then
    [[ "$rootless_payload_seen" -eq 1 ]] || fail "rootless package has no /var/jb payload: $deb_path"
  fi

  package_hash=$("${sha256_command[@]}" "$deb_path" | awk '{ print $1 }')
  printf 'Verified %s %s (%s, sha256 %s)\n' "$package" "$version" "$architecture" "$package_hash"
  package_count=$((package_count + 1))
done < <(find "$pool_dir" -type f -name '*.deb' -print | LC_ALL=C sort)

printf 'Validated %d package file(s).\n' "$package_count"
