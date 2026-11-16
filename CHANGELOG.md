# Changelog

## [Unreleased]

### Fixed

- On Linux aarch64, the Vulkan module (`fastfetch -s Vulkan`) crashed the
  program with a segmentation fault or an illegal instruction whenever a
  Vulkan driver was installed. The machine code fastfetch generates at
  runtime to call into the system's GPU libraries was wrong on aarch64; it
  now reports the Vulkan version as it does on x86_64.

## [2.63.1-2] - 2026-09-26

### Fixed

- `nix build` downloaded roughly a gigabyte of build-only dependencies to
  produce a 15 MB binary. The libraries linked into it bake their data
  directory paths in as text — glib's locale data, libX11's compose tables,
  the XML catalog, ImageMagick's — and Nix read those dead strings as runtime
  dependencies. The binary reaches none of them; it now depends on nothing at
  all, so the download is the binary itself.
