{
  description = "decomment - blank out comments in source files while preserving byte offsets";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;

      # No x86_64-darwin: nixpkgs unstable removed it after the 25.11
      # deprecation. Core packages (bash, stdenv, ...) no longer carry it in
      # meta.platforms, so its outputs would not even evaluate.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      # Small helper instead of flake-utils: `f` receives the system and its pkgs.
      forAllSystems = f: lib.genAttrs systems (system: f system nixpkgs.legacyPackages.${system});

      # build.zig.zon is the single source of truth for the version (build.zig
      # imports it as well), so read it here instead of duplicating the number.
      # Falls back to the known value if the file layout ever changes.
      version =
        let
          match = builtins.match ".*\\.version = \"([^\"]+)\".*" (builtins.readFile ./build.zig.zon);
        in
        if match == null then "0.3.1" else builtins.head match;

      mkDecomment =
        pkgs:
        pkgs.stdenv.mkDerivation {
          pname = "decomment";
          inherit version;

          # Mirrors `.paths` in build.zig.zon: keeping flake.nix/flake.lock out
          # of the source means touching them does not invalidate the build.
          # build.zig imports build.zig.zon, so both files must be present.
          src = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./build.zig
              ./build.zig.zon
              ./src
              ./README.md
              ./LICENSE
            ];
          };

          # Pure Zig with zero external dependencies, so no dependency fetching
          # is needed. The hook drives configure/build/install and points
          # ZIG_GLOBAL_CACHE_DIR at a writable temporary directory.
          nativeBuildInputs = [ pkgs.zig_0_16.hook ];

          # `zig build test` is exposed as a separate flake check so that
          # `nix build` / `nix profile install` stay fast.
          doCheck = false;

          meta = {
            description = "Blank out comments in source files while preserving byte offsets";
            homepage = "https://github.com/sammyjoyce/decomment";
            license = lib.licenses.mit;
            mainProgram = "decomment";
            platforms = systems;
          };
        };
    in
    {
      packages = forAllSystems (
        _system: pkgs: rec {
          decomment = mkDecomment pkgs;
          default = decomment;
        }
      );

      apps = forAllSystems (
        system: _pkgs: rec {
          decomment = {
            type = "app";
            program = lib.getExe self.packages.${system}.decomment;
            meta.description = "Blank out comments in source files while preserving byte offsets";
          };
          default = decomment;
        }
      );

      devShells = forAllSystems (
        _system: pkgs: {
          default = pkgs.mkShell {
            packages = [
              pkgs.zig_0_16
            ]
            ++ lib.optional (lib.meta.availableOn pkgs.stdenv.hostPlatform pkgs.zls) pkgs.zls;
          };
        }
      );

      checks = forAllSystems (
        system: _pkgs: {
          # The package itself must build.
          package = self.packages.${system}.decomment;
          # ... and the module + CLI test suites must pass (`zig build test`,
          # run by the zig hook's check phase). No network access is required.
          tests = self.packages.${system}.decomment.overrideAttrs (_: {
            pname = "decomment-tests";
            doCheck = true;
          });
        }
      );

      overlays.default = final: _prev: {
        decomment = mkDecomment final;
      };

      formatter = forAllSystems (_system: pkgs: pkgs.nixfmt-tree);
    };
}
