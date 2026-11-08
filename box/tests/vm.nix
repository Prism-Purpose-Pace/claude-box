# nix build ./box#checks.x86_64-linux.vm
# Boots the real host modules in a VM (without disk layout and secrets) and
# checks SSH hardening, the claude user, the wrapper and the smoke test.
{ pkgs, self }:
pkgs.testers.runNixOSTest {
  name = "claude-box";
  node.pkgsReadOnly = false;
  nodes.box =
    { lib, ... }:
    {
      imports = [
        self.inputs.sops-nix.nixosModules.sops
        ../modules/base.nix
        ../modules/claude.nix
        ../modules/auto-upgrade.nix
        ../modules/remote-access.nix
      ];
      nixpkgs.overlays = self.nixosConfigurations.claude-box.config.nixpkgs.overlays;
      nixpkgs.config.allowUnfreePredicate = _: true;
      box.sshKeys = [ (builtins.readFile ../hosts/claude-box/authorized_keys) ];
      box.hasSecrets = lib.mkForce false;
      box.upgrade.flake = "path:/nonexistent";
      boot.loader.systemd-boot.enable = lib.mkForce false;
      boot.loader.efi.canTouchEfiVariables = lib.mkForce false;
      virtualisation.memorySize = 2048;
    };
  testScript = ''
    box.wait_for_unit("multi-user.target")
    box.wait_for_unit("sshd.service")
    box.succeed("grep -qx 'PasswordAuthentication no' /etc/ssh/sshd_config")
    box.succeed("grep -qx 'PermitRootLogin no' /etc/ssh/sshd_config")
    box.fail("id -nG claude | grep -qw wheel")
    box.succeed("id -nG admin | grep -qw wheel")
    print(box.succeed("su - claude -c 'claude --version'"))
    box.succeed("su - claude -c 'jq -e .hasCompletedOnboarding ~/.claude.json'")
    print(box.succeed("runuser -u nobody -- claude-smoke-test /run/current-system/claude-code/bin/claude"))
    box.succeed("systemctl list-timers | grep -q claude-box-upgrade")
  '';
}
