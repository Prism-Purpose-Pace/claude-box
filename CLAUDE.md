# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Two things in one repository, each with its own flake:

1. **Repository root**: a Nix package for the Claude Code binary (derived from ryoppippi/nix-claude-code). `update.nu` downloads release metadata from Anthropic's GCS distribution bucket into `versions/<ver>.json` (URL + SRI hash per platform) and writes the `stable` channel marker. `flake.nix` exposes `claude`/`latest` (newest file in `versions/`), `stable` (from the `stable` marker), `*-minimal`, `*-fhs` (Linux only), one package per version, and `overlays.default`.
2. **`box/`**: an unattended NixOS host (Zotac ZBOX CI323, Celeron N3150, **no AVX**) that runs Claude Code and upgrades itself from `main`. Its flake imports `../package.nix` and `../package-fhs.nix` directly; it does **not** consume the root flake. Human docs: `box/README.md` (update flow, operations) and `box/SETUP.md` (first install).

`dev/` is a third flake that holds only tooling: treefmt, gitleaks and the pre-commit hooks (installed by the dev shell: `direnv allow` via `.envrc`, or `nix develop ./dev`). It reads the whole repository through `./..`. User-facing hook docs: root `README.md`.

## Commands

```bash
nix build -L                          # root package (latest version)
nix run . -- --version                # what CI checks: "<x.y.z> (Claude Code)"
nix build .#stable                    # also .#claude-fhs; a pinned version needs quoting: '.#"2.1.319"'
cd dev && nix flake check -L          # what CI's `check` job runs: every pre-commit hook on all files + full gitleaks scan
prek run --all-files                  # same hooks by hand, inside the dev shell (rewrites files)
./update.nu                           # fetch new releases into versions/ (normally run by CI, hourly)

nix build -L ./box#toplevel                    # full host system closure
nix build -L ./box#checks.x86_64-linux.vm      # NixOS VM test (box/tests/vm.nix), needs KVM
nix build ./box#claude ./box#smoke-test        # the box's Claude package and the smoke test
nix build ./box#installer-iso
```

Non-AVX smoke test as CI runs it:

```bash
qemu=$(nix build --no-link --print-out-paths --inputs-from ./box nixpkgs#qemu-user)
SMOKE_PREFIX="$qemu/bin/qemu-x86_64 -cpu Westmere" \
  "$(nix build --no-link --print-out-paths ./box#smoke-test)/bin/claude-smoke-test" \
  "$(nix build --no-link --print-out-paths ./box#claude)/bin/.claude-wrapped"
```

## Files written by CI, not by hand

- `versions/*.json` and `stable`: written by `update.yaml` (hourly, via `update.nu`). `box.yaml` prunes `versions/` to the newest 20, plus whatever `stable` and `box/claude-version` reference; `update.nu` backfills only inside that window (`KEEP_VERSIONS`, keep both at the same value). `versions/unavailable.txt` lists versions whose GCS manifest returned 404 (with the date), so they are not requested every hour; entries older than 30 days are retried. Never delete a version file that `stable` or `box/claude-version` points to: flake evaluation would fail.
- `box/claude-version` / `box/claude-rejected`: `box.yaml` promotes `stable` into `claude-version` only after the smoke test passes under QEMU `-cpu Westmere`; a failing candidate goes into `claude-rejected` and is then skipped.
- `box/flake.lock`: updated weekly by `box.yaml`. `release.yaml` (workflow name `nixos-release`) bumps the `nixos-YY.MM` channel URL in `box/flake.nix` to the next release once it exists. `system.stateVersion` is intentionally never changed.
- `box/security/known-critical.txt`: appended by the weekly grype scan in `security.yaml`. The scan fails only on critical findings that are not already listed.

All of these workflows commit straight to `main`.

## Box architecture (the parts that span files)

- **Package path**: `box/flake.nix` reads `box/claude-version` and builds an overlay with `claude-code-box` (from `../package.nix` with that version's JSON) and `claude-code-box-fhs`. `modules/claude.nix` wraps the FHS variant in a `claude` script that loads `CLAUDE_CODE_OAUTH_TOKEN` from the sops secret `/run/secrets/claude_oauth_token`. The FHS wrapper is needed because agent teams download helper binaries that expect `/lib64/ld-linux-x86-64.so.2`. It also puts `bubblewrap` and `socat` in its `/usr/bin` for Claude Code's `/sandbox`.
- **Two gates against AVX regressions**: (1) the CI QEMU gate in `box.yaml`, which is only an early warning; (2) `modules/auto-upgrade.nix` on the real box, which builds `github:Prism-Purpose-Pace/claude-box?dir=box`, runs `claude-smoke-test` against `$new/claude-code/bin/claude`, then switches, rolls back if the switch fails, and reboots only if the kernel/initrd changed. The `$out/claude-code` symlink in the system closure exists so that the gate tests the exact binary that will be deployed. Keep it if you refactor.
- **Smoke test** (`box/pkgs/smoke-test.nix` + `mock-anthropic-api.py`): runs one full `claude -p` turn against a local mock Messages API, with no token or network. It passes only if the output contains `GATE-OK`. Exit codes matter: 1 = Claude Code failed (CI writes `claude-rejected`, the box logs `REJECTED`), 2 = the harness failed (no rejection; CI fails the run, the box logs `SKIPPED` and retries next run).
- **Options** live under the `box.*` namespace: `sshKeys` and `hasSecrets` in `modules/base.nix`, `remoteAccess` (`"none"` | `"netbird"`), `upgrade.flake`/`upgrade.schedule`, and notify settings. `box.hasSecrets` depends on whether `box/secrets/secrets.yaml` exists. That file is created on the Mac by `scripts/bootstrap.sh` and encrypted to the box's SSH host key. Modules must stay evaluable without it (CI and the VM test have no secrets), so gate `sops.secrets.*` with `lib.mkIf config.box.hasSecrets`.
- **Notifications**: a failed systemd unit triggers an ntfy push (`modules/notify.nix`). The VM test checks this end to end with a fake ntfy server, so keep that path working when you change upgrade or notify units.
- **User config and herdr**: `modules/claude.nix` copies `box/home/claude/` (Claude Code `settings.json`, `settings.local.json`, the statusline script and herdr's Claude hook, herdr `config.toml`) into `/home/claude` on activation, only for files that do not exist yet. herdr comes from the `herdr` flake input, pinned to a release tag and compiled on the box (not in cache.nixos.org); the upgrade gate also checks that `herdr --version` runs. Plugins are installed by hand with `claude-box-herdr-plugins` so herdr's trust preview is never skipped. `.claude/hooks/herdr-agent-state.sh` is generated by herdr (its header says so); refresh the copy when herdr's integration version changes.
- **Users**: `claude` (no sudo) and `admin` (wheel, passwordless sudo). SSH keys only, root login disabled. The VM test asserts these properties.

## Conventions

- **Every change must pass the pre-commit hooks** (`dev/flake.nix`); formatters rewrite files, linters block. Do not disable a hook or add an ignore comment (ruff `noqa`, shellcheck `disable=`) without saying why next to it.
  - Nix: nixfmt, statix, deadnix, nixf-diagnose.
  - Python: ruff format + `ruff check` (`ruff.toml`).
  - Shell (`*.sh`, `.envrc`): bash with `set -euo pipefail`, shfmt (style from `.editorconfig`: 2 spaces, `||`/`&&` at the start of continuation lines), shellcheck.
  - Workflows: actionlint (with shellcheck on `run:` blocks), zizmor offline.
  - JSON/YAML/Markdown: oxfmt (`.oxfmtrc.jsonc`: tabs, single quotes). TOML: taplo. `update.nu`: nufmt. Everything: typos, whitespace/EOF, merge markers, shebang/executable bit, large files, gitleaks on staged changes.
- GitHub Actions are pinned to commit SHAs with a version comment, use `persist-credentials: false`, and set least-privilege `permissions:`. zizmor (`--min-severity low`) blocks CI otherwise; config is in `.github/zizmor.yml`.
- A push to `main` is root on the box within a day. In `box.yaml` the `gate` job (Nix builds, third-party actions, also runs on same-repository PRs) is read-only and hands a patch to the `commit` job, the only one with `contents: write`. Keep that split, and keep Renovate from auto-merging GitHub Actions updates.
- `install.sh` never sends anything to the installer over an unverified connection: `installer_connect` (`box/scripts/lib.sh`) pins the host key after the user compares its fingerprint with the installer console, and nixos-anywhere runs over that master connection (`ControlPath`), because its own `StrictHostKeyChecking=no` cannot be overridden.
- The unfree allowance is limited to the package name `claude` (`allowUnfreePredicate`). The overlay instead relies on the consumer's own nixpkgs config.
- Commit messages: a prefix for the area (`box:`, `dev:`, `docs:`, `chore:`), imperative summary, body that says why.

## Verification by change type

| Change                          | Run                                                                       |
| ------------------------------- | ------------------------------------------------------------------------- |
| any file                        | `prek run --all-files` (or `cd dev && nix flake check -L`)                |
| root package (`package*.nix`)   | `nix build -L && nix run . -- --version`                                  |
| `box/` NixOS modules or `pkgs/` | `nix build -L ./box#toplevel`, then the VM test                           |
| smoke test / mock API           | the non-AVX smoke test above                                              |
| workflows                       | hooks (actionlint, zizmor offline); online zizmor runs in `security.yaml` |
| docs                            | hooks (oxfmt, typos); keep README tables in sync with the code            |

Mac-side scripts (`box/scripts/*.sh`) are interactive and touch real hardware, keys and GitHub settings: do not run them yourself.

## Gotchas

- Flakes only see files tracked by Git. Run `git add -N <file>` on new files before any `nix` command, or they are silently missing.
- The pre-commit flake check sets `rootSrc` to the whole repository; the flake-parts default would only check `dev/`.
- `box/secrets/` is excluded from every rewriting hook: `bootstrap.sh` commits sops output there, and a reformat would abort that commit. gitleaks still scans it.
- zizmor runs offline in the hooks (no network in the Nix sandbox). Online audits such as impostor commits run only in `security.yaml`. The `self-repository` rule is disabled in `.github/zizmor.yml` until actionlint understands the `$/` syntax.
- `box/SETUP.md` marks hardware steps that were never tested on the real box as _(unverified)_. Keep that marker unless someone confirms the step.
