# CLAUDE.md

Guide for agents working in this repository. User-facing docs: `README.md`,
`box/README.md`, `box/SETUP.md`.

## What this repository is

Two parts that share one Git history:

- **Repository root**: a Nix flake that packages the Claude Code binary
  (`package.nix`, `package-fhs.nix`, `flake.nix`, `default.nix`). `update.nu`
  writes one `versions/<version>.json` per release plus the `stable` marker.
  Derived from ryoppippi/nix-claude-code.
- **`box/`**: a separate flake with the NixOS configuration of the claude-box
  host (Zotac ZBOX CI323 nano, Celeron N3150, **x86_64 without AVX**). It also
  holds the smoke test, VM test, installer ISO and the Mac install scripts.
- **`dev/`**: a third flake for the dev shell, treefmt and pre-commit hooks.
  It reads the whole repository through `./..`.

## Commands

```bash
direnv allow                         # or `nix develop ./dev`: dev shell, installs the git hooks
prek run --all-files                 # all hooks on all files (inside the dev shell)
cd dev && nix flake check -L         # what CI's `check` job runs: hooks + gitleaks
nix build -L                         # Claude Code package (root flake)
nix build -L ./box#toplevel          # whole box system (x86_64-linux)
nix build -L ./box#checks.x86_64-linux.vm   # NixOS VM test (needs KVM)
```

Mac-side scripts run inside the box dev shell, e.g.
`nix develop ./box --command ./box/scripts/setup.sh`. They are interactive and
touch real hardware, keys and GitHub settings: do not run them yourself.

## Rules

- **Every change must pass the hooks.** Formatters fix files in place; linters
  block. Do not disable a hook or add an ignore comment (ruff `noqa`,
  shellcheck `disable=`) without saying why next to it.
- **Files written by CI, do not edit by hand**: `versions/*.json`, `stable`,
  `box/claude-version`, `box/claude-rejected`, `box/security/known-critical.txt`.
  `flake.lock` files are updated by CI and Renovate; change them only on
  purpose.
- **Secrets**: never commit plaintext. `box/secrets/secrets.yaml` is
  sops-encrypted by `box/scripts/bootstrap.sh`; `box/secrets/*.plain` is
  gitignored. gitleaks runs on commit, in `nix flake check` and on the full
  history in CI.
- **GitHub Actions**: pin actions to a full commit SHA with a `# vX.Y.Z`
  comment, keep `permissions` minimal per job, set
  `persist-credentials: false` on checkout, use `ubuntu-24.04` runners.
  actionlint and zizmor enforce most of this.
- **Shell scripts**: bash with `set -euo pipefail`; style comes from
  `.editorconfig` (2 spaces, `||`/`&&` at the start of continuation lines).
- **Python**: ruff, configured in `ruff.toml`.
- **The box has no AVX.** Anything that runs on it must work on the N3150;
  `box/pkgs/smoke-test.nix` and the CI gate in `box.yaml` exist for this.
- **Commit messages**: a prefix for the area (`box:`, `dev:`, `chore:`),
  imperative summary, body that says why.

## Verification by change type

| Change                           | Run                                                                       |
| -------------------------------- | ------------------------------------------------------------------------- |
| any file                         | `prek run --all-files` (or `cd dev && nix flake check -L`)                |
| root package (`package*.nix`)    | `nix build -L && nix run . -- --version`                                  |
| `box/` NixOS modules or `pkgs/`  | `nix build -L ./box#toplevel`, then the VM test                           |
| `box/pkgs/mock-anthropic-api.py` | start it with a port and `curl -X POST localhost:<port>/v1/messages`      |
| workflows                        | hooks (actionlint, zizmor offline); online zizmor runs in `security.yaml` |
| docs                             | hooks (oxfmt, typos); keep README tables in sync with the code            |

## Gotchas

- Flakes only see files tracked by Git. Run `git add -N <file>` on new files
  before any `nix` command, or they are silently missing.
- The pre-commit flake check sets `rootSrc` to the whole repository; the
  flake-parts default would only check `dev/`.
- zizmor runs offline in the hooks (no network in the Nix sandbox). Online
  audits such as impostor commits run only in `security.yaml`.
- The zizmor `self-repository` rule is disabled in `.github/zizmor.yml` until
  actionlint understands the `$/` syntax.
- `box/secrets/` is excluded from every rewriting hook: `bootstrap.sh` commits
  sops output there, and a reformat would abort that commit. gitleaks still
  scans it.
- `box/SETUP.md` marks hardware steps that were never tested on the real box
  as _(unverified)_. Keep that marker unless someone confirms the step.
