# Pull-based, self-testing upgrades.
#
#   1. build the latest config from GitHub (substituted from cache.nixos.org,
#      only the small Claude wrapper is built locally)
#   2. run a full headless Claude Code turn with the NEW binary on THIS CPU
#      against a local mock API; abort if it crashes (e.g. AVX regression)
#   3. switch; if switching fails, roll back to the previous generation
#   4. reboot only if kernel/initrd changed
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.box.upgrade;

  upgrade = pkgs.writeShellApplication {
    name = "claude-box-upgrade";
    runtimeInputs = [
      config.nix.package
      pkgs.git
      pkgs.coreutils
      pkgs.util-linux
      config.systemd.package
    ];
    text = ''
      ref="${cfg.flake}#nixosConfigurations.claude-box.config.system.build.toplevel"
      state=/var/lib/claude-box
      mkdir -p "$state"

      echo "Building $ref"
      new=$(nix build --no-link --print-out-paths --refresh "$ref")
      cur=$(readlink -f /run/current-system)
      if [ "$new" = "$cur" ]; then
        echo "Already up to date: $cur"
        exit 0
      fi

      echo "Smoke-testing Claude Code of $new on this CPU"
      rc=0
      runuser -u nobody -- ${pkgs.claude-smoke-test}/bin/claude-smoke-test "$new/claude-code/bin/claude" || rc=$?
      if [ "$rc" -eq 2 ]; then
        echo "$(date -Is) SKIPPED $new (smoke test harness failed, retry next run)" >> "$state/history"
        echo "Smoke test could not run, keeping $cur" >&2
        exit 1
      elif [ "$rc" -ne 0 ]; then
        echo "$(date -Is) REJECTED $new (smoke test failed)" >> "$state/history"
        echo "Smoke test failed, keeping $cur" >&2
        exit 1
      fi

      echo "Switching to $new"
      nix-env -p /nix/var/nix/profiles/system --set "$new"
      if ! "$new/bin/switch-to-configuration" switch; then
        echo "$(date -Is) ROLLBACK $new (switch failed)" >> "$state/history"
        nix-env -p /nix/var/nix/profiles/system --rollback
        "$cur/bin/switch-to-configuration" switch || true
        exit 1
      fi
      echo "$(date -Is) OK $new" >> "$state/history"

      booted=$(readlink /run/booted-system/{initrd,kernel,kernel-modules})
      built=$(readlink "$new"/{initrd,kernel,kernel-modules})
      if [ "$booted" != "$built" ]; then
        echo "Kernel changed, rebooting"
        systemctl reboot
      fi
    '';
  };
in
{
  options.box.upgrade = {
    flake = lib.mkOption {
      type = lib.types.str;
      description = "Flake reference (without #attr) the box pulls its configuration from.";
    };
    schedule = lib.mkOption {
      type = lib.types.str;
      default = "*-*-* 04:30:00";
      description = "systemd OnCalendar expression for upgrade runs.";
    };
  };

  config = {
    # Expose the unwrapped Claude Code package inside the system closure,
    # so the upgrade gate can test exactly the binary that will be deployed.
    system.systemBuilderCommands = ''
      ln -s ${pkgs.claude-code-box} $out/claude-code
    '';

    environment.systemPackages = [ upgrade ];

    systemd.services.claude-box-upgrade = {
      description = "Pull, test and apply the claude-box configuration";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      restartIfChanged = false; # never interrupt itself while switching
      unitConfig.X-StopOnRemoval = false;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe upgrade;
      };
    };

    systemd.timers.claude-box-upgrade = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.schedule;
        RandomizedDelaySec = "30min";
        Persistent = true; # catch up if the box was off at 04:30
      };
    };
  };
}
