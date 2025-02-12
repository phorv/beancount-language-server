{
  description = "Build a cargo project";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    crane = {
      url = "github:ipetkov/crane";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-utils.url = "github:numtide/flake-utils";

    advisory-db = {
      url = "github:rustsec/advisory-db";
      flake = false;
    };
  };

  outputs = {
    self,
    nixpkgs,
    crane,
    flake-utils,
    advisory-db,
    ...
  }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import nixpkgs {
        inherit system;
      };

      inherit (pkgs) lib;

      craneLib = crane.lib.${system};
      src = ./.;

      # Build *just* the cargo dependencies, so we can reuse
      # all of that work (e.g. via cachix) when running in CI
      cargoArtifacts = craneLib.buildDepsOnly {
        inherit src;
      };

      # Build the actual crate itself, reusing the dependency
      # artifacts from above.
      beancount-language-server-crate = craneLib.buildPackage {
        inherit cargoArtifacts src;
      };
    in {
      checks =
        {
          # Build the crate as part of `nix flake check` for convenience
          inherit beancount-language-server-crate;

          # Run clippy (and deny all warnings) on the crate source,
          # again, resuing the dependency artifacts from above.
          #
          # Note that this is done as a separate derivation so that
          # we can block the CI if there are issues here, but not
          # prevent downstream consumers from building our crate by itself.
          beancount-language-server-crate-clippy = craneLib.cargoClippy {
            inherit cargoArtifacts src;
            cargoClippyExtraArgs = "--all-targets -- --deny warnings";
          };

          # Check formatting
          beancount-language-server-crate-fmt = craneLib.cargoFmt {
            inherit src;
          };

          # Audit dependencies
          beancount-language-server-crate-audit = craneLib.cargoAudit {
            inherit src advisory-db;
            cargoAuditExtraArgs = "--ignore RUSTSEC-2020-0071";
          };

          # Run tests with cargo-nextest
          # Consider setting `doCheck = false` on `my-crate` if you do not want
          # the tests to run twice
          beancount-language-server-crate-nextest = craneLib.cargoNextest {
            inherit cargoArtifacts src;
            partitions = 1;
            partitionType = "count";
          };
        }
        // lib.optionalAttrs (system == "x86_64-linux") {
          # NB: cargo-tarpaulin only supports x86_64 systems
          # Check code coverage (note: this will not upload coverage anywhere)
          beancount-language-server-crate-coverage = craneLib.cargoTarpaulin {
            inherit cargoArtifacts src;
          };
        };

      packages.default = beancount-language-server-crate;

      apps.default = flake-utils.lib.mkApp {
        drv = beancount-language-server-crate;
      };

      devShells.default = pkgs.mkShell {
        inputsFrom = builtins.attrValues self.checks;

        # Extra inputs can be added here
        nativeBuildInputs = with pkgs; [
          cargo
          cargo-dist
          rustc
          rustfmt
          clippy
          git-cliff
          #nodejs-16_x
          #python310
        ];
      };
    });
}
