# claude-box backlog

Open work that is not done yet. Issues are disabled in this repository, so
pending work is tracked here. Remove an entry in the change that resolves it.

## 1. Verify PR #2 on the real box

PR #2 (sandbox tools, herdr, user config, containment M1-M5) passed CI, but
the real N3150 has not run it yet. Owner steps, in this order:

- [ ] Upgrade; the first run compiles herdr on the N3150 and takes a while:
      `ssh claude-box-admin sudo systemctl start claude-box-upgrade`
- [ ] The last line of `ssh claude-box-admin tail -1 /var/lib/claude-box/history`
      is `OK`, not `REJECTED (herdr does not start)` or `ROLLBACK`. Otherwise
      keep `journalctl -u claude-box-upgrade -n 80`.
- [ ] Only after `OK`, remove the hand-installed duplicates:
      `ssh claude-box nix profile remove herdr bubblewrap socat`
- [ ] `ssh claude-box 'readlink -f "$(command -v herdr)"; herdr --version; nix profile list | grep -c Name; systemctl is-active claude-seed-home'`
      prints a `/nix/store/…` path, a version, `0` and `active`.
- [ ] `/sandbox` in Claude Code shows bubblewrap and socat as found.
- [ ] Containment: `claude` cannot reach the LAN (for example
      `ssh claude-box curl -m 5 http://<router-ip>` fails), and
      `ssh claude-box-admin sudo ausearch --input-logs -i -k claude-exec --start today`
      shows entries.

## 2. Weekly flake update recompiles herdr on the box

`herdr` is pinned to a tag, but `box.yaml` (Mondays) and `release.yaml` run
`nix flake update --flake ./box`, which also moves herdr's own inputs
(`nixpkgs_2` = nixos-unstable, `rust-overlay`). herdr is not in
cache.nixos.org, so every weekly update makes the N3150 recompile Rust and
Zig. The "Update herdr" row in `README.md` and the comment in `flake.nix`
claim herdr only changes with the tag.

Proposed fix: update only the box's own inputs in both workflows
(`nix flake update --flake ./box nixpkgs disko sops-nix`) and update herdr
with its inputs when bumping the tag (`nix flake update --flake ./box herdr`).
Trade-off: herdr's build toolchain then only moves with herdr. Done when a
Monday run of `box.yaml` leaves the `herdr`, `nixpkgs_2` and `rust-overlay`
nodes of `flake.lock` unchanged.

## 3. Installer wait loop hides SSH errors

Seen during the first install (2026-11-08):

- `setup.sh` step 3/4 probes the installer with `ssh … 2>/dev/null` and
  prints only dots. The real cause was the owner's `~/.ssh/config`: an
  invalid `HostName` line, plus `UseKeychain`, which the nixpkgs OpenSSH of
  `nix develop ./box` rejects. Every probe failed for 30 minutes silently.
- `ssh-add --apple-use-keychain` in step 1 runs the nixpkgs `ssh-add`, which
  does not know the flag; `|| true` hides it, so a key with a passphrase never
  reaches the agent and the `BatchMode=yes` probes fail.
- The `claude -p` check in `install.sh` has no stdin and prints "no stdin
  data received in 3s".

Proposed fix: `-F /dev/null` for the installer connections in `setup.sh` and
`lib.sh` (they set every option themselves); print the last probe error when
the wait times out; call `/usr/bin/ssh-add --apple-use-keychain` on macOS;
`claude -p … </dev/null` in `install.sh`. Mac-side scripts: test by hand with
a deliberately broken `~/.ssh/config`.

## 4. `claude-box-notify` posts to an empty topic

`modules/notify.nix` builds the URL as `"${cfg.server}/$(< topicFile)"`. As
`admin` without sudo, `/run/secrets/ntfy_topic` (root, 0400) is unreadable,
the substitution is empty, and curl POSTs to `https://ntfy.sh/` (HTTP 400).
The docs now say to test with `sudo`; real notifications run as root and are
not affected.

Proposed fix: read the topic into a variable first and exit with a clear
message if it is unreadable or empty. Check in the VM test: as a non-root
user the command fails with that message and sends nothing to the fake ntfy
server, while the failure-notification assertion stays green.

## 5. Open decisions for development on the box

- Git access for `claude`: none yet. Options: fine-grained PAT limited to
  selected repositories (recommended), per-repository deploy keys, or
  `gh auth login` (all repositories). A token that must survive a reinstall
  belongs in `secrets.yaml` via `bootstrap.sh`. `SECURITY.md` forbids an
  identity on the box that can push to this repository.
- VS Code Remote-SSH and similar editor servers download generic Linux
  binaries and need `programs.nix-ld` (untested). Check against `SECURITY.md`
  first; the alternative is a Git-only workflow.
- herdr plugins are installed by hand with the trust preview; their commits
  are not pinned in the repository. Pin refs once herdr documents the syntax.
