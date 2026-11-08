#!/usr/bin/env bash
# Run on the Mac after bootstrap.sh (setup.sh does both), with the ZBOX booted
# from the claude-box installer ISO (or the stock NixOS minimal ISO):
#   nix develop ./box --command ./box/scripts/install.sh [host]
# host defaults to claude-installer.local (our ISO); for the stock ISO pass its IP.
#
# WIPES the internal SATA disk of the box and installs claude-box.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ip="${1:-claude-installer.local}"
cd "$(git rev-parse --show-toplevel)/box"

min_disk=$((60 * 1000 * 1000 * 1000))

[ -f "$hostkey" ] || { echo "No host key in $keydir - run bootstrap.sh first." >&2; exit 1; }
[ -f secrets/secrets.yaml ] || { echo "No secrets - run bootstrap.sh first." >&2; exit 1; }
# Whole repository: the box flake also builds ../package.nix and ../versions/.
if [ -n "$(git status --porcelain -- :/)" ]; then
  echo "The repository has uncommitted changes - commit and push first, the box will pull from GitHub." >&2
  exit 1
fi
git fetch -q origin
if [ -n "$(git rev-list '@{u}..HEAD')" ]; then
  echo "Local commits are not pushed yet - run 'git push' first, the box will pull from GitHub." >&2
  exit 1
fi

trap installer_disconnect EXIT
installer_connect "$ip" "$key"

echo "==> Checking the target disk"
# The disk disko will wipe, resolved on the installer (handles /dev/disk/by-id/…).
target=$(nix eval --raw ".#nixosConfigurations.claude-box.config.disko.devices.disk.main.device")
target_name=$(ssh "${installer_ssh[@]}" "root@$ip" readlink -f "$target")
target_name="${target_name#/dev/}"
disks=$(ssh "${installer_ssh[@]}" "root@$ip" lsblk -dnbo NAME,TRAN,RM,SIZE,MODEL)
echo "$disks"
read -r _ tran rm size model <<<"$(awk -v d="$target_name" '$1==d' <<<"$disks")"
if [ "${tran:-}" != "sata" ] || [ "${rm:-1}" != "0" ] || [ "${size:-0}" -lt "$min_disk" ]; then
  echo "$target is not the internal SATA disk - aborting, nothing was changed." >&2
  echo "Set disko.devices.disk.main.device in hosts/claude-box/disko.nix to the right disk." >&2
  exit 1
fi
echo
read -r -p "ERASE $target ($model, $((size / 1000000000)) GB) and install claude-box? Type YES: " answer
[ "$answer" = "YES" ] || exit 1

echo "==> Installing (builds on the box, takes a while on the N3150)"
nixos-anywhere \
  --flake ".#claude-box" \
  --build-on remote \
  --extra-files "$keydir" \
  -i "$key" \
  --ssh-option "${installer_mux[1]}" \
  --target-host "root@$ip"
installer_disconnect

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
