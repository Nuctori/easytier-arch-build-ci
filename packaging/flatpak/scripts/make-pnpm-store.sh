#!/usr/bin/env bash
set -euo pipefail

version="${1:-2.4.5}"
# Resolve to absolute paths BEFORE any `cd` below: the script later enters the
# extracted source dir, and a relative out_path would land inside the temp
# workdir, which the EXIT trap then deletes (the old file appeared to be
# written, but vanished before the flatpak-builder step ran).
out_path="$(realpath -m "${2:-packaging/flatpak/pnpm-store.tar.gz}")"
store_dir_arg="${3:-}"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

pnpm_bin="$workdir/pnpm"
store_dir="$(realpath -m "${store_dir_arg:-$workdir/pnpm-store}")"

mkdir -p "$store_dir"

curl -L -o "$pnpm_bin" "https://github.com/pnpm/pnpm/releases/download/v9.15.4/pnpm-linuxstatic-x64"
chmod +x "$pnpm_bin"

curl -L -o "$workdir/easytier-src.tar.gz" "https://github.com/EasyTier/EasyTier/archive/refs/tags/v${version}.tar.gz"
tar -xf "$workdir/easytier-src.tar.gz" -C "$workdir"

src_root="$(find "$workdir" -maxdepth 1 -type d -name "EasyTier-*" | head -n 1)"
if [[ -z "${src_root}" ]]; then
	echo "Failed to locate extracted EasyTier sources" >&2
	exit 1
fi

cd "$src_root"

"$pnpm_bin" config set store-dir "$store_dir"
"$pnpm_bin" config set registry https://registry.npmjs.org/
"$pnpm_bin" config set fetch-retries 7
"$pnpm_bin" config set fetch-retry-mintimeout 20000
"$pnpm_bin" config set fetch-retry-maxtimeout 120000
"$pnpm_bin" config set network-concurrency 2

"$pnpm_bin" fetch --frozen-lockfile

mkdir -p "$(dirname "$out_path")"
tar -czf "$out_path" -C "$store_dir" .

# Sanity check: the tarball must survive outside the temp workdir.
if [[ ! -s "${out_path}" ]]; then
	echo "pnpm store tarball is missing/empty: ${out_path}" >&2
	exit 1
fi

echo "Wrote ${out_path} ($(du -h "${out_path}" | cut -f1))"
ls -lh "$(dirname "${out_path}")"
