{
  description = "A helper flake for building SSBU mods using skyline-rs.";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-25.05";

    cargo-skyline-src = {
      url = "github:jam1garner/cargo-skyline";
      flake = false;
    };
    fenix.url = "github:nix-community/fenix";

    crane.url = "github:ipetkov/crane";

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

      forEachSupportedSystem =
        f:
        nixpkgs.lib.genAttrs supportedSystems (
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
                    rev = "3b1dd4aca19b5dca6e90a3de457304f013d7bc77";
                    hash = "sha256-aXmyW7pVSar31r9nm+WvmKQcoXI5Ht3ZEnB3yWbnxJY=";
                    fetchSubmodules = true;
                  };
                }
                ''
                  mkdir -p $out/lib/rustlib/src/
                  cp -r $src $out/lib/rustlib/src/rust
                '';

            skylineBaseToolchain = pkgs.fenix.toolchainOf {
              channel = "nightly";
              date = "2023-12-30";
              sha256 = "sha256-6ro0E+jXO1vkfTTewwzJu9NrMf/b9JWJyU8NaEV5rds=";
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

            patched-build-target =
              pkgs.runCommandLocal "skyline-build-target"
                {
                  src = pkgs.substitute {
                    src = "${skyline-rust-src}/lib/rustlib/src/rust/aarch64-skyline-switch.json";
                    substitutions = [
                      "--replace-fail"
                      "-Tlink.T"
                      "-T${cargo-skyline-src}/src/link.T"
                    ];
                  };
                }
                ''
                  mkdir -p $out
                  cp $src $out/aarch64-skyline-switch.json
                '';

            CARGO_BUILD_TARGET = "${patched-build-target}/aarch64-skyline-switch.json";
          in
          f {
            inherit
              CARGO_BUILD_TARGET
              craneSkyline
              craneStable
              pkgs
              skyline-rust-src
              skylineToolchain
              system
              ;
          }
        );
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

      lib = forEachSupportedSystem (
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
            craneSkyline.buildPackage (
              {
                inherit
                  pname
                  version
                  copyLibs
                  src
                  ;

                cargoVendorDir = craneSkyline.vendorCargoDeps {
                  cargoLockParsed =
                    let
                      skylineCargoLock = builtins.fromTOML (
                        builtins.readFile "${skyline-rust-src}/lib/rustlib/src/rust/Cargo.lock"
                      );
                      ourCargoLock = builtins.fromTOML (builtins.readFile "${src}/Cargo.lock");
                    in
                    {
                      inherit (ourCargoLock) version;

                      package = ourCargoLock.package ++ skylineCargoLock.package;
                    };
                };

                cargoExtraArgs = "--offline -Z build-std=core,alloc,std,panic_abort";

                inherit CARGO_BUILD_TARGET;

                env =
                  {
                    SKYLINE_ADD_NRO_HEADER = "1";
                  }
                  // (builtins.removeAttrs (args.env or { }) [
                    "CARGO_BUILD_TARGET"
                    "SKYLINE_ADD_NRO_HEADER"
                  ]);

                postInstall = ''
                  cd $out/lib
                  for f in *.so; do
                    ${self.packages.${system}.linkle}/bin/linkle nro $f ''${f%.so}.nro
                    rm $f
                  done
                '';
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
              ])
            );
        }
      );

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
            nativeBuildInputs = builtins.attrValues {
              inherit (pkgs) gdb python311;
              inherit skylineToolchain;
              inherit (self.packages.${system}) cargo-skyline;
            };

            inherit CARGO_BUILD_TARGET;
          };
        }
      );
    };
}
