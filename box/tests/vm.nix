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
        ../modules/notify.nix
      ];
      nixpkgs.overlays = self.nixosConfigurations.claude-box.config.nixpkgs.overlays;
      nixpkgs.config.allowUnfreePredicate = _: true;
      box = {
        sshKeys = [ (builtins.readFile ../hosts/claude-box/authorized_keys) ];
        hasSecrets = lib.mkForce false;
        upgrade.flake = "path:/nonexistent";
        notify = {
          enable = true;
          server = "http://127.0.0.1:8099";
          topicFile = "${pkgs.writeText "topic" "vm-test-topic"}";
        };
      };
      # Stand-in for ntfy.sh: records every request.
      systemd.services.fake-ntfy = {
        wantedBy = [ "multi-user.target" ];
        script = ''
          ${pkgs.python3}/bin/python3 -c '
          import http.server
          class H(http.server.BaseHTTPRequestHandler):
              def do_POST(self):
                  body = self.rfile.read(int(self.headers["content-length"] or 0))
                  open("/tmp/ntfy.log", "a").write(self.path + " " + self.headers["Title"] + "\n")
                  self.send_response(200); self.end_headers()
          http.server.HTTPServer(("127.0.0.1", 8099), H).serve_forever()
          '
        '';
      };
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
    box.wait_for_unit("claude-seed-home.service")
    box.succeed("su - claude -c 'jq -e .permissions ~/.claude/settings.json'")
    box.succeed("su - claude -c 'test -O ~/.config/herdr/config.toml'")
    print(box.succeed("su - claude -c 'herdr --version'"))
    box.succeed("su - claude -c 'command -v claude-box-herdr-plugins'")
    print(box.succeed("runuser -u nobody -- claude-smoke-test /run/current-system/claude-code/bin/claude"))
    box.succeed("systemctl list-timers | grep -q claude-box-upgrade")
    box.succeed("systemctl list-timers | grep -q claude-box-token-check")

    # A failing upgrade (unreachable flake) must end up as a push notification.
    box.wait_for_unit("fake-ntfy.service")
    box.fail("systemctl start claude-box-upgrade.service")
    box.wait_until_succeeds("grep -q 'vm-test-topic claude-box: claude-box-upgrade.service failed' /tmp/ntfy.log", timeout=120)
  '';
}
