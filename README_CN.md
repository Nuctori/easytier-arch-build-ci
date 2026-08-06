# EasyTier Arch 打包与 SteamOS CI

> [English](README.md) | 简体中文

本仓库通过 GitHub Actions 将 EasyTier 打包为 Arch Linux 软件包，并**确保它能真正在
SteamOS / Steam Deck 上运行**。

## 构建内容

- `easytier` 软件包（Arch：`.pkg.tar.zst`）
  - `easytier-core`
  - `easytier-cli`
  - `easytier-web`
- `easytier-gui` 软件包 / AppImage / Flatpak（Tauri 桌面应用）

源码来自：<https://github.com/EasyTier/EasyTier>

## 工作流（闭环）

| 工作流 | 产物 | 验证内容 |
| --- | --- | --- |
| `build-archpkg` | `*.pkg.tar.zst` | Arch 软件包可构建 |
| `build-appimage` | `*.AppImage` | GUI 打包为单文件，**基于 SteamOS 的 glibc（2.41）构建** |
| `steamos-smoke-test` | `easytier-steamos-<版本>-x86_64.tar.gz` | **二进制真的能在 SteamOS 上跑**：基于 glibc 2.41 构建后，启动一个真实的双节点 `--no-tun` 虚拟局域网，并用 `easytier-cli` 验证节点互通 |
| `build-flatpak` | `*.flatpak` 包 | GUI 以**完全离线**方式构建（与 Flathub 约束一致） |

四个工作流全部通过意味着：软件包能编译、单文件 AppImage 和 Flatpak 都能构建、
CLI/core 二进制在 Steam Deck 上可实际运行。

## 本机构建（Arch 上）

```bash
sudo pacman -Syu --needed base-devel \
  rust cargo protobuf git clang llvm pkgconf zstd \
  nodejs pnpm python \
  webkit2gtk gtk3 librsvg libayatana-appindicator

cd packaging/arch
makepkg -s
```

生成的软件包位于 `packaging/arch/`。

## SteamOS / Steam Deck（单文件）

如果想要一个可下载并在 SteamOS 上直接运行的单文件，请使用 AppImage 构建：

- 工作流：`.github/workflows/build-appimage.yml`
- 产物：`*.AppImage`

在 SteamOS（桌面模式）下：

1. 下载 `*.AppImage`
2. 赋予执行权限：`chmod +x easytier-gui*.AppImage`
3. 运行：
   - 常规方式：`./easytier-gui*.AppImage`
   - 若提示 `Cannot mount AppImage, please check your FUSE setup`：`./easytier-gui*.AppImage --appimage-extract-and-run`

注意事项：

- SteamOS 默认可能没有 `fuse2`。安装 `fuse2` 后可正常使用（挂载式）AppImage。
- 若在 SteamOS（glibc 2.41）上遇到 `GLIBC_2.42 not found`，请用更早的 Arch Linux Archive 快照重新构建 AppImage：
  - `workflow_dispatch` 输入项 `arch_snapshot`（默认：`2025/07/01`）

## SteamOS 冒烟测试（core/cli/web）

`steamos-smoke-test` 工作流把闭环补上：不只编译二进制，还会在 SteamOS 等价环境中
真正运行它们。

1. 通过 `ci/pin-arch-snapshot.sh` 将 pacman 固定到 **glibc <= 2.41** 的 Arch Linux
   Archive 快照（SteamOS 3.7 自带 glibc 2.41）。
2. 基于该运行时构建 `easytier-core`、`easytier-cli`、`easytier-web`。
3. 静态检查：每个二进制要求的最高 `GLIBC_` 符号版本 <= 2.41。
4. 运行检查（`ci/steamos-smoke-test.sh`）：在本机启动两个 `--no-tun` easytier
   节点并互连，用 `easytier-cli` 断言两个节点的路由表都能看到对方的虚拟 IP。
   `--no-tun` 对应 SteamOS 桌面模式（无需 root / TUN 配置）。

可通过 `workflow_dispatch` 手动触发并选择其他 `arch_snapshot`。
产出的 `easytier-steamos-<版本>-x86_64.tar.gz` 是一份开箱即用的 SteamOS 兼容二进制包。

### 为什么固定快照没那么简单

归档快照的软件包由一些打包者密钥签名，而滚动容器的 `archlinux-keyring` 后来
禁用/新增了这些密钥，所以**任何单个 keyring 都无法完整验证一个快照**。
`ci/pin-arch-snapshot.sh` 因此对一次性 CI 容器设置 `SigLevel = Never`
（软件包仍通过 HTTPS 从官方归档下载），并使用 `--overwrite '*'` 处理拆分/合并
软件包带来的文件冲突（例如 `gcc-libs` 与 `libgomp/libstdc++/...`）。

## Flatpak（SteamOS 推荐）

SteamOS 运行 AppImage 可能有问题（FUSE/glibc/Wayland/WebKitGTK），Flatpak 通常
是最可靠的方式。

- Manifest：`packaging/flatpak/io.github.easytier.EasyTierGUI.yml`
- CI 工作流（测试构建）：`.github/workflows/build-flatpak.yml`
- 基于 **GNOME 运行时/SDK** 构建（自带 Tauri v2 所需的 WebKitGTK 4.1）。

Flathub 注意事项：Flathub 构建是**离线**的（flatpak-builder 的构建沙箱默认也无网络，
再怎么改 DNS 都没用）。因此本仓库预先生成*两种*离线依赖仓库，并作为本地 source
打进 manifest：

- `pnpm` store 压缩包（`packaging/flatpak/pnpm-store.tar.gz`）→ `pnpm install --offline`
- vendored cargo 依赖（`packaging/flatpak/cargo-vendor.tar.gz`）→ `cargo build --offline`

两者都由 `packaging/flatpak/scripts/` 下的 CI 脚本（`make-pnpm-store.sh`、
`make-cargo-vendor.sh`）生成并缓存。提交 Flathub 时应把这些压缩包固定为远端 source
（或生成 `generated-sources*.json`）。

## 备注

- 需要 `protobuf`：EasyTier 在 Linux 上使用 `protoc` 构建。
- 需要 `clang/llvm`：`kcp-sys` 使用 `bindgen`，需要 `libclang`。
- 需要 `pkgconf` + `zstd`：`zstd-sys` 链接系统 `libzstd`。
- 需要 `nodejs/pnpm/python` 和 `webkit2gtk/gtk3/...`：构建 Tauri GUI。
- CI 构建会从 `easytier-gui/vite.config.ts` 中移除 `vite-plugin-vue-devtools`
  （它在 Node/CI 中可能因浏览器 `localStorage` 假设而崩溃），并通过
  `NODE_OPTIONS=--import ...` 注入最小 `localStorage` polyfill 供其他 Node 侧工具使用。
- 若出现 `ring_*` / `ikcp_*` 链接错误，可能是 GCC LTO 目标文件被 `lld` 链接所致；
  本仓库在 `PKGBUILD` 中会去掉 `-flto=auto` / `-fuse-ld=lld`。

## 升级 EasyTier 版本

编辑 `packaging/arch/PKGBUILD`：

- `pkgver=...`
- `source=...v$pkgver.tar.gz`

可选：用 `updpkgsums`（来自 `pacman-contrib`）计算校验和。
