#!/usr/bin/env bash
# The whole first installation in one command, run on the Mac:
#   nix develop ./box --command ./box/scripts/setup.sh
#
# 1. checks the Mac (SSH key, Keychain, repository state)
# 2. creates host key + encrypted secrets if they do not exist yet (bootstrap.sh)
# 3. waits until the ZBOX, booted from the claude-box installer, shows up
# 4. installs and verifies (install.sh)
#
# Safe to re-run: finished steps are skipped.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

cd "$(git rev-parse --show-toplevel)/box"
installer="${CLAUDE_BOX_INSTALLER:-claude-installer.local}"

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
fail() {
  printf '\033[31m%s\033[0m\n' "$*" >&2
  exit 1
}

step "1/4 Checking the Mac"
[ -f "$key" ] || fail "SSH key $key not found. Create it with:
  ssh-keygen -t ed25519 -f $key && ssh-add --apple-use-keychain $key
then add $key.pub to box/hosts/claude-box/authorized_keys, commit and push."
[ -f "$key.pub" ] || fail "Public key $key.pub not found. Recreate it with:
  ssh-keygen -y -f $key > $key.pub"
if [ "$(uname)" = Darwin ]; then
  ssh-add --apple-use-keychain "$key" 2>/dev/null || true
fi
grep -qF "$(cut -d' ' -f2 "$key.pub")" hosts/claude-box/authorized_keys \
  || fail "$key.pub is not in hosts/claude-box/authorized_keys."
git pull -q --ff-only || fail "Could not fast-forward to origin/main - resolve this first."
echo "OK: key, Keychain, repository up to date"

step "2/4 Host key and secrets"
if [ -f secrets/secrets.yaml ] && [ -f "$pubkey" ] && [ -f "$hostkey" ]; then
  echo "Already there (rotate later with: ./box/scripts/bootstrap.sh --secrets)"
elif [ -f secrets/secrets.yaml ] && [ -f "$pubkey" ]; then
  # install.sh deletes the private host key after a successful install. A new
  # one would lock the running box out of its secrets, so only on request.
  fail "claude-box is already installed (its private host key was removed from this Mac).
Nothing to do. To reinstall from scratch run:
  ./box/scripts/bootstrap.sh --new-host-key
then re-run this script."
else
  ./scripts/bootstrap.sh
fi
if [ -n "$(git rev-list '@{u}..HEAD')" ]; then git push -q; fi

step "3/4 Waiting for the installer ($installer)"
cat <<TXT
Boot the ZBOX from the USB stick written by flash-usb.sh
(LAN cable plugged in; boot menu key on ZOTAC boards is usually F8 or F11).
TXT
deadline=$((SECONDS + 1800))
until ssh -i "$key" -o BatchMode=yes -o ConnectTimeout=5 "${installer_ssh_opts[@]}" \
  "root@$installer" true 2>/dev/null; do
  [ $SECONDS -lt $deadline ] || fail "Installer not reachable after 30 minutes. With the stock
NixOS ISO run instead: ./box/scripts/install.sh <IP>"
  printf '.'
  sleep 10
done
echo
echo "Installer found."

step "4/4 Installing"
./scripts/install.sh "$installer"
