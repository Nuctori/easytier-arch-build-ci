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

# The container's LOCAL trustdb (/etc/pacman.d/gnupg) was populated when the
# image was built, from the FRESH keyring — it marks snapshot-era packager
# keys as disabled and the auto-populate hook on `pacman -U` only merges, it
# does not clear that state. Rebuild the trustdb from the snapshot-era keyring
# files (fully offline) so those keys verify again.
rm -rf /etc/pacman.d/gnupg
pacman-key --init
pacman-key --populate archlinux

# Downgrade the whole system to the snapshot.
# - --overwrite '*': the rolling image splits libs into separate packages
#   (libgomp/libstdc++/libtsan/... ) that the snapshot-era gcc-libs owns
#   directly; without overwriting, the downgrade aborts on file conflicts.
#   Safe here: this is a throwaway CI container.
# - libmakepkg-dropins: newer split/dropin package, not needed for the snapshot.
pacman -Rdd --noconfirm libmakepkg-dropins || true
pacman -Syyuu --noconfirm --overwrite '*'
