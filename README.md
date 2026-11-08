# claude-box

Unattended NixOS host that runs Claude Code on a Zotac ZBOX CI323 nano,
reachable from a Mac over SSH and updated without manual work.

- **`box/`** – the host: NixOS configuration, self-testing upgrades, CI gate,
  install scripts. Start with [`box/README.md`](box/README.md).
- **Repository root** – the Claude Code package: `update.nu` (hourly via
  `update.yaml`) fetches new releases with SHA256 checksums directly from
  Anthropic's distribution server into `versions/`; `package.nix` wraps the
  binary. `box.yaml` keeps only the newest 20 versions.

## Formatting, linting and pre-commit hooks

`dev/flake.nix` defines one hook set that runs on every `git commit` and, via
`nix flake check` in `dev/`, in CI (`check.yaml`). Install the hooks once:

```bash
direnv allow   # or: nix develop ./dev
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
dev shell.

Package flake derived from [ryoppippi/nix-claude-code](https://github.com/ryoppippi/nix-claude-code) (MIT).
Claude Code itself is unfree software by Anthropic.
