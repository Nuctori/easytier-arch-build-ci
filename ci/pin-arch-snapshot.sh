#!/usr/bin/env bash
# Pin pacman to an Arch Linux Archive snapshot (YYYY/MM/DD).
#
# Used by CI workflows that must build against the same glibc as SteamOS 3.7
# (glibc 2.41), e.g. snapshot 2025/07/01.
#
# Usage: pin-arch-snapshot.sh <snapshot>
set -euo pipefail

snapshot="${1:?usage: pin-arch-snapshot.sh <YYYY/MM/DD>}"

cat > /etc/pacman.d/mirrorlist <<EOF
Server = https://archive.archlinux.org/repos/${snapshot}/\$repo/os/\$arch
EOF

# Sync the snapshot databases first.
pacman -Syy --noconfirm

# The rolling archlinux container ships a fresh archlinux-keyring that has
# DISABLED old packager keys, so snapshot-era packages fail signature checks
# ("error: base: key ... is disabled"). Install the snapshot-era keyring
# before downgrading; it is itself signed by master keys, which the fresh
# keyring still trusts.
keyring_pkg="$(
  curl -fsSL "https://archive.archlinux.org/repos/${snapshot}/core/os/x86_64/" \
    | grep -oE 'archlinux-keyring-[^"]+\.pkg\.tar\.(zst|xz)' \
    | sort -u \
    | head -n1
)"
if [[ -z "${keyring_pkg}" ]]; then
  echo "could not find archlinux-keyring in snapshot ${snapshot}" >&2
  exit 1
fi
pacman -U --noconfirm \
  "https://archive.archlinux.org/repos/${snapshot}/core/os/x86_64/${keyring_pkg}"

# Downgrade the whole system to the snapshot.
# - libmakepkg-dropins: a newer split/dropin package from the rolling image can
#   conflict during downgrade; the snapshot era does not need it.
# - --overwrite python.sh: its ownership changed across snapshots.
pacman -Rdd --noconfirm libmakepkg-dropins || true
pacman -Syyuu --noconfirm --overwrite /usr/share/makepkg/reproducible/python.sh
