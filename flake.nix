{
  description = "A helper flake for building SSBU mods using skyline-rs.";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-24.05";

    flake-utils.url = "github:numtide/flake-utils";

    cargo-skyline-src = {
      url = "github:jam1garner/cargo-skyline";
      flake = false;
    };
    fenix.url = "github:nix-community/fenix";

    naersk.url = "github:Naxdy/naersk?ref=work/consider-additional-cargo-lock";

    linkle-src = {
      url = "github:MegatonHammer/linkle";
      flake = false;
    };
  };

  outputs =
    { self
    , nixpkgs
    , flake-utils
    , fenix
    , naersk
    , linkle-src
    , cargo-skyline-src
    }: flake-utils.lib.eachDefaultSystem (system:
    let
      pkgs = import nixpkgs {
        inherit system;
        overlays = [
          fenix.overlays.default
        ];
      };

      skyline-rust-src = pkgs.runCommandLocal "skyline-rust-src"
        {
          src = pkgs.fetchFromGitHub {
            owner = "skyline-rs";
            repo = "rust-src";
            rev = "3b1dd4aca19b5dca6e90a3de457304f013d7bc77";
            hash = "sha256-aXmyW7pVSar31r9nm+WvmKQcoXI5Ht3ZEnB3yWbnxJY=";
            fetchSubmodules = true;
          };
        } ''
        mkdir -p $out/lib/rustlib/src/
        cp -r $src $out/lib/rustlib/src/rust
      '';

      skylineBaseToolchain = pkgs.fenix.toolchainOf {
        channel = "nightly";
        date = "2023-12-30";
        sha256 = "sha256-6ro0E+jXO1vkfTTewwzJu9NrMf/b9JWJyU8NaEV5rds=";
      };

      skylineToolchain = fenix.packages.${system}.combine ((builtins.attrValues {
        inherit (skylineBaseToolchain)
          cargo
          clippy
          rustc
          rustfmt;
      }) ++ [
        skyline-rust-src
      ]);

      stableToolchain = pkgs.fenix.stable.withComponents [
        "cargo"
        "rustc"
      ];

      naersk_skyline = naersk.lib.${system}.override {
        cargo = skylineToolchain;
        rustc = skylineToolchain;
      };

      naersk_stable = naersk.lib.${system}.override {
        cargo = stableToolchain;
        rustc = stableToolchain;
      };

      patched-build-target = pkgs.runCommandLocal "skyline-build-target"
        {
          src = pkgs.substitute {
            src = "${skyline-rust-src}/lib/rustlib/src/rust/aarch64-skyline-switch.json";
            substitutions = [
              "--replace-fail"
              "-Tlink.T"
              "-T${cargo-skyline-src}/src/link.T"
            ];
          };
        } ''
        mkdir -p $out
        cp $src $out/aarch64-skyline-switch.json
      '';

      CARGO_BUILD_TARGET = "${patched-build-target}/aarch64-skyline-switch.json";
    in
    {
      packages = {

        cargo-skyline =
          let
            cargoTOML = (builtins.fromTOML (builtins.readFile "${cargo-skyline-src}/Cargo.toml"));
          in
          naersk_stable.buildPackage {
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
          naersk_stable.buildPackage {
            pname = cargoTOML.package.name;
            version = cargoTOML.package.version;

            src = linkle-src;

            # https://github.com/nix-community/naersk/issues/127
            singleStep = true;

            cargoBuildOptions = old: old ++ [
              "--bin"
              "linkle"
              "--features=binaries"
            ];

            meta.description = "Command line utility for working with Nintendo file formats.";
          };
      };

      lib.mkNroPackage =
        { pname
        , version
        , src
        , ...
        }@args: naersk_skyline.buildPackage
          {
            inherit
              pname
              version
              src;

            additionalCargoLock = "${skyline-rust-src}/lib/rustlib/src/rust/Cargo.lock";

            cargoBuildOptions = old: pkgs.lib.unique (old ++ [
              "-Z"
              "build-std=core,alloc,std,panic_abort"
            ] ++ (pkgs.lib.optionals (args ? cargoBuildOptions) (args.cargoBuildOptions old)));

            copyLibs = true;
            copyBins = false;

            gitSubmodules = true;

            env = {
              inherit CARGO_BUILD_TARGET;
              SKYLINE_ADD_NRO_HEADER = "1";
            } // (builtins.removeAttrs (args.env or { }) [ "CARGO_BUILD_TARGET" "SKYLINE_ADD_NRO_HEADER" ]);

            overrideMain = old: ({
              postInstall = ''
                cd $out/lib
                for f in *.so; do
                  ${self.packages.${system}.linkle}/bin/linkle nro $f ''${f%.so}.nro
                  rm $f
                done
              '';
            } // (args.overrideMain or (old: { })) old);
          } // (builtins.removeAttrs args [
          "pname"
          "version"
          "src"
          "additionalCargoLock"
          "cargoBuildOptions"
          "copyLibs"
          "copyBins"
          "gitSubmodules"
          "env"
          "overrideMain"
        ]);

      devShells.default = pkgs.mkShell {
        nativeBuildInputs = builtins.attrValues {
          inherit (pkgs) gdb python311;
          inherit skylineToolchain;
          inherit (self.packages.${system}) cargo-skyline;
        };

        inherit CARGO_BUILD_TARGET;
      };
    });
}
