{
  description = "GitHub Action to Reclaim Disk Space for Nix-Only Workflows";

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";
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
                MD026 = false;
                MD034 = false;
                MD041 = false;
                MD012 = false;
                MD036 = false;
              };
            };
          };

          formatter =
            let
              cfg = config.pre-commit.settings;
            in
            pkgs.writeShellScriptBin "pre-commit-fmt" ''
              set -euo pipefail
              export PATH="${
                pkgs.lib.makeBinPath (
                  [
                    cfg.gitPackage
                    cfg.package
                  ]
                  ++ cfg.enabledPackages
                )
              }:$PATH"

              exitcode=0
              if [ "$#" -gt 0 ]; then
                ${pkgs.lib.getExe cfg.package} run -c ${cfg.configFile} --files "$@" || exitcode=$?
              else
                if [ -n "''${PRJ_ROOT:-}" ]; then
                  cd "$PRJ_ROOT"
                fi
                ${pkgs.lib.getExe cfg.package} run -c ${cfg.configFile} --all-files || exitcode=$?
              fi

              if [ "$exitcode" -eq 1 ]; then
                if [ "$#" -gt 0 ]; then
                  ${pkgs.lib.getExe cfg.package} run -c ${cfg.configFile} --files "$@"
                else
                  ${pkgs.lib.getExe cfg.package} run -c ${cfg.configFile} --all-files
                fi
              else
                exit "$exitcode"
              fi
            '';

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
