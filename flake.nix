{
  description = "A helper flake for building SSBU mods using skyline-rs.";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    fenix.url = "github:nix-community/fenix";

    crane.url = "github:ipetkov/crane/v0.23.0";

    cargo-skyline-src = {
      url = "github:jam1garner/cargo-skyline";
      flake = false;
    };

    linkle-src = {
      url = "github:MegatonHammer/linkle";
      flake = false;
    };
  };

  outputs =
    {
      cargo-skyline-src,
      crane,
      fenix,
      linkle-src,
      nixpkgs,
      self,
    }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      attrsForSystem =
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [
              fenix.overlays.default
            ];
          };

          skyline-rust-src =
            pkgs.runCommandLocal "skyline-rust-src"
              {
                src = pkgs.fetchFromGitHub {
                  owner = "skyline-rs";
                  repo = "rust-src";
                  rev = "3848adbb6115f80702ff9d2b88a17288937db3db"; # branch `skyline`
                  hash = "sha256-TV/6msvxna7WzSflAAq2C6fz5mnah6pbIbOI2MXxrRs=";
                  fetchSubmodules = true;
                };
              }
              ''
                mkdir -p $out/lib/rustlib/src/
                cp -r $src $out/lib/rustlib/src/rust
              '';

          skylineBaseToolchain = pkgs.fenix.toolchainOf {
            channel = "nightly";
            date = "2024-10-09"; # date of last bors commit to `skyline` branch
            sha256 = "sha256-NUQz7n8uyR/O+DE5DsgEupEiJsU8YeVHuKuPd5TCJ3E=";
          };

          skylineToolchain = pkgs.fenix.combine (
            (builtins.attrValues {
              inherit (skylineBaseToolchain)
                cargo
                clippy
                rustc
                rustfmt
                ;
            })
            ++ [
              skyline-rust-src
            ]
          );

          stableToolchain = pkgs.fenix.stable.withComponents [
            "cargo"
            "rustc"
          ];

          craneSkylinePre = (crane.mkLib pkgs).overrideToolchain skylineToolchain;
          craneStable = (crane.mkLib pkgs).overrideToolchain stableToolchain;

          craneSkyline = craneSkylinePre.appendCrateRegistries [
            (craneSkylinePre.registryFromGitIndex {
              indexUrl = "https://github.com/ultimate-research/libc-nnsdk";
              rev = "da6a3d0b5916354977166b3ed8df86a0d02e327c";
            })
          ];

          # extracted from cargo skyline
          buildTarget = pkgs.writeText "aarch64-skyline-switch.json" ''
            {
              "arch": "aarch64",
              "crt-static-default": false,
              "crt-static-respected": false,
              "data-layout": "e-m:e-i8:8:32-i16:16:32-i64:64-i128:128-n32:64-S128-Fn32",
              "dynamic-linking": true,
              "executables": true,
              "has-rpath": false,
              "linker": "rust-lld",
              "linker-flavor": "ld.lld",
              "llvm-target": "aarch64-unknown-none",
              "max-atomic-width": 128,
              "os": "switch",
              "panic-strategy": "abort",
              "position-independent-executables": true,
              "pre-link-args": {
                "ld.lld": [
                  "-T${cargo-skyline-src}/src/link.T",
                  "-init=__custom_init",
                  "-fini=__custom_fini",
                  "--export-dynamic"
                ]
              },
              "post-link-args": {
                "ld.lld": [
                  "--no-gc-sections",
                  "--eh-frame-hdr"
                ]
              },
              "relro-level": "off",
              "target-c-int-width": 32,
              "target-endian": "little",
              "target-pointer-width": "64",
              "vendor": "jam1garner"
            }
          '';

          CARGO_BUILD_TARGET =
            let
              # we need to have an extra derivation to ensure the file is called "aarch64-skyline-switch.json"
              pkg =
                pkgs.runCommandLocal "aarch64-skyline-switch"
                  {
                  }
                  ''
                    mkdir -p $out
                    cp ${buildTarget} $out/aarch64-skyline-switch.json
                  '';
            in
            "${pkg}/aarch64-skyline-switch.json";
        in
        {
          inherit
            CARGO_BUILD_TARGET
            craneSkyline
            craneStable
            pkgs
            skyline-rust-src
            skylineToolchain
            system
            ;
        };

      forEachSupportedSystem =
        f: nixpkgs.lib.genAttrs supportedSystems (system: f (attrsForSystem system));
    in
    {
      packages = forEachSupportedSystem (
        { craneStable, ... }:
        {
          cargo-skyline =
            let
              cargoTOML = (builtins.fromTOML (builtins.readFile "${cargo-skyline-src}/Cargo.toml"));
            in
            craneStable.buildPackage {
              pname = cargoTOML.package.name;
              version = cargoTOML.package.version;

              src = cargo-skyline-src;

              meta = {
                description = "A cargo subcommand for working with Skyline plugins written in Rust";
              };
            };

          linkle =
            let
              cargoTOML = builtins.fromTOML (builtins.readFile "${linkle-src}/Cargo.toml");
            in
            craneStable.buildPackage {
              pname = cargoTOML.package.name;
              version = cargoTOML.package.version;

              src = linkle-src;

              cargoExtraArgs = "--locked --bin linkle --features=binaries";

              meta.description = "Command line utility for working with Nintendo file formats.";
            };
        }
      );

      lib = {
        forSystem =
          system:
          let
            attrs = attrsForSystem system;
          in
          (
            {
              CARGO_BUILD_TARGET,
              craneSkyline,
              pkgs,
              skyline-rust-src,
              system,
              ...
            }:
            {
              mkNroPackage =
                {
                  pname,
                  version,
                  src,
                  copyLibs ? true,
                  ...
                }@args:
                let
                  craneArgs = {
                    inherit
                      pname
                      version
                      copyLibs
                      src
                      ;

                    cargoVendorDir = craneSkyline.vendorMultipleCargoDeps {
                      cargoLockList = [
                        "${src}/Cargo.lock"
                        "${skyline-rust-src}/lib/rustlib/src/rust/Cargo.lock"
                        "${skyline-rust-src}/lib/rustlib/src/rust/library/Cargo.lock"
                      ];
                    };

                    # doesn't work with skyline toolchain
                    doCheck = false;

                    cargoExtraArgs = "--offline --locked -Z build-std=core,alloc,std,panic_abort";

                    env = {
                      inherit CARGO_BUILD_TARGET;
                      SKYLINE_ADD_NRO_HEADER = "1";
                    }
                    // (builtins.removeAttrs (args.env or { }) [
                      "CARGO_BUILD_TARGET"
                      "SKYLINE_ADD_NRO_HEADER"
                    ]);
                  };

                  cargoArtifacts = craneSkyline.buildDepsOnly craneArgs;
                in
                craneSkyline.buildPackage (
                  craneArgs
                  // {
                    inherit cargoArtifacts;

                    postInstall = ''
                      cd $out/lib
                      for f in *.so; do
                        ${self.packages.${system}.linkle}/bin/linkle nro $f ''${f%.so}.nro
                        rm $f
                      done
                    '';

                    env = craneArgs.env // (args.toplevelEnv or { });
                  }
                  // (builtins.removeAttrs args [
                    "pname"
                    "version"
                    "src"
                    "copyLibs"
                    "cargoBuildOptions"
                    "gitSubmodules"
                    "env"
                    "overrideMain"
                    "toplevelEnv"
                  ])
                );
            }
          )
            attrs;
      };

      devShells = forEachSupportedSystem (
        {
          CARGO_BUILD_TARGET,
          pkgs,
          skylineToolchain,
          system,
          ...
        }:
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.gdb
              pkgs.python311
              self.packages.${system}.cargo-skyline
              skylineToolchain
            ];

            env = {
              inherit CARGO_BUILD_TARGET;
            };
          };
        }
      );
    };
}
