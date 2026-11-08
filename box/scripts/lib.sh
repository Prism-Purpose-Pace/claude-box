# shellcheck shell=bash disable=SC2034
# Shared helpers for the Mac-side scripts. Source it, do not run it.

# owner/repo of the `origin` remote. Takes the last two path components, so
# git@github.com:o/r, ssh://git@github.com/o/r, https://github.com/o/r and
# SSH host aliases (alias:o/r) all work.
repo_slug() {
  git remote get-url origin | sed -E 's#/+$##; s#\.git$##; s#.*[:/]([^/:]+/[^/:]+)$#\1#'
}

# Defaults shared by setup.sh, bootstrap.sh and install.sh.
# SSH key of the Mac that is authorized on the box and the installer.
key="${CLAUDE_BOX_SSH_KEY:-$HOME/.ssh/id_ed25519_claude-box_zodiac}"
# Private host key tree, copied onto the box by install.sh, then deleted.
keydir="${CLAUDE_BOX_KEYDIR:-$HOME/.config/claude-box/install-root}"
hostkey="$keydir/etc/ssh/ssh_host_ed25519_key"
# Committed public half (relative to box/).
pubkey="hosts/claude-box/ssh_host_ed25519_key.pub"

# Only for probing whether the installer is up: it gets a new host key on every
# boot, which these options do not check. Never send anything secret with them.
installer_probe_opts=(-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o LogLevel=ERROR)

# installer_connect <host> <identity-file>
# Reads the installer's host key, has the user compare its fingerprint with the
# one on the installer's screen, and opens a master connection that accepts
# exactly that key. Sets installer_ssh (options for ssh) and installer_mux
# (-o ControlPath=...): every later ssh and nixos-anywhere call passes it and so
# runs over the verified connection. That is the only way for nixos-anywhere:
# it passes StrictHostKeyChecking=no itself, and ssh keeps the first value of
# each option, so --ssh-option cannot turn checking back on; ControlPath it
# does not set. Otherwise anyone on the LAN answering mDNS for the installer
# would receive the box's private host key, which decrypts secrets.yaml.
installer_connect() {
  local host=$1 identity=$2 kh fp answer
  installer_dir=$(mktemp -d)
  kh="$installer_dir/known_hosts"
  ssh-keyscan -T 10 -t ed25519 "$host" 2>/dev/null \
    | awk '!/^#/ && NF >= 3 { print "claude-installer", $2, $3; exit }' >"$kh"
  [ -s "$kh" ] || {
    echo "Could not read the SSH host key of $host." >&2
    return 1
  }
  fp=$(ssh-keygen -lf "$kh" | awk '{ print $2 }')
  cat <<TXT
SSH host key of $host:
    $fp
It must match the fingerprint on the installer's screen (our ISO shows it after
boot; on the stock NixOS ISO run: ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub).
A different value means another machine answered - do not continue.
TXT
  read -r -p "Does it match exactly? Type yes: " answer
  [ "$answer" = yes ] || {
    echo "Host key not confirmed - aborting, nothing was sent." >&2
    return 1
  }

  installer_mux=(-o ControlPath="$installer_dir/mux")
  installer_ssh=(-i "$identity" "${installer_mux[@]}" -o UserKnownHostsFile="$kh"
    -o HostKeyAlias=claude-installer -o StrictHostKeyChecking=yes -o LogLevel=ERROR)
  local master=(-o ControlMaster=yes -o ControlPersist=yes -o ConnectTimeout=10 -fN)
  if ssh "${installer_ssh[@]}" "${master[@]}" -o BatchMode=yes "root@$host" 2>/dev/null; then
    echo "==> Installer accepts your key"
  else
    # Stock ISO: only the root password set with `passwd` there.
    echo "==> Authorising your key on the installer (enter the password you set with 'passwd')"
    # shellcheck disable=SC2029 # host argument, not a remote command
    ssh "${installer_ssh[@]}" "${master[@]}" "root@$host"
    ssh "${installer_ssh[@]}" "root@$host" \
      'umask 077; mkdir -p ~/.ssh; cat >> ~/.ssh/authorized_keys' <"$identity.pub"
  fi
}

# Closes the master connection of installer_connect and removes its files.
installer_disconnect() {
  [ -n "${installer_dir:-}" ] || return 0
  ssh "${installer_mux[@]}" -O exit claude-installer 2>/dev/null || true
  rm -rf "$installer_dir"
  installer_dir=""
}
