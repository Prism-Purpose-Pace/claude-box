# claude-box

Unattended NixOS host that runs Claude Code on a Zotac ZBOX CI323 nano,
reachable from a Mac over SSH and updated without manual work.

- **`box/`** – the host: NixOS configuration, self-testing upgrades, CI gate,
  install scripts. Start with [`box/README.md`](box/README.md).
- **Repository root** – the Claude Code package: `update.nu` (hourly via
  `update.yaml`) fetches new releases with SHA256 checksums directly from
  Anthropic's distribution server into `versions/`; `package.nix` wraps the
  binary. `box.yaml` keeps only the newest 20 versions.

Agents working in this repository: see [`CLAUDE.md`](CLAUDE.md).

## Using the package

```bash
nix run github:Prism-Purpose-Pace/claude-box            # latest release
nix run github:Prism-Purpose-Pace/claude-box#stable     # upstream `stable` channel
```

| Output                                 | Contents                                                                                   |
| -------------------------------------- | ------------------------------------------------------------------------------------------ |
| `claude` (default), `latest`, `stable` | Claude Code with `gh` and `pdftotext` on `PATH`                                            |
| `claude-minimal`, `stable-minimal`     | the binary only                                                                            |
| `*-fhs` (Linux)                        | FHS wrapper for agent teams and `/sandbox` (bubblewrap, socat)                             |
| `<version>`, e.g. `2.1.319`            | one of the archived versions in `versions/`                                                |
| `overlays.default`                     | `claude-code`, `claude-code-minimal`, `claude-code-fhs`, `claude-code-minimal-fhs` (Linux) |

The packages of this flake allow the unfree `claude` package themselves. The
overlay builds from your own nixpkgs, so permit it there:

```nix
nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "claude" ];
```

## Contributing: formatting, linting and pre-commit hooks

`dev/flake.nix` defines one hook set that runs on every `git commit` and, via
`nix flake check` in `dev/`, in CI (`check.yaml`).

Prerequisites: Nix with flakes enabled (the
[Determinate installer](https://install.determinate.systems) enables them) and,
optionally, [direnv](https://direnv.net) with nix-direnv. Install the hooks
once per clone:

```bash
direnv allow
```

Without direnv, enter the dev shell instead; it installs the same hooks:

```bash
nix develop ./dev
```

| Files                          | Formatters (auto-fix)                   | Linters (block the commit)                                                             |
| ------------------------------ | --------------------------------------- | -------------------------------------------------------------------------------------- |
| `*.nix`                        | nixfmt, statix, deadnix, nixf-diagnose  | statix, deadnix, nixf-diagnose                                                         |
| `*.py`                         | ruff format, `ruff check --fix`         | ruff (`ruff.toml`)                                                                     |
| `*.sh`, `.envrc`               | shfmt (`.editorconfig`)                 | shellcheck                                                                             |
| `.github/workflows`, `actions` | –                                       | actionlint (+ shellcheck), zizmor                                                      |
| Markdown, YAML, JSON(5)        | oxfmt                                   | –                                                                                      |
| TOML / `*.nu`                  | taplo / nufmt                           | –                                                                                      |
| everything                     | typos, end-of-file, trailing whitespace | gitleaks (staged), large files, merge markers, shebang/executable bit, Renovate config |

A commit whose files were rewritten aborts; review the changes, `git add` them
and commit again. Run all hooks by hand with `prek run --all-files` inside the
dev shell, or reproduce the CI check with `cd dev && nix flake check -L`. New
files must be tracked (`git add`) before Nix sees them. `box/secrets/` (sops
output) is never rewritten, only scanned by gitleaks.

| Workflow        | When                                                  | Does                                                       |
| --------------- | ----------------------------------------------------- | ---------------------------------------------------------- |
| `check.yaml`    | push to main, PR                                      | all hooks + gitleaks; build and `--version` on Linux/macOS |
| `security.yaml` | push to main, PR, Sundays                             | gitleaks on history, zizmor online; weekly SBOM + CVE scan |
| `update.yaml`   | hourly                                                | new Claude Code releases into `versions/`                  |
| box workflows   | see [`box/README.md`](box/README.md#how-updates-flow) | gate, NixOS release, installer ISO                         |

Package flake derived from [ryoppippi/nix-claude-code](https://github.com/ryoppippi/nix-claude-code) (MIT).
Claude Code itself is unfree software by Anthropic.
