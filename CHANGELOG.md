# Changelog

## [Unreleased]

### Fixed

- `nix build` downloaded roughly a gigabyte of build-only dependencies to
  produce a 15 MB binary. The libraries linked into it bake their data
  directory paths in as text — glib's locale data, libX11's compose tables,
  the XML catalog, ImageMagick's — and Nix read those dead strings as runtime
  dependencies. The binary reaches none of them; it now depends on nothing at
  all, so the download is the binary itself.
