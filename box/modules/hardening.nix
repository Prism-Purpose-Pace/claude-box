# Containment of the `claude` user (see SECURITY.md, measures M1-M3).
#
# The threat model treats everything running as `claude` as potentially
# attacker-controlled (prompt injection). This module therefore puts hard,
# kernel-enforced limits around that user, none of which depend on Claude Code
# behaving:
#
#   M1  resource limits + systemd-oomd on the user's slice, so a runaway or
#       hijacked agent cannot starve sshd, the upgrade (= patch) path or admin
#   M2  no network access from the slice to the LAN, link-local, CGNAT/VPN or
#       multicast ranges, plus every on-link IPv6 prefix (tracked at runtime)
#   M3  no self-managed SSH keys (~/.ssh/authorized_keys is ignored) and no
#       SSH agent forwarding
#
# The limits live on user-<uid>.slice, which contains every process of the
# user: SSH sessions, tmux, `systemd-run --user` jobs and lingering services.
# The uid is not pinned in the configuration (an installed box already has
# one), so a generator resolves it at boot and on every switch.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.box.hardening;
  inherit (lib) mkOption types;

  # Destinations no process of `claude` may reach (systemd IPAddressDeny syntax).
  staticDeny = [
    "10.0.0.0/8" # RFC 1918
    "172.16.0.0/12"
    "192.168.0.0/16"
    "100.64.0.0/10" # CGNAT: NetBird/Tailscale peers
    "169.254.0.0/16" # IPv4 link-local
    "fc00::/7" # IPv6 unique local
    "fe80::/10" # IPv6 link-local
    "224.0.0.0/4" # multicast (LAN discovery); the keyword `multicast` works
    "ff00::/8" # in unit files but not in `systemctl set-property`
  ];

  sliceConf = pkgs.writeText "claude-box-slice.conf" (
    ''
      [Slice]
      MemoryHigh=${cfg.claude.memoryHigh}
      MemoryMax=${cfg.claude.memoryMax}
      MemorySwapMax=${cfg.claude.memorySwapMax}
      CPUWeight=${toString cfg.claude.cpuWeight}
      TasksMax=${toString cfg.claude.tasksMax}
      ManagedOOMMemoryPressure=kill
      ManagedOOMMemoryPressureLimit=${cfg.claude.oomdPressureLimit}
    ''
    + lib.optionalString cfg.lanIsolation.enable ''
      IPAddressDeny=${lib.concatStringsSep " " staticDeny}
    ''
    + lib.optionalString (cfg.lanIsolation.enable && cfg.lanIsolation.allow != [ ]) ''
      IPAddressAllow=${lib.concatStringsSep " " cfg.lanIsolation.allow}
    ''
  );

  # systemd.generator(7): runs before any unit starts (boot) and on every
  # daemon-reload/reexec (switch-to-configuration), so the drop-in is in place
  # before the lingering user manager of `claude` comes up.
  sliceGenerator = pkgs.writeShellScript "claude-box-slice-generator" ''
    uid=$(${pkgs.gawk}/bin/awk -F: '$1 == "claude" { print $3 }' /etc/passwd)
    [ -n "$uid" ] || exit 0
    dir="$1/user-$uid.slice.d"
    ${pkgs.coreutils}/bin/mkdir -p "$dir"
    ${pkgs.coreutils}/bin/ln -sf ${sliceConf} "$dir/50-claude-box.conf"
  '';

  # IPv6 LAN prefixes are global (ISP-delegated) and change, so they cannot be
  # listed statically. Every route that is not the default route leads to a
  # directly attached network: deny those, IPv4 and IPv6 alike.
  lanGuard = pkgs.writeShellApplication {
    name = "claude-box-lan-guard";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gawk
      pkgs.iproute2
      config.systemd.package
    ];
    text = ''
      uid=$(id -u claude)
      state=/run/claude-box-lan-guard
      mkdir -p "$state"

      routes() {
        # skip the default route, route types (unreachable, ...), link-local,
        # multicast and loopback (::1 is in the main table)
        ip -o "$1" route show table main \
          | awk '$1 != "default" && $1 ~ /^[0-9a-f.:]+(\/[0-9]+)?$/ && $1 !~ /^(fe80|ff)/ && $0 !~ / dev lo / { print $1 }'
      }
      want=$(
        {
          printf '%s\n' ${lib.escapeShellArgs staticDeny}
          routes -4
          routes -6
        } | sort -u | tr '\n' ' '
      )

      if [ "$want" = "$(cat "$state/applied" 2>/dev/null || true)" ]; then
        exit 0
      fi
      # The empty assignment resets the list (including the generator's static
      # part, which is therefore repeated in $want).
      systemctl set-property --runtime "user-$uid.slice" "IPAddressDeny=" "IPAddressDeny=$want"
      echo "$want" >"$state/applied"
      echo "claude slice: IPAddressDeny=$want"
    '';
  };
in
{
  options.box.hardening = {
    claude = {
      memoryHigh = mkOption {
        type = types.str;
        default = "60%";
        description = "MemoryHigh= of the claude slice: above this the kernel throttles and reclaims (percent of RAM or bytes).";
      };
      memoryMax = mkOption {
        type = types.str;
        default = "70%";
        description = "MemoryMax= of the claude slice: hard limit, the kernel OOM-kills inside the slice beyond it.";
      };
      memorySwapMax = mkOption {
        type = types.str;
        default = "2G";
        description = "MemorySwapMax= of the claude slice (swap is zram, i.e. also RAM).";
      };
      cpuWeight = mkOption {
        type = types.ints.between 1 10000;
        default = 50;
        description = "CPUWeight= of the claude slice (default 100); only matters under contention, idle CPU stays usable.";
      };
      tasksMax = mkOption {
        type = types.ints.positive;
        default = 4096;
        description = "TasksMax= of the claude slice (processes + threads); stops fork bombs.";
      };
      oomdPressureLimit = mkOption {
        type = types.str;
        default = "80%";
        description = "systemd-oomd kills the worst cgroup in the claude slice when memory pressure stays above this for 20 s.";
      };
    };

    lanIsolation = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Block all traffic between processes of `claude` and private, link-local,
          CGNAT/VPN and multicast addresses, plus every directly attached network
          (on-link IPv6 prefixes are tracked at runtime). Internet and localhost
          stay reachable; DNS goes through the local systemd-resolved stub.
        '';
      };
      allow = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "192.168.178.20/32" ];
        description = "Exceptions (IPAddressAllow=), e.g. a NAS that Claude is supposed to use.";
      };
      interval = mkOption {
        type = types.str;
        default = "2min";
        description = "How often on-link IPv6 prefixes are re-read (they change when the ISP delegates a new prefix).";
      };
    };

    agentForwarding = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Allow SSH agent forwarding. Off because the Mac uses the same key for
        `claude` and `admin`: an agent forwarded into a `claude` session would let
        a hijacked agent log in as admin (root).
      '';
    };
  };

  config = lib.mkMerge [
    {
      # M1: limits + oomd on the claude slice (oomd itself is on by default;
      # only this slice is monitored, admin is left alone).
      systemd.oomd.enable = true;
      systemd.generators.claude-box-slice = sliceGenerator;

      # M3: keys only from the Nix configuration (/etc/ssh/authorized_keys.d/%u).
      # A hijacked agent could otherwise add its own key to ~/.ssh/authorized_keys
      # and keep a shell after the token is revoked.
      services.openssh = {
        authorizedKeysInHomedir = false;
        settings.AllowAgentForwarding = cfg.agentForwarding;
      };
    }

    # M2: on-link prefixes (IPv6 above all) at boot and then periodically.
    (lib.mkIf cfg.lanIsolation.enable {
      environment.systemPackages = [ lanGuard ];
      systemd.services.claude-box-lan-guard = {
        description = "Keep LAN networks out of reach of the claude user";
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe lanGuard;
        };
      };
      systemd.timers.claude-box-lan-guard = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = cfg.lanIsolation.interval;
          OnUnitActiveSec = cfg.lanIsolation.interval;
        };
      };
    })
  ];
}
