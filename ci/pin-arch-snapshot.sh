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

# Why SigLevel = Never: snapshot-era packages are signed by packager keys that
# were added to archlinux-keyring after the snapshot's keyring release, or that
# were revoked in later releases — NO single keyring can verify them all
# (observed: heftig "key is disabled" with the fresh keyring, Robin Candau
# "unknown trust" with the snapshot-era keyring). Packages are pulled from the
# official archive over HTTPS and this is a throwaway CI container, so the
# signature check is relaxed instead of fighting key rotation.
#
# Also:
# - --overwrite '*': the rolling image splits libs into separate packages
#   (libgomp/libstdc++/libtsan/... ) that the snapshot-era gcc-libs owns
#   directly; without overwriting, the downgrade aborts on file conflicts.
# - libmakepkg-dropins: newer split/dropin package, not needed for the snapshot.
sed -i 's/^SigLevel.*/SigLevel = Never/' /etc/pacman.conf
pacman -Syy --noconfirm
pacman -Rdd --noconfirm libmakepkg-dropins || true
pacman -Syyuu --noconfirm --overwrite '*'
