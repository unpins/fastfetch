# fastfetch

[fastfetch](https://github.com/fastfetch-cli/fastfetch) as a single self-contained binary, built natively for Linux and macOS.

[![CI](https://github.com/unpins/fastfetch/actions/workflows/fastfetch.yml/badge.svg)](https://github.com/unpins/fastfetch/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-✓-success?logo=apple&logoColor=white)

Part of the [unpins](https://unpins.org) catalog; install it with [`unpin`](https://github.com/unpins/unpin): `unpin install fastfetch`.

## Usage

Run the `fastfetch` program with [unpin](https://github.com/unpins/unpin):

```bash
unpin fastfetch
```

To install it onto your PATH:

```bash
unpin install fastfetch
```

## Man pages

`fastfetch.1` is embedded in the binary — read it with `unpin man fastfetch`.

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

## Build notes

fastfetch normally loads many of its libraries from the system at runtime.
This build puts them inside the binary instead. What still comes from the
system is what has to match the machine: the GPU drivers (Vulkan, OpenCL,
OpenGL), the PulseAudio client library for the Sound module, and the NVIDIA
and Moore Threads management libraries. Without a driver, the GPU name and
vendor still show up, read from sysfs and an embedded PCI ID list.

What is missing, and where:

- **Linux i686, ppc64le, riscv64 and armv7l:** no Vulkan, OpenCL, OpenGL or
  Sound details, because loading the system's libraries only works on x86_64
  and aarch64. Everything else matches the x86_64 and aarch64 builds.
- **macOS:** no Vulkan module. MoltenVK, the only Vulkan driver on macOS, can't
  be built into the binary; the GPU itself is still detected. Display
  brightness and the now-playing Media module use private Apple frameworks; if
  a future macOS removes them, those modules report "unavailable" instead of
  failing.
- **Image logos:** PNG, JPEG, WebP, TIFF, HEIC, JPEG XL and SVG work. Camera
  RAW, OpenEXR, DjVu and JPEG 2000 images don't.
- **Windows:** no build yet.
