{ lib, ... }:
{
  imports = [
    ./hardware.nix
    ./disko.nix
    ../../modules/base.nix
    ../../modules/claude.nix
    ../../modules/auto-upgrade.nix
    ../../modules/remote-access.nix
  ];

  networking.hostName = "claude-box";

  box = {
    sshKeys = lib.splitString "\n" (lib.trim (builtins.readFile ./authorized_keys));
    # "none"    = reachable in the LAN only (and via FritzBox WireGuard, which needs nothing here)
    # "netbird" = NetBird mesh VPN; needs netbird_setup_key in secrets (bootstrap.sh asks for it)
    remoteAccess = "none";
    upgrade.flake = "github:philippsied/nix-claude-box?dir=box";
  };

  system.stateVersion = "26.05";
}
