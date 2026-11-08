# Installer ISO for claude-box, built by CI and published as the GitHub release
# "installer". Compared with the stock NixOS minimal ISO it saves the manual
# steps before installation: your SSH key is already authorised for root, and
# the box announces itself as claude-installer.local, so neither a password nor
# its IP address is needed.
{ lib, modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix") ];

  networking.hostName = "claude-installer";
  image.baseName = lib.mkForce "claude-box-installer";

  users.users.root.openssh.authorizedKeys.keys = lib.splitString "\n" (
    lib.trim (builtins.readFile ../hosts/claude-box/authorized_keys)
  );
  services = {
    openssh.settings = {
      PasswordAuthentication = lib.mkForce false;
      KbdInteractiveAuthentication = lib.mkForce false;
      PermitRootLogin = lib.mkForce "prohibit-password";
    };

    avahi = {
      enable = true;
      nssmdns4 = true;
      publish = {
        enable = true;
        addresses = true;
      };
    };

    getty.helpLine = lib.mkForce ''

      claude-box installer. Nothing to do here: on the Mac run
        nix develop ./box --command ./box/scripts/setup.sh
      It finds this machine as claude-installer.local.
    '';
  };

  console.keyMap = "de";
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

}
