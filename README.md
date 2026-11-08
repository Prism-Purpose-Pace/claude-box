# claude-box

Unattended NixOS host that runs Claude Code on a Zotac ZBOX CI323 nano,
reachable from a Mac over SSH and updated without manual work.

- **`box/`** – the host: NixOS configuration, self-testing upgrades, CI gate,
  install scripts. Start with [`box/README.md`](box/README.md).
- **Repository root** – the Claude Code package: `update.nu` (hourly via
  `update.yaml`) fetches new releases with SHA256 checksums directly from
  Anthropic's distribution server into `versions/`; `package.nix` wraps the
  binary. `box.yaml` keeps only the newest 20 versions.

Package flake derived from [ryoppippi/nix-claude-code](https://github.com/ryoppippi/nix-claude-code) (MIT).
Claude Code itself is unfree software by Anthropic.
