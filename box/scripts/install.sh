#!/usr/bin/env bash
# Run on the Mac after bootstrap.sh (setup.sh does both), with the ZBOX booted
# from the claude-box installer ISO (or the stock NixOS minimal ISO):
#   nix develop ./box --command ./box/scripts/install.sh [host]
# host defaults to claude-installer.local (our ISO); for the stock ISO pass its IP.
#
# WIPES the internal SATA disk of the box and installs claude-box.
set -euo pipefail

ip="${1:-claude-installer.local}"
cd "$(git rev-parse --show-toplevel)/box"

key="${CLAUDE_BOX_SSH_KEY:-$HOME/.ssh/id_ed25519_claude-box_zodiac}"
keydir="${CLAUDE_BOX_KEYDIR:-$HOME/.config/claude-box/install-root}"
pubkey="hosts/claude-box/ssh_host_ed25519_key.pub"
min_disk=$((60 * 1000 * 1000 * 1000))

[ -f "$keydir/etc/ssh/ssh_host_ed25519_key" ] || { echo "No host key in $keydir - run bootstrap.sh first." >&2; exit 1; }
[ -f secrets/secrets.yaml ] || { echo "No secrets - run bootstrap.sh first." >&2; exit 1; }
if [ -n "$(git status --porcelain .)" ]; then
  echo "box/ has uncommitted changes - commit and push first, the box will pull from GitHub." >&2
  exit 1
fi
git fetch -q origin
if [ -n "$(git rev-list '@{u}..HEAD')" ]; then
  echo "Local commits are not pushed yet - run 'git push' first, the box will pull from GitHub." >&2
  exit 1
fi

installer_ssh=(-i "$key" -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o LogLevel=ERROR)

if ssh "${installer_ssh[@]}" -o BatchMode=yes -o ConnectTimeout=10 "root@$ip" true 2>/dev/null; then
  echo "==> Installer accepts your key"
else
  echo "==> Authorising your key on the installer (enter the password you set with 'passwd')"
  ssh-copy-id -i "$key.pub" "${installer_ssh[@]}" "root@$ip" >/dev/null
fi

echo "==> Checking the target disk"
disks=$(ssh "${installer_ssh[@]}" "root@$ip" lsblk -dnbo NAME,TRAN,RM,SIZE,MODEL)
echo "$disks"
read -r _ tran rm size model <<<"$(awk '$1=="sda"' <<<"$disks")"
if [ "${tran:-}" != "sata" ] || [ "${rm:-1}" != "0" ] || [ "${size:-0}" -lt "$min_disk" ]; then
  echo "/dev/sda is not the internal SATA disk - aborting, nothing was changed." >&2
  echo "Set disko.devices.disk.main.device in hosts/claude-box/disko.nix to the right disk." >&2
  exit 1
fi
echo
read -r -p "ERASE /dev/sda ($model, $((size / 1000000000)) GB) and install claude-box? Type YES: " answer
[ "$answer" = "YES" ] || exit 1

echo "==> Installing (builds on the box, takes a while on the N3150)"
nixos-anywhere \
  --flake ".#claude-box" \
  --build-on remote \
  --extra-files "$keydir" \
  -i "$key" \
  --ssh-option UserKnownHostsFile=/dev/null \
  --ssh-option StrictHostKeyChecking=no \
  --target-host "root@$ip"

echo "==> Trusting the box's host key"
ssh-keygen -R claude-box.local >/dev/null 2>&1 || true
echo "claude-box.local $(cut -d' ' -f1,2 "$pubkey")" >> "$HOME/.ssh/known_hosts"

if ! grep -q "^Host claude-box$" "$HOME/.ssh/config" 2>/dev/null; then
  cat >> "$HOME/.ssh/config" <<EOF

Host claude-box
  HostName claude-box.local
  User claude
  IdentityFile $key
  IdentitiesOnly yes
  UseKeychain yes
  AddKeysToAgent yes

Host claude-box-admin
  HostName claude-box.local
  User admin
  IdentityFile $key
  IdentitiesOnly yes
  UseKeychain yes
  AddKeysToAgent yes
EOF
  echo "Added Host claude-box / claude-box-admin to ~/.ssh/config"
fi

echo "==> Waiting for the box to come back"
for _ in $(seq 60); do
  ssh -o BatchMode=yes -o ConnectTimeout=5 claude-box true 2>/dev/null && break
  sleep 10
done

echo "==> Verifying"
ssh claude-box 'set -e
  claude --version
  claude-smoke-test /run/current-system/claude-code/bin/claude
  claude -p "Reply with exactly: claude-box ready"'
ssh claude-box-admin 'systemctl list-timers claude-box-upgrade --no-pager'

echo "==> Removing the private host key from this Mac"
rm -rf "$keydir"
echo "Done. Connect with: ssh claude-box"
