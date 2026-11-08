# claude-box

Unattended NixOS host for Claude Code on a Zotac ZBOX CI323 nano
(Celeron N3150, **no AVX**, 8 GB RAM, 128 GB SATA SSD). You reach it from the
Mac over SSH; it updates itself from this repository.

## How updates flow

```
update.yaml (hourly)      new Claude Code releases → versions/*.json, `stable` marker
        │
box.yaml (every 6 h; Mondays also nixpkgs/disko/sops-nix)
   ├─ candidate = `stable`; full headless turn on QEMU -cpu Westmere (no AVX)
   │    pass → box/claude-version      fail → box/claude-rejected + mail
   ├─ build the whole system, run the NixOS VM test
   ├─ prune versions/ to the newest 20
   └─ commit to main
nixos-release.yaml (Tuesdays)  next NixOS release (YY.05/YY.11) once out: build + VM test → commit
installer.yaml (monthly / on change)  installer ISO → GitHub release "installer"
        │
claude-box-upgrade.timer (daily ~04:30, catches up after downtime)
   ├─ build main from GitHub (binaries from cache.nixos.org)
   ├─ smoke test of the NEW Claude Code on the REAL N3150 (local mock API, no tokens)
   ├─ switch; if switching fails, roll back to the previous generation
   └─ reboot only if the kernel changed
claude-box-token-check.timer (monthly)  one real prompt with the stored token

failures on the box → ntfy push to your phone; failures in CI → GitHub mail
```

**What the two gates can and cannot do.** The CI gate is an early warning:
QEMU does reject AVX instructions, but historic non-AVX crashes (e.g. 2.1.15)
did not reproduce under it. The authoritative check is the smoke test on the
box itself; a version that fails it is never activated. Neither gate catches
problems that only appear later at runtime; for those, roll back (see below).

## Layout

| Path                                        | Purpose                                                                            |
| ------------------------------------------- | ---------------------------------------------------------------------------------- |
| `../package.nix`, `../package-fhs.nix`      | Claude Code binary wrapper; FHS variant used on the box (agent teams)              |
| `../update.nu`, `../versions/`, `../stable` | release tracking, fed by `update.yaml`                                             |
| `flake.nix`                                 | host config, packages `claude` / `smoke-test` / `toplevel`, VM test, Mac dev shell |
| `claude-version` / `claude-rejected`        | deployed version / last version rejected by CI (both written by CI)                |
| `hosts/claude-box/`                         | hardware, disk layout, SSH keys, host settings                                     |
| `modules/`                                  | base system, `claude` user, self-testing upgrades, remote access, notifications    |
| `installer/`                                | installer ISO (your key preset, `claude-installer.local`)                          |
| `pkgs/`                                     | smoke test + mock Messages API                                                     |
| `tests/vm.nix`                              | VM test run by CI                                                                  |
| `scripts/`                                  | Mac: `setup.sh` (= `bootstrap.sh` + `install.sh`), `flash-usb.sh`, `repo-setup.sh` |
| `secrets/secrets.yaml`                      | sops-encrypted to the box's SSH host key, created by `bootstrap.sh`                |

## First install

Step by step, with BIOS settings and troubleshooting: **[SETUP.md](SETUP.md)**. In short:

```sh
nix develop ./box --command ./box/scripts/repo-setup.sh   # GitHub settings, once
./box/scripts/flash-usb.sh                                # installer onto a USB stick
nix develop ./box --command ./box/scripts/setup.sh        # secrets, wait for the box, install, verify
```

## Daily use

```sh
ssh claude-box                       # user claude (no sudo), key from the Keychain
tmux new -A -s work                  # long tasks survive disconnects
ssh claude-box claude -p "…"         # one-shot headless task
ssh claude-box-admin                 # user admin (sudo), maintenance only
```

The box is found as `claude-box.local` (mDNS), so DHCP address changes do not matter.

## Occasional tasks

| Task                        | How                                                                                                                |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| Rotate the Claude token     | `bootstrap.sh --secrets`; the box picks it up with its next upgrade (or "Upgrade now")                             |
| Enable NetBird              | `bootstrap.sh --secrets` with a setup key, then `remoteAccess = "netbird"` in `hosts/claude-box/configuration.nix` |
| Upgrade now                 | `ssh claude-box-admin sudo systemctl start claude-box-upgrade`                                                     |
| Why was an upgrade skipped? | `ssh claude-box-admin cat /var/lib/claude-box/history`, `journalctl -u claude-box-upgrade`                         |
| Roll back                   | `ssh claude-box-admin sudo nixos-rebuild switch --rollback`, or pick a generation in the boot menu (last 10 kept)  |
| Test notifications          | `ssh claude-box-admin claude-box-notify "claude-box" "test"`                                                       |
| Box not reachable           | it is probably off or the Mac is outside the LAN; after a power cut it restarts by itself (BIOS setting)           |

## Security model

- SSH keys only; no passwords exist on the system, root login is disabled.
- `claude` has no sudo. `admin` has passwordless sudo, protected by the SSH key.
- Secrets are decrypted on the box with its SSH host key; only ciphertext is in Git.
- The box pulls; nothing pushes to it, and no inbound port besides SSH (LAN) is open.

## Security checks (`.github/workflows/security.yaml`)

| Check                                                              | When            | Effect                                                                                                                 |
| ------------------------------------------------------------------ | --------------- | ---------------------------------------------------------------------------------------------------------------------- |
| gitleaks (secrets in Git history)                                  | every push / PR | blocks                                                                                                                 |
| zizmor (insecure workflow patterns, `.github/zizmor.yml`)          | every push / PR | blocks                                                                                                                 |
| sbomnix SBOM (CycloneDX + SPDX) + grype CVE scan of the box system | Sundays         | report artifact; fails (mail) only on a **new** critical finding, which is then added to `security/known-critical.txt` |

grype matches by version number and cannot see fixes that nixpkgs backports as
patches, so check a finding against the nixpkgs package before acting. Real fixes
arrive with the weekly flake update in `box.yaml`.
