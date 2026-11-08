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
