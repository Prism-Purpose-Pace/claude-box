# nix build ./box#checks.x86_64-linux.vm
# Boots the real host modules in a VM (without disk layout and secrets) and
# checks SSH hardening, the claude user, the wrapper and the smoke test, plus
# the containment and monitoring measures from SECURITY.md (M1-M5). A second
# node `lan` plays a device in the home network and the Mac's SSH client.
{ pkgs, self }:
let
  inherit (pkgs) lib;
  audit = lib.getBin pkgs.audit;
in
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
        ../modules/hardening.nix
        ../modules/monitoring.nix
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
        # Small enough to hit in the test; the disk alert fires immediately.
        hardening.claude.tasksMax = 200;
        monitoring.watch.diskPercent = 1;
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

  # A device in the home network (router UI, NAS, ...): must stay out of reach
  # of `claude`, over IPv4 and over its global IPv6 address.
  nodes.lan = {
    networking.firewall.allowedTCPPorts = [ 8000 ];
    systemd.services.lan-http = {
      wantedBy = [ "multi-user.target" ];
      script = "${pkgs.python3}/bin/python3 -m http.server --bind :: --directory /etc 8000";
    };
  };

  testScript =
    { nodes, ... }:
    let
      lan4 = nodes.lan.networking.primaryIPAddress;
      lan6 = nodes.lan.networking.primaryIPv6Address;
    in
    ''
      import shlex

      # -n: without it ssh reads stdin, i.e. the test driver's command channel
      SSH = "ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=10"
      def as_claude(cmd, key="/root/.ssh/id_ed25519"):
          """Command for `lan` that runs cmd on the box in a real SSH session of claude."""
          return f"{SSH} -i {key} claude@box {shlex.quote(cmd)}"

      start_all()
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
      box.succeed("systemctl list-timers | grep -q claude-box-watch")
      box.succeed("systemctl list-timers | grep -q claude-box-lan-guard")

      # A failing upgrade (unreachable flake) must end up as a push notification.
      box.wait_for_unit("fake-ntfy.service")
      box.fail("systemctl start claude-box-upgrade.service")
      box.wait_until_succeeds("grep -q 'vm-test-topic claude-box: claude-box-upgrade.service failed' /tmp/ntfy.log", timeout=120)

      # M3: only keys from the configuration log in; no agent forwarding.
      box.succeed("grep -qx 'AuthorizedKeysFile /etc/ssh/authorized_keys.d/%u' /etc/ssh/sshd_config")
      box.succeed("grep -qx 'AllowAgentForwarding no' /etc/ssh/sshd_config")
      lan.wait_for_unit("multi-user.target")
      lan.succeed("mkdir -p -m 700 /root/.ssh")
      lan.succeed("ssh-keygen -q -t ed25519 -N ''' -f /root/.ssh/id_ed25519")
      lan.succeed("ssh-keygen -q -t ed25519 -N ''' -f /root/attacker")
      owner = lan.succeed("cat /root/.ssh/id_ed25519.pub").strip()
      box.succeed(
          "cat /etc/ssh/authorized_keys.d/claude > /tmp/ak"
          f" && echo '{owner}' >> /tmp/ak"
          " && rm /etc/ssh/authorized_keys.d/claude"
          " && install -m 444 /tmp/ak /etc/ssh/authorized_keys.d/claude"
      )
      lan.succeed(as_claude("true"))
      attacker = lan.succeed("cat /root/attacker.pub").strip()
      lan.succeed(as_claude(
          f"mkdir -p -m 700 ~/.ssh && echo '{attacker}' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
      ))
      lan.fail(as_claude("true", key="/root/attacker"))

      # M1: limits on the claude slice, which holds the SSH session.
      uid = box.succeed("id -u claude").strip()
      props = box.succeed(f"systemctl show user-{uid}.slice -p MemoryHigh -p MemoryMax -p TasksMax -p ManagedOOMMemoryPressure")
      print(props)
      assert "TasksMax=200" in props, props
      assert "ManagedOOMMemoryPressure=kill" in props, props
      box.succeed(f"test \"$(cat /sys/fs/cgroup/user.slice/user-{uid}.slice/memory.max)\" != max")
      lan.succeed(as_claude(f"grep -q 'user-{uid}.slice' /proc/self/cgroup"))

      # M2: no LAN access for claude (IPv4 and the on-link IPv6 prefix),
      # while root on the box and localhost for claude keep working.
      lan.wait_for_open_port(8000)
      box.succeed("systemctl start claude-box-lan-guard.service")
      print(box.succeed(f"systemctl show user-{uid}.slice -p IPAddressDeny"))
      box.succeed("curl -sf --max-time 5 http://${lan4}:8000/hostname")
      box.succeed("curl -sf --max-time 5 'http://[${lan6}]:8000/hostname'")
      lan.succeed(as_claude("! curl -sf --max-time 5 http://${lan4}:8000/hostname"))
      lan.succeed(as_claude("! curl -sf --max-time 5 'http://[${lan6}]:8000/hostname'"))
      box.succeed("systemd-run --unit=local-http ${pkgs.python3}/bin/python3 -m http.server --bind 127.0.0.1 --directory /etc 8001")
      box.wait_for_open_port(8001)
      lan.succeed(as_claude("curl -sf --max-time 5 http://127.0.0.1:8001/hostname"))

      # M4: every program claude runs is in the audit log, not in journald.
      box.wait_for_unit("auditd.service")
      box.succeed("${audit}/bin/auditctl -l | grep -q claude-exec")
      lan.succeed(as_claude("uname -n"))
      # --input-logs: without a TTY, ausearch would read stdin instead of the log
      box.wait_until_succeeds("${audit}/bin/ausearch --input-logs -i -k claude-exec | grep -q 'a0=uname a1=-n'", timeout=60)
      # is-enabled exits non-zero for masked units; the driver runs with pipefail
      box.succeed("test \"$(systemctl is-enabled systemd-journald-audit.socket || true)\" = masked")

      # M5: resource history runs; the watchdog alerts on a fork bomb and the disk.
      box.wait_for_unit("below.service")
      box.succeed("systemctl start claude-box-watch.service")
      box.succeed("grep -q 'vm-test-topic claude-box: root filesystem' /tmp/ntfy.log")
      box.succeed(
          "cat > /tmp/forks.py <<'EOF'\n"
          "import os, time\n"
          "for _ in range(400):\n"
          "    try:\n"
          "        if os.fork() == 0:\n"
          "            time.sleep(20)\n"
          "            os._exit(0)\n"
          "    except OSError:\n"
          "        break\n"
          "EOF"
      )
      lan.succeed(as_claude("python3 /tmp/forks.py </dev/null >/dev/null 2>&1"))
      box.succeed(f"grep -Eq '^max [1-9]' /sys/fs/cgroup/user.slice/user-{uid}.slice/pids.events")
      box.succeed("systemctl start claude-box-watch.service")
      box.succeed("grep -q 'vm-test-topic claude-box: claude hit its task limit' /tmp/ntfy.log")
      print(box.succeed("cat /tmp/ntfy.log"))
    '';
}
