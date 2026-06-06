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

fastfetch probes the system through many libraries that upstream `dlopen`s at
runtime. This build links them **statically** instead — the only thing left
dynamic is the machine-specific GPU driver (Vulkan/OpenCL loaders, NVIDIA/Moore-Threads
management libs); GPU name/vendor still resolves without a driver via sysfs and an
embedded `pci.ids`.

- **Linux** ships for six arches (x86_64, aarch64, i686, ppc64le, riscv64, armv7l). GPU
  compute/render API detail needs a TLS-swap trampoline that only exists for x86_64/aarch64,
  so it's the one feature missing on the other four.
- **macOS** uses Apple frameworks. Two features (display brightness, now-playing Media) rely
  on *private* frameworks, weak-linked as a per-package exception and null-guarded so they
  degrade to "unavailable" rather than break on a future macOS.
