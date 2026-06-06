# fastfetch

Standalone build of [fastfetch](https://github.com/fastfetch-cli/fastfetch).

[![CI](https://github.com/unpins/fastfetch/actions/workflows/fastfetch.yml/badge.svg)](https://github.com/unpins/fastfetch/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-✓-success?logo=apple&logoColor=white)

Part of the [unpins](https://unpins.org) project — native single-binary builds with no third-party runtime dependencies.

## Usage

Run the `fastfetch` program with [unpin](https://github.com/unpins/unpin):

```bash
unpin fastfetch
```

To install it onto your PATH:

```bash
unpin install fastfetch
```

## Build locally

```bash
nix build github:unpins/fastfetch
./result/bin/fastfetch
```

Or run directly:

```bash
nix run github:unpins/fastfetch
```

The first invocation will offer to add the [unpins.cachix.org](https://unpins.cachix.org) substituter so most pulls come pre-built.

## Manual download

The [Releases](https://github.com/unpins/fastfetch/releases) page has standalone binaries for manual download.

## Man pages

`fastfetch.1` is embedded in the binary — read it with `unpin man fastfetch`.

## Build notes

fastfetch probes the system through many optional libraries that upstream loads
with `dlopen` at runtime. A single static binary can't depend on those being
present on the host, so this build links almost everything **statically** and
reserves `dlopen` for the one case that needs it — the GPU driver.

- **Self-contained except the GPU driver.** Image/logo rendering, the display
  server (XCB/XRandR/Wayland), DRM, D-Bus, GSettings (GLib plus an embedded
  static dconf backend, so theme/icon/font detection reads the real dconf
  databases without the host `libgio`), ddcutil, libelf and zlib are all linked
  in. Only the host GPU stack — Vulkan/OpenCL loaders and the
  NVIDIA/Moore-Threads management libraries — stays dynamic, since it's
  machine-specific. GPU name/vendor still resolves with no driver present, via
  `/sys/class/drm` and an embedded `pci.ids`.
- **Linux on six arches** (x86_64, aarch64, i686, ppc64le, riscv64, armv7l). The
  Vulkan/OpenCL dlopen runs through a TLS-swap trampoline that only has asm for
  x86_64/aarch64, so on the other four GPU compute/render API detail is the one
  feature left out — GPU name via sysfs still works.
- **macOS** reads everything through Apple frameworks (CoreFoundation, IOKit,
  SystemConfiguration), kept dynamic per the dynamic-link policy. Built-in-display
  brightness (`DisplayServices`) and the now-playing Media module (`MediaRemote`)
  have no public-framework path, so the binary weak-links those two *private*
  frameworks as a narrow per-package exception; every call site is null-guarded,
  degrading to "unavailable" rather than breaking if a future macOS drops them.

## Future: Windows port

Not on the roadmap. fastfetch's Windows support is a separate Win32 backend (WMI,
registry, DXGI, NT APIs) that Cosmopolitan can't provide, and the Linux backend
would report nothing on Windows (no `/proc` or `/sys`). A real
`x86_64-w64-mingw32` cross is the path — feasible, but linking the WMI/DXGI/PEB
surface statically under mingw is a project of its own. Contributions welcome —
open an issue first.
