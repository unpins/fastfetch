# Changelog

## [Unreleased]

### Added

- On Linux x86_64 and aarch64, the OpenGL and Sound modules now work: they
  report the OpenGL version and the PulseAudio (or PipeWire) audio devices.
- On musl-based Linux aarch64 systems such as Alpine, fastfetch can now load
  the system's GPU libraries, as it already did on x86_64 and on glibc-based
  aarch64, so the Vulkan module reports the installed driver instead of
  nothing.

### Fixed

- On Linux, image logos in WebP, TIFF, HEIC and JPEG XL failed to render; they
  now display like PNG and JPEG.
- On macOS, the image logo only worked on Macs with Homebrew's ImageMagick
  installed. Image logos no longer need anything installed.
- On Linux aarch64, the Vulkan module (`fastfetch -s Vulkan`) crashed the
  program with a segmentation fault or an illegal instruction whenever a
  Vulkan driver was installed. The machine code fastfetch generates at
  runtime to call into the system's GPU libraries was wrong on aarch64; it
  now reports the Vulkan version as it does on x86_64.
- fastfetch was compiled without optimization and with its debug assertions
  on, on every platform: `fastfetch --version` printed `2.63.1-debug`. It is
  now an optimized release build, as upstream intends.

## [2.63.1-2] - 2026-09-26

### Fixed

- `nix build` downloaded roughly a gigabyte of build-only dependencies to
  produce a 15 MB binary. The libraries linked into it bake their data
  directory paths in as text — glib's locale data, libX11's compose tables,
  the XML catalog, ImageMagick's — and Nix read those dead strings as runtime
  dependencies. The binary reaches none of them; it now depends on nothing at
  all, so the download is the binary itself.
