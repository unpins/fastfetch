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

## Man pages

`fastfetch.1` is embedded in the binary — read with `unpin man fastfetch`.

## Manual download

The [Releases](https://github.com/unpins/fastfetch/releases) page has standalone binaries for manual download.

## Build notes

fastfetch probes the system through a lot of optional libraries. Upstream loads
all of them with `dlopen` at runtime, which makes the binary depend on those
libraries being present on the host. A single static binary can't rely on that,
so this build links almost everything **statically** and reserves `dlopen` for
the one case that genuinely needs it.

- **Self-contained except the GPU driver.** Image/logo rendering (ImageMagick,
  Chafa), the display server (XCB, XRandR, Wayland), DRM, D-Bus, GSettings
  (GLib + an embedded static dconf backend), ddcutil, libelf, zlib and the rest
  are all linked into the binary. The only libraries still loaded at runtime are
  the **host GPU stack** — Vulkan/OpenCL loaders and the NVIDIA/Moore-Threads
  management libraries — because the GPU driver is machine-specific and cannot
  be bundled. GPU name/vendor still resolves with no driver present, via
  `/sys/class/drm` and an embedded `pci.ids`.

- **GSettings without a host GLib.** Theme/icon/font/cursor detection uses a
  dconf GIO backend built against this build's static GLib and registered at
  startup, so the values come from the real user/system dconf databases without
  dlopen'ing the host `libgio`.

- **Linux runs on six arches.** x86_64, aarch64, i686, ppc64le, riscv64 and
  armv7l. On x86_64/aarch64 the Vulkan/OpenCL loaders run through a TLS-swap
  trampoline so they can dlopen the host ICD from a static-musl binary; the
  trampoline has no asm for the other four arches, so on those GPU
  compute/render API detail is the one feature left out (everything else,
  including GPU name via sysfs, is present).

- **macOS** reads everything through Apple frameworks (CoreFoundation, IOKit,
  SystemConfiguration, sysctl) — no dlopen trampoline needed; those frameworks
  are allowed to stay dynamic per the project's dynamic-link policy.

- No upstream features are disabled beyond the GPU compute/render APIs on the
  four secondary Linux cross targets noted above.

## Future: Windows port

Not on the current roadmap. Unlike its Linux/macOS backends, fastfetch's Windows
support is a separate Win32 backend that talks to WMI, the registry, DXGI and
the NT APIs. Cosmopolitan can't provide that surface (it polyfills POSIX, not
WMI/registry/DXGI), and the Linux backend run under Cosmopolitan would report
nothing useful on Windows because there is no `/proc` or `/sys`. A real
`x86_64-w64-mingw32` cross-build is the path — feasible, but it needs the WMI /
DXGI / PEB-walking surface linked statically under mingw, which is a project of
its own. Contributions welcome — open an issue first.
