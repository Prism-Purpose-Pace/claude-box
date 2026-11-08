{
  description = "Development environment for nix-claude-code";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";

    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.treefmt-nix.flakeModule
        inputs.git-hooks.flakeModule
      ];

      systems = import ../systems.nix;

      perSystem =
        {
          config,
          pkgs,
          ...
        }:
        let
          # Shared by the gitleaks flake check (full `detect`) and the
          # commit-time pre-commit hook (`git --staged`), so both stages
          # honour the same rules.
          gitleaksConfig = ./../.gitleaks.toml;
        in
        {
          treefmt = {
            # Format the whole repository, not just `dev/`. `cleanSource` strips
            # `.git`, so anchor the project root on `flake.nix`.
            projectRoot = pkgs.lib.cleanSource ./..;
            projectRootFile = "flake.nix";
            # The pre-commit flake check below already runs treefmt over every
            # file (and prints the diff), so skip treefmt-nix's own duplicate.
            flakeCheck = false;
            programs = {
              # Nix
              nixfmt.enable = true;
              deadnix.enable = true;
              statix.enable = true;
              nixf-diagnose.enable = true;

              # Python: rules and line length live in `ruff.toml` so editors
              # and a bare `ruff` invocation agree with the hook.
              ruff-format.enable = true;
              ruff-check.enable = true;

              # Shell: shfmt formats (style from `.editorconfig`), shellcheck
              # lints (including `.envrc`).
              shfmt = {
                enable = true;
                useEditorConfig = true;
              };
              shellcheck.enable = true;

              # GitHub Actions: actionlint also runs shellcheck on `run:`
              # blocks; zizmor flags insecure workflow patterns offline (the
              # security workflow repeats it online with a token).
              actionlint.enable = true;
              zizmor.enable = true;

              # Markdown, YAML, JSON(5) and TOML.
              oxfmt.enable = true;
              taplo.enable = true;

              # Spelling across every file.
              typos.enable = true;
            };

            # treefmt-nix ships no nufmt module, so declare the formatter by
            # hand. Without it `update.nu` is the one tracked source file that
            # no formatter checks.
            # Same threshold and config as the security workflow, but offline:
            # the flake sandbox has no network and a commit must not depend on
            # the GitHub API. Online audits (impostor commits, known-vulnerable
            # actions) stay in `.github/workflows/security.yaml`.
            settings.formatter.zizmor.options = [
              "--offline"
              "--min-severity=low"
              "--config=.github/zizmor.yml"
            ];

            settings.formatter.nufmt = {
              command = pkgs.lib.getExe pkgs.nufmt;
              includes = [ "*.nu" ];
            };
          };

          checks = {
            # Expose a full gitleaks scan as a flake check so `nix flake check`
            # covers secret detection. The flake sandbox has no `.git`, so we
            # scan the cleaned working tree with `--no-git` rather than history.
            gitleaks =
              pkgs.runCommand "gitleaks"
                {
                  nativeBuildInputs = [ pkgs.gitleaks ];
                }
                ''
                  gitleaks detect \
                    --source ${pkgs.lib.cleanSource ./..} \
                    --config ${gitleaksConfig} \
                    --no-git \
                    --redact
                  touch "$out"
                '';

          };

          pre-commit = {
            # The same hooks run on `git commit` (installed by the dev shell)
            # and in `nix flake check`, so CI enforces exactly what a commit
            # enforces. Formatters rewrite files in place on commit; the commit
            # then aborts so the fixes can be reviewed and staged.
            check.enable = true;
            settings = {
              src = ./..;
              # The flake-parts module defaults to `self` (= `dev/` only).
              rootSrc = pkgs.lib.mkForce (pkgs.lib.cleanSource ./..);
              package = pkgs.prek;
              hooks = {
                # All formatters and linters from the `treefmt` block above.
                treefmt = {
                  enable = true;
                  package = config.treefmt.build.wrapper;
                };

                # Repository hygiene that no language formatter covers.
                check-added-large-files.enable = true;
                check-case-conflicts.enable = true;
                check-executables-have-shebangs.enable = true;
                check-merge-conflicts.enable = true;
                check-shebang-scripts-are-executable.enable = true;
                check-symlinks.enable = true;
                end-of-file-fixer.enable = true;
                mixed-line-endings.enable = true;
                trim-trailing-whitespace.enable = true;

                renovate-config-validator = {
                  enable = true;
                  entry = "${pkgs.lib.getExe' pkgs.renovate "renovate-config-validator"} --strict";
                  files = "renovate\\.json5?$";
                  language = "system";
                };

                # Commit time: staged changes only. The full working-tree scan
                # is the `gitleaks` check above, the history scan runs in
                # `.github/workflows/security.yaml`.
                gitleaks = {
                  enable = true;
                  name = "gitleaks";
                  entry = "${pkgs.lib.getExe pkgs.gitleaks} git --staged --no-banner --redact --config ${gitleaksConfig}";
                  language = "system";
                  pass_filenames = false;
                };
              };
            };
          };

          packages = {
            inherit (pkgs) typos typos-lsp;
          };

          devShells.default = pkgs.mkShellNoCC {
            inherit (config.pre-commit) shellHook;
            packages = [
              # `prek run --all-files` runs every hook by hand.
              config.pre-commit.settings.package
              config.packages.typos
              config.packages.typos-lsp
              pkgs.gitleaks
            ];
          };
        };
    };
}
