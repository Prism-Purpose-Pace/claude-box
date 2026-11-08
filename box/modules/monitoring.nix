# Detection for the `claude` user (see SECURITY.md, measures M4 and M5).
#
#   M4  audit trail: every program `claude` executes, recorded by the kernel
#       audit subsystem in /var/log/audit (root only, own rotation)
#   M5  continuous resource history (below) and a watchdog that pushes an ntfy
#       alert on OOM kills, fork-bomb hits, sustained full CPU (runaway or
#       cryptomining) and a filling disk
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.box.monitoring;
  inherit (lib) mkOption types;
  notifyEnabled = config.box.notify.enable;

  watch = pkgs.writeShellApplication {
    name = "claude-box-watch";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gawk
      pkgs.gnugrep
      pkgs.procps
      config.systemd.package
    ]
    ++ lib.optional notifyEnabled config.box.notify.package;
    text = ''
      state=''${STATE_DIRECTORY:-/var/lib/claude-box-watch}
      uid=$(id -u claude)
      cg=/sys/fs/cgroup/user.slice/user-$uid.slice
      now=$(date +%s)

      # Fails if the push could not be sent; callers then retry next run.
      alert() { # alert <title> <message>
        echo "ALERT: $1 - $2"
        ${
          if notifyEnabled then
            ''claude-box-notify "claude-box: $1" "$2" || { echo "notification failed" >&2; return 1; }''
          else
            "true"
        }
      }
      top_procs() {
        { ps -u claude -o pid=,pcpu=,rss=,etime=,args= --sort=-pcpu || true; } | head -5 | cut -c1-120
      }
      # Level conditions alert once, then again only after they cleared.
      raise() { # raise <key> <title> <message>
        [ -e "$state/$1.raised" ] && return 0
        if alert "$2" "$3"; then touch "$state/$1.raised"; fi
      }
      rearm() { rm -f "$state/$1.raised" "$state/$1.since"; }
      # Kernel counters alert whenever they grew since the last run.
      counter() { # counter <key> <file> <field> <title> <message>
        local cur prev
        cur=$(awk -v f="$3" '$1 == f { print $2 }' "$2" 2>/dev/null || true)
        [ -n "$cur" ] || return 0
        prev=$(cat "$state/$1.count" 2>/dev/null || echo 0)
        if [ "$cur" -gt "$prev" ] && ! alert "$4" "$5 ($((cur - prev)) new)"$'\n'"$(top_procs)"; then
          return 0 # keep the old count
        fi
        echo "$cur" >"$state/$1.count" # also after a reset (slice recreated)
      }

      if [ -d "$cg" ]; then
        counter oom "$cg/memory.events" oom_kill "claude hit its memory limit" \
          "The kernel OOM-killed processes of claude (MemoryMax)."
        counter tasks "$cg/pids.events" max "claude hit its task limit" \
          "Process creation of claude failed at TasksMax (fork bomb or runaway)."

        # Sustained CPU: average cores used since the last run.
        usage=$(awk '$1 == "usage_usec" { print $2 }' "$cg/cpu.stat")
        last_t=$now last_u=$usage
        if [ -r "$state/cpu" ]; then read -r last_t last_u <"$state/cpu"; fi
        echo "$now $usage" >"$state/cpu"
        elapsed=$((now - last_t))
        if [ "$elapsed" -gt 0 ] && [ "$usage" -ge "$last_u" ]; then
          millicores=$(((usage - last_u) / elapsed / 1000))
          if [ "$millicores" -ge ${toString cfg.watch.cpuMillicores} ]; then
            [ -e "$state/cpu.since" ] || echo "$now" >"$state/cpu.since"
            if [ $((now - $(cat "$state/cpu.since"))) -ge ${toString (cfg.watch.cpuMinutes * 60)} ]; then
              raise cpu "claude used the CPU for ${toString cfg.watch.cpuMinutes} min" \
                "Average $((millicores / 10))% of one core, for ${toString cfg.watch.cpuMinutes}+ minutes. Expected (long build) or not (runaway, mining)?"$'\n'"$(top_procs)"
            fi
          else
            rearm cpu
          fi
        fi
      fi

      # systemd-oomd kills by memory pressure; those do not show up as oom_kill.
      # First run: start at the newest entry of the whole journal (a unit filter
      # could leave the cursor unset and skip the first kill later).
      if [ ! -e "$state/oomd.cursor" ]; then
        journalctl -q -n 1 --cursor-file="$state/oomd.cursor" >/dev/null || true
      else
        cp "$state/oomd.cursor" "$state/oomd.cursor.new"
        killed=$(journalctl -q -o cat -u systemd-oomd --cursor-file="$state/oomd.cursor.new" \
          | grep "Killed .*user-$uid\.slice" || true)
        if [ -z "$killed" ] || alert "systemd-oomd killed claude processes" "$(echo "$killed" | tail -3)"; then
          mv "$state/oomd.cursor.new" "$state/oomd.cursor"
        fi
      fi

      # The disk is shared with /nix and the logs; ext4 keeps 5 % for root.
      used=$(df --output=pcent / | tail -1 | tr -dc 0-9)
      if [ "$used" -ge ${toString cfg.watch.diskPercent} ]; then
        raise disk "root filesystem ''${used}% full" \
          "$(timeout 60 du -xsh /home/claude 2>/dev/null || true)"$'\n'"Upgrades fail when the disk is full."
      elif [ "$used" -lt ${toString (cfg.watch.diskPercent - 5)} ]; then
        rearm disk
      fi
    '';
  };
in
{
  options.box.monitoring = {
    audit.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Record every program `claude` executes in /var/log/audit.";
    };
    below.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Record CPU, memory, IO and pressure per cgroup every 5 s (`below replay`), 14 days / 1 GiB.";
    };
    watch = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Periodic watchdog that sends ntfy alerts about the claude slice and the disk.";
      };
      interval = mkOption {
        type = types.str;
        default = "5min";
        description = "Watchdog interval (systemd time span).";
      };
      cpuMillicores = mkOption {
        type = types.ints.positive;
        default = 3500;
        description = "CPU alert threshold in thousandths of a core (the N3150 has 4 cores = 4000).";
      };
      cpuMinutes = mkOption {
        type = types.ints.unsigned;
        default = 60;
        description = "The CPU threshold must be exceeded for this long before an alert.";
      };
      diskPercent = mkOption {
        type = types.ints.between 1 100;
        default = 90;
        description = "Alert when the root filesystem is at least this full (re-arms 5 points below).";
      };
    };
  };

  config = lib.mkMerge [
    # M4: kernel audit trail. auditd writes /var/log/audit (mode 0700), rotated
    # at 10 x 50 MB. The kernel no longer also multicasts the records into
    # journald, where an execve flood would push out the upgrade and notify
    # logs (journald is capped at 500 MB).
    (lib.mkIf cfg.audit.enable {
      security.audit = {
        enable = true;
        rules = [
          # Every program run by claude, from any session or service.
          "-a always,exit -F arch=b64 -S execve,execveat -F uid=claude -k claude-exec"
          "-a always,exit -F arch=b32 -S execve,execveat -F uid=claude -k claude-exec"
        ];
      };
      security.auditd = {
        enable = true;
        settings = {
          max_log_file = 50;
          num_logs = 10;
          max_log_file_action = "rotate";
          space_left = "10%";
          admin_space_left = "5%";
          space_left_action = "syslog";
          admin_space_left_action = "syslog";
          disk_full_action = "rotate";
        };
      };
      systemd.sockets.systemd-journald-audit.enable = false;
    })

    # M5a: continuous per-cgroup history, queried with `below replay`.
    (lib.mkIf cfg.below.enable {
      services.below = {
        enable = true;
        compression.enable = true;
        retention = {
          size = 1024 * 1024 * 1024;
          time = 14 * 24 * 3600;
        };
      };
    })

    # M5b: watchdog with push alerts.
    (lib.mkIf cfg.watch.enable {
      environment.systemPackages = [ watch ];
      systemd.services.claude-box-watch = {
        description = "Check the claude slice and the disk, alert via ntfy";
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        onFailure = lib.optional notifyEnabled "notify-failure@%n.service";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe watch;
          StateDirectory = "claude-box-watch";
          StateDirectoryMode = "0700";
          ProtectSystem = "strict";
          PrivateTmp = true;
          NoNewPrivileges = true;
        };
      };
      systemd.timers.claude-box-watch = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = cfg.watch.interval;
          OnUnitActiveSec = cfg.watch.interval;
        };
      };
    })
  ];
}
