#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../packaging/arch"

if [[ -f PKGBUILD ]]; then
  echo "Building Arch package in $(pwd)"
else
  echo "PKGBUILD not found" >&2
  exit 1
fi

makepkg -s
