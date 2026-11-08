# shellcheck shell=bash disable=SC2034
# Shared helpers for the Mac-side scripts. Source it, do not run it.

# owner/repo of the `origin` remote. Takes the last two path components, so
# git@github.com:o/r, ssh://git@github.com/o/r, https://github.com/o/r and
# SSH host aliases (alias:o/r) all work.
repo_slug() {
  git remote get-url origin | sed -E 's#/+$##; s#\.git$##; s#.*[:/]([^/:]+/[^/:]+)$#\1#'
}

# ssh options for the installer: its host key changes with every boot.
installer_ssh_opts=(-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o LogLevel=ERROR)

# Defaults shared by setup.sh, bootstrap.sh and install.sh.
# SSH key of the Mac that is authorized on the box and the installer.
key="${CLAUDE_BOX_SSH_KEY:-$HOME/.ssh/id_ed25519_claude-box_zodiac}"
# Private host key tree, copied onto the box by install.sh, then deleted.
keydir="${CLAUDE_BOX_KEYDIR:-$HOME/.config/claude-box/install-root}"
hostkey="$keydir/etc/ssh/ssh_host_ed25519_key"
# Committed public half (relative to box/).
pubkey="hosts/claude-box/ssh_host_ed25519_key.pub"
