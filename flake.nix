{
  description = "GitHub Action to Reclaim Disk Space for Nix-Only Workflows";

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.zst";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    systems.url = "github:nix-systems/triplet";
    git-hooks-nix = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import inputs.systems;

      imports = [
        inputs.git-hooks-nix.flakeModule
      ];

      perSystem =
        {
          config,
          pkgs,
          ...
        }:
        {
          pre-commit.settings.hooks = {
            shfmt.enable = true;
            nixfmt.enable = true;
            shellcheck.enable = true;
            statix.enable = true;
            deadnix.enable = true;
            markdownlint = {
              enable = true;
              excludes = [
                "^LICENSE\\.md$"
                "^\\.github/.*"
              ];
              settings.configuration = {
                MD013 = false;
                MD024 = {
                  siblings_only = true;
                };
              };
            };
          };

          packages.test-runner = pkgs.writeShellApplication {
            name = "test-runner";
            runtimeInputs = [ pkgs.gh ];
            text = ''
              gh workflow run test.yml --ref "$(git rev-parse --abbrev-ref HEAD)"
              gh run watch
            '';
          };

          devShells.default = pkgs.mkShell {
            inputsFrom = [ config.pre-commit.devShell ];
            packages = [
              pkgs.nodejs_24
              pkgs.gawk
              pkgs.coreutils
              pkgs.gh
            ];
          };

          checks = {
            test-suite =
              let
                testSrc = pkgs.lib.fileset.toSource {
                  root = ./.;
                  fileset = pkgs.lib.fileset.unions [
                    ./src
                    ./tests
                    ./action.yml
                  ];
                };
              in
              pkgs.runCommand "test-suite"
                {
                  nativeBuildInputs = [
                    pkgs.coreutils
                    pkgs.gawk
                  ];
                }
                ''
                  export HOME=$TMPDIR
                  cp -r ${testSrc}/* .
                  chmod -R +w .
                  ./tests/test_scenarios.sh
                  touch $out
                '';
          };
        };
    };
}
