# nix-skyline-rs

A flake to provide helpful functionality for building `skyline-rs` plugins using the Nix ecosystem.

This flake provides:

- A function `nix-skyline-rs.lib.${system}.mkNroPackage` that builds a Rust project as an `.nro` file, and takes in the following arguments:
  - `pname`: The package name (ideally from your `Cargo.toml`)
  - `version`: The package version (ideally from your `Cargo.toml`)
  - `src`: The root of the package's source files
  - plus any arguments as supported by [naersk](https://github.com/nix-community/naersk)
- A dev shell under `nix-skyline-rs.devShells.${system}.default` that provides a ready-to-go development environment with the skyline toolchain, `gdb`, `cargo-skyline` and `python311`, as well as `CARGO_BUILD_TARGET` preconfigured for use with `cargo` and `rust-analyzer`.
- The packages `linkle` and `cargo-skyline`, fully built using Nix.

For example usage, see [this repository](https://github.com/Naxdy/latency-slider-de).
