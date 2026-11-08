#!/usr/bin/env bash
# macOS: download the claude-box installer ISO (GitHub release "installer"),
# verify its checksum and write it to a USB stick.
#   ./box/scripts/flash-usb.sh
# Only external physical disks are offered; you confirm the disk by typing its name.
set -euo pipefail

[ "$(uname)" = Darwin ] || { echo "macOS only (uses diskutil)." >&2; exit 1; }

repo=$(git remote get-url origin | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')
base="https://github.com/$repo/releases/download/installer"
cache="$HOME/.cache/claude-box"
iso="$cache/claude-box-installer.iso"
mkdir -p "$cache"

echo "==> Checking for the current installer ($repo)"
curl -fsSL "$base/claude-box-installer.iso.sha256" -o "$cache/claude-box-installer.iso.sha256" \
  || { echo "No installer release yet - run the 'installer' workflow on GitHub first." >&2; exit 1; }
if ! (cd "$cache" && shasum -a 256 -c claude-box-installer.iso.sha256 >/dev/null 2>&1); then
  echo "==> Downloading ISO"
  curl -fL --progress-bar "$base/claude-box-installer.iso" -o "$iso"
  (cd "$cache" && shasum -a 256 -c claude-box-installer.iso.sha256) \
    || { echo "Checksum mismatch - download corrupt, aborting." >&2; rm -f "$iso"; exit 1; }
else
  echo "Cached ISO is current."
fi

echo
echo "==> External disks:"
disks=$(diskutil list external physical | awk '/^\/dev\/disk/ {print $1}')
[ -n "$disks" ] || { echo "No external disk found - plug in the USB stick." >&2; exit 1; }
for d in $disks; do
  name=$(diskutil info "$d" | awk -F: '/Media Name/ {gsub(/^ +/,"",$2); print $2}')
  size=$(diskutil info "$d" | awk -F: '/Disk Size/ {gsub(/^ +/,"",$2); print $2}' | cut -d'(' -f1)
  echo "  ${d#/dev/}  $name  $size"
done
echo
read -r -p "Type the disk to ERASE (e.g. disk4): " choice
dev="/dev/$choice"
grep -qx "$dev" <<<"$disks" || { echo "$choice is not one of the external disks above." >&2; exit 1; }
read -r -p "All data on $choice will be lost. Type YES: " answer
[ "$answer" = "YES" ] || exit 1

diskutil unmountDisk "$dev"
echo "==> Writing (sudo asks for your Mac password; takes a few minutes)"
sudo dd if="$iso" of="/dev/r$choice" bs=4194304
sync
diskutil eject "$dev"
echo "Done. Plug the stick into the ZBOX and continue with setup.sh."
