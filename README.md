# EasyTier Arch Package & SteamOS CI

> English | [简体中文](README_CN.md)

This repository builds EasyTier for Arch Linux and ensures it actually runs on
**SteamOS / Steam Deck** — all enforced by GitHub Actions.

## What it builds

- `easytier` package (Arch: `.pkg.tar.zst`)
  - `easytier-core`
  - `easytier-cli`
  - `easytier-web`
- `easytier-gui` package / AppImage / Flatpak (Tauri desktop app)

Source code is fetched from: <https://github.com/EasyTier/EasyTier>

## Workflows (the closed loop)

| Workflow | Artifacts | Verifies |
| --- | --- | --- |
| `build-archpkg` | `*.pkg.tar.zst` | Arch package builds |
| `build-appimage` | `*.AppImage` | GUI bundles as a single file, **built against SteamOS's glibc (2.41)** |
| `steamos-smoke-test` | `easytier-steamos-<ver>-x86_64.tar.gz` | **Binaries actually run on SteamOS**: built against glibc 2.41, then a real two-node `--no-tun` virtual network is started and peer connectivity is verified via `easytier-cli` |
| `build-flatpak` | `*.flatpak` bundle | GUI builds **fully offline** (same constraints as Flathub) |

A green run of all four means: the package compiles, the single-file AppImage
and the Flatpak both build, and the CLI/core binaries demonstrably work on a
Steam Deck.

## Local build (on Arch)

```bash
sudo pacman -Syu --needed base-devel \
  rust cargo protobuf git clang llvm pkgconf zstd \
  nodejs pnpm python \
  webkit2gtk gtk3 librsvg libayatana-appindicator

cd packaging/arch
makepkg -s
```

The package files will be created in `packaging/arch/`.

## SteamOS / Steam Deck (single file)

If you want a single file that can be downloaded and run on SteamOS, use the AppImage build:

- Workflow: `.github/workflows/build-appimage.yml`
- Output: `*.AppImage` artifact

On SteamOS (Desktop Mode):

1. Download the `*.AppImage`
2. Make it executable: `chmod +x easytier-gui*.AppImage`
3. Run it:
   - Normal: `./easytier-gui*.AppImage`
   - If you see `Cannot mount AppImage, please check your FUSE setup`: `./easytier-gui*.AppImage --appimage-extract-and-run`

Notes:

- SteamOS may not ship `fuse2` by default. Installing `fuse2` enables normal (mount-based) AppImage execution.
- If you see `GLIBC_2.42 not found` on SteamOS (glibc 2.41), rebuild the AppImage using an older Arch Linux Archive snapshot:
  - `workflow_dispatch` input `arch_snapshot` (default: `2025/07/01`)

## SteamOS smoke test (core/cli/web)

The `steamos-smoke-test` workflow closes the loop: it doesn't just compile the
binaries, it runs them on a SteamOS-equivalent environment.

1. Pins pacman to an Arch Linux Archive snapshot with **glibc <= 2.41**
   (SteamOS 3.7 ships glibc 2.41) via `ci/pin-arch-snapshot.sh`.
2. Builds `easytier-core`, `easytier-cli`, `easytier-web` against that runtime.
3. Static check: the max `GLIBC_` symbol each binary requires is <= 2.41.
4. Runtime check (`ci/steamos-smoke-test.sh`): starts two `--no-tun`
   easytier nodes on the host, connects them as peers, and asserts each node
   sees the other's virtual IP in its route table through `easytier-cli`.
   `--no-tun` matches SteamOS Desktop Mode without root/TUN setup.

Trigger manually via `workflow_dispatch` to pick a different `arch_snapshot`.
The produced `easytier-steamos-<ver>-x86_64.tar.gz` is a drop-in tarball of
SteamOS-compatible binaries.

### Why the snapshot pinning is non-trivial

Archive snapshots are signed by packager keys that the rolling container's
`archlinux-keyring` has since disabled/added, so no single keyring can verify a
snapshot. `ci/pin-arch-snapshot.sh` therefore sets `SigLevel = Never` for the
throwaway CI container (packages still come from the official archive over
HTTPS) and uses `--overwrite '*'` to survive split/merged package conflicts
(e.g. `gcc-libs` vs `libgomp/libstdc++/...`).

## Flatpak (SteamOS recommended)

SteamOS may have issues running AppImage (FUSE/glibc/Wayland/WebKitGTK). Flatpak is usually the most reliable option.

- Manifest: `packaging/flatpak/io.github.easytier.EasyTierGUI.yml`
- CI workflow (test build): `.github/workflows/build-flatpak.yml`
- Builds on the **GNOME runtime/SDK** (bundles WebKitGTK 4.1, required by Tauri v2).

Flathub note: Flathub builds are **offline** (and so is flatpak-builder's build
sandbox by default — no amount of DNS workarounds helps). This repo therefore
pre-generates *both* offline stores and ships them as local manifest sources:

- `pnpm` store tarball (`packaging/flatpak/pnpm-store.tar.gz`) → `pnpm install --offline`
- vendored cargo deps (`packaging/flatpak/cargo-vendor.tar.gz`) → `cargo build --offline`

Both are produced by CI scripts in `packaging/flatpak/scripts/`
(`make-pnpm-store.sh`, `make-cargo-vendor.sh`) and cached. For Flathub
submission you should pin those tarballs as remote sources (or generate
`generated-sources*.json`).

## Notes

- `protobuf` is required because EasyTier's build uses `protoc` on Linux.
- `clang/llvm` are required because `kcp-sys` uses `bindgen`, which needs `libclang`.
- `pkgconf` + `zstd` are required so `zstd-sys` can link to `libzstd`.
- `nodejs/pnpm/python` and `webkit2gtk/gtk3/...` are required to build the Tauri GUI.
- CI builds strip `vite-plugin-vue-devtools` from `easytier-gui/vite.config.ts` because it may crash in Node/CI (browser `localStorage` assumption), and also inject a minimal `localStorage` polyfill via `NODE_OPTIONS=--import ...` for other Node-side tooling.
- If you see linker errors about `ring_*` or `ikcp_*`, they may be caused by GCC LTO objects being linked with `lld`; this repo strips `-flto=auto` / `-fuse-ld=lld` during the build inside `PKGBUILD`.

## Bumping EasyTier version

Edit `packaging/arch/PKGBUILD`:

- `pkgver=...`
- `source=...v$pkgver.tar.gz`

Optionally compute checksums with `updpkgsums` (from `pacman-contrib`).
