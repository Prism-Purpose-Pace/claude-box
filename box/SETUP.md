# Setting up claude-box from scratch

Takes about an hour, most of it waiting. You need: the Mac, the ZBOX with a LAN
cable to your router, a USB stick (≥ 2 GB, will be erased), and a monitor plus
USB keyboard for the BIOS step only.

Items marked _(unverified)_ depend on your exact firmware or account and were
not tested on real hardware.

## 1. Mac (one time)

```sh
# Nix (Determinate Systems installer) – skip if `nix --version` works
curl -fsSL https://install.determinate.systems/nix | sh -s -- install

# repository + GitHub CLI login
git clone git@github.com:Prism-Purpose-Pace/claude-box.git && cd claude-box
nix develop ./box --command gh auth login
```

Your SSH key `~/.ssh/id_ed25519_claude-box_zodiac` must exist and its public half
must be in `box/hosts/claude-box/authorized_keys` (already the case).

`setup.sh` commits the encrypted secrets, so install the repository's
pre-commit hooks first (formatters, linters, secret scan on every commit):

```sh
nix develop ./dev --command true   # or `direnv allow` if you use direnv
```

## 2. GitHub (one time)

```sh
nix develop ./box --command ./box/scripts/repo-setup.sh
```

Enables Actions, secret scanning, push protection and vulnerability alerts, and
starts the first workflow runs. Then, in the browser:

- **Install Renovate** for the repository: https://github.com/apps/renovate
  (lock files are merged automatically; GitHub Actions updates wait for your review)
- Wait until **Actions → installer** is green (≈ 10 min). It publishes the
  installer ISO as the release `installer`.

## 3. Phone (one time)

Install the **ntfy** app (iOS / Android). You subscribe to your topic in step 6,
when `setup.sh` prints it. The box only sends messages when something fails.

## 4. USB stick

```sh
./box/scripts/flash-usb.sh
```

Downloads the ISO, checks its SHA-256, lists only external disks and asks you to
type the disk name (e.g. `disk4`) and `YES`. Your Mac password is needed for `dd`.

## 5. ZBOX BIOS

Connect monitor, keyboard and LAN, plug in the stick, power on and enter the
setup with **Del** _(unverified: ZOTAC boards usually use Del)_. Set:

| Setting                                             | Value               | Why                                    |
| --------------------------------------------------- | ------------------- | -------------------------------------- |
| Boot mode                                           | UEFI only           | systemd-boot needs UEFI                |
| Secure Boot                                         | Disabled            | NixOS kernels are not signed for it    |
| Restore on AC power loss / "Power on after AC loss" | Power On            | comes back by itself after a power cut |
| Boot order                                          | USB first (for now) | install from the stick                 |

Save, reboot. If it does not boot from the stick, use the boot menu key
(**F8** or **F11**, _unverified_). The screen then shows
"claude-box installer… nothing to do here" – leave it.

## 6. Install

```sh
nix develop ./box --command ./box/scripts/setup.sh
```

| What it does                                                                            | What you do                                                                                                                                                           |
| --------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| checks key, Keychain, repository                                                        | –                                                                                                                                                                     |
| creates the box's host key and encrypted secrets (first run only)                       | run `claude setup-token` in a second terminal, paste the token; NetBird key: Enter; ntfy topic: Enter (generates one) – **subscribe to the printed topic in the app** |
| waits for `claude-installer.local`                                                      | –                                                                                                                                                                     |
| shows the installer's SSH fingerprint                                                   | compare it with the one on the ZBOX screen, type `yes` only if it matches                                                                                             |
| shows the disk it will erase                                                            | type `YES`                                                                                                                                                            |
| installs (builds on the ZBOX, _unverified: roughly 20–40 min on the N3150_) and reboots | –                                                                                                                                                                     |
| verifies `claude --version`, smoke test, one real prompt, upgrade timer                 | –                                                                                                                                                                     |

Afterwards **remove the USB stick**, otherwise the next boot starts the installer again.

## 7. Check

```sh
ssh claude-box                                                   # user claude
ssh claude-box-admin sudo claude-box-notify "claude-box" "test"  # should reach your phone
ssh claude-box-admin systemctl list-timers 'claude-box-*'
```

Claude Code settings and the herdr config are set up automatically from
`box/home/claude/`. The herdr plugins need your approval once:

```sh
ssh claude-box -t claude-box-herdr-plugins   # shows each plugin's trust preview
```

From now on nothing is manual. What happens automatically is described in
[README.md](README.md#how-updates-flow).

## Troubleshooting

| Symptom                                               | Cause / fix                                                                                                                                                |
| ----------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `flash-usb.sh`: "No installer release yet"            | step 2 not finished; check Actions → installer                                                                                                             |
| `setup.sh` waits forever for `claude-installer.local` | box not on LAN, booted from internal disk, or mDNS blocked (guest Wi-Fi/VLAN). With the IP from the box's screen (`ip a`): `./box/scripts/install.sh <IP>` |
| "/dev/sda is not the internal SATA disk"              | nothing was erased. Set the correct device in `hosts/claude-box/disko.nix`, commit, push, rerun                                                            |
| "Local commits are not pushed yet"                    | `git push`, rerun – the box installs what is on GitHub                                                                                                     |
| Verification prompt fails, everything else OK         | token wrong or expired: `./box/scripts/bootstrap.sh --secrets`, then `ssh claude-box-admin sudo systemctl start claude-box-upgrade`                        |
| `ssh claude-box` hangs after install                  | the box rebooted into the installer: remove the stick, power-cycle                                                                                         |
| Stock NixOS ISO instead of ours                       | set root password with `passwd`, then `./box/scripts/install.sh <IP>` (asks for that password once)                                                        |
