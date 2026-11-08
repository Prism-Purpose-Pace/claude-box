# claude-box

Unattended NixOS host for Claude Code on a Zotac ZBOX CI323 nano
(Celeron N3150, no AVX, 8 GB RAM, 128 GB SATA SSD).

Everything outside `box/` is the upstream package flake (`ryoppippi/nix-claude-code`)
and stays mergeable.

## How it stays maintenance-free

```
upstream update.yaml (hourly) ── new versions/*.json + stable marker
            │
box.yaml (every 6 h, Monday also flake inputs)
   ├─ promote `stable` → box/claude-version only if a full headless turn
   │  succeeds on QEMU -cpu Westmere (no AVX, same ISA class as the N3150)
   ├─ build the whole system + run the NixOS VM test
   └─ commit to main
            │
claude-box-upgrade.timer (daily ~04:30, catches up after downtime)
   ├─ build main from GitHub (binaries from cache.nixos.org)
   ├─ smoke-test the NEW Claude Code on the REAL CPU (local mock API, no tokens)
   ├─ switch; on failure roll back to the previous generation
   └─ reboot only if the kernel changed
```

A version that fails either gate is never activated; the box keeps the last good one.
The last 10 generations stay in the boot menu as a manual fallback.

## Layout

| Path | Purpose |
|---|---|
| `flake.nix` | host + `claude`, `smoke-test`, `toplevel` packages, VM test, Mac dev shell |
| `claude-version` | Claude Code version deployed to the box (written by CI) |
| `claude-rejected` | last version that failed the non-AVX gate (written by CI) |
| `hosts/claude-box/` | hardware, disk layout, SSH keys, host settings |
| `modules/` | base system, Claude user, self-testing upgrades, remote access |
| `pkgs/` | smoke test + mock Messages API |
| `scripts/` | `bootstrap.sh`, `install.sh` (run on the Mac) |
| `secrets/secrets.yaml` | sops-encrypted to the box's SSH host key |

## First install

Prerequisites: Nix on the Mac, the ZBOX booted from the NixOS minimal ISO with
`passwd` set for root, its IP from `ip a`, and the GitHub Actions of this fork enabled.

```sh
git clone git@github.com:philippsied/nix-claude-box.git && cd nix-claude-box
nix develop ./box --command ./box/scripts/bootstrap.sh       # asks for `claude setup-token` output
nix develop ./box --command ./box/scripts/install.sh <IP>    # wipes /dev/sda after confirmation
```

`install.sh` ends by checking `claude --version`, the smoke test, a real prompt
and the upgrade timer, then deletes the box's private host key from the Mac.

## Daily use

```sh
ssh claude-box                       # user claude, key from the macOS Keychain
tmux new -A -s work                  # sessions survive disconnects
ssh claude-box claude -p "…"         # one-shot headless task
ssh claude-box-admin                 # sudo, for maintenance
```

## Occasional tasks

| Task | How |
|---|---|
| Rotate the Claude token (setup tokens expire) | `bootstrap.sh --secrets` |
| Enable NetBird | `bootstrap.sh --secrets` with a setup key, then `remoteAccess = "netbird"` in `hosts/claude-box/configuration.nix` |
| Upgrade now | `ssh claude-box-admin sudo systemctl start claude-box-upgrade` |
| See upgrade history | `ssh claude-box-admin cat /var/lib/claude-box/history` |
| Roll back | `ssh claude-box-admin sudo nixos-rebuild switch --rollback`, or pick a generation in the boot menu |
| Pull upstream changes | GitHub "Sync fork"; `box/` never conflicts |
