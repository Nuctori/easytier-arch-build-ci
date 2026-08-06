#!/usr/bin/env bash
# Pre-vendor the Rust (cargo) dependencies of EasyTier into a tarball so the
# flatpak-builder build can run fully OFFLINE (its sandbox has no network by
# default — and neither does Flathub). Mirrors make-pnpm-store.sh.
#
# Usage:
#   make-cargo-vendor.sh <version> [out_path] [cache_dir]
#
# cache_dir (optional): a directory for rustup/cargo home so CI can cache the
# toolchain + registry across runs.
set -euo pipefail

version="${1:?usage: make-cargo-vendor.sh <version> [out_path] [cache_dir]}" 
out_path="$(realpath -m "${2:-packaging/flatpak/cargo-vendor.tar.gz}")"
cache_dir="${3:-}"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

curl -L -o "$workdir/easytier-src.tar.gz" \
  "https://github.com/EasyTier/EasyTier/archive/refs/tags/v${version}.tar.gz"
tar -xf "$workdir/easytier-src.tar.gz" -C "$workdir"

src_root="$(find "$workdir" -maxdepth 1 -type d -name "EasyTier-*" | head -n 1)"
if [[ -z "${src_root}" ]]; then
  echo "Failed to locate extracted EasyTier sources" >&2
  exit 1
fi
cd "$src_root"

if [[ -n "${cache_dir}" ]]; then
  RUSTUP_HOME="$(realpath -m "${cache_dir}/rustup")"
  CARGO_HOME="$(realpath -m "${cache_dir}/cargo")"
else
  RUSTUP_HOME="$workdir/.rustup"
  CARGO_HOME="$workdir/.cargo"
fi
export RUSTUP_HOME CARGO_HOME
mkdir -p "$RUSTUP_HOME" "$CARGO_HOME"
export PATH="$CARGO_HOME/bin:$PATH"

if ! command -v cargo >/dev/null; then
  curl -fsSL https://sh.rustup.rs -o "$workdir/rustup-init.sh"
  sh "$workdir/rustup-init.sh" -y --profile minimal --default-toolchain 1.89.0 --no-modify-path
  export PATH="$CARGO_HOME/bin:$PATH"
fi
cargo -V

# Vendors every dependency in Cargo.lock (registry + git, incl. the
# EasyTier/http_req fork) into ./vendor; modern cargo also writes
# vendor/config.toml with the source-replacement rules.
cargo vendor vendor --locked

# Make the replacement config apply to the workspace build: the project-level
# .cargo/config.toml is picked up by `cargo build` in any member dir.
mkdir -p .cargo
cp vendor/config.toml .cargo/config.toml

mkdir -p "$(dirname "$out_path")"
tar -czf "$out_path" vendor .cargo

if [[ ! -s "${out_path}" ]]; then
  echo "cargo vendor tarball is missing/empty: ${out_path}" >&2
  exit 1
fi

echo "Wrote ${out_path} ($(du -h "${out_path}" | cut -f1))"
ls -lh "$(dirname "${out_path}")"
