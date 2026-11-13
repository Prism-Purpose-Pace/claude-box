# claude-box security concept

How the box contains and watches Claude Code, and why it does it this way.
Written 2026-11-08 for NixOS 26.05. Implemented in
[`modules/hardening.nix`](modules/hardening.nix) (M1–M3) and
[`modules/monitoring.nix`](modules/monitoring.nix) (M4–M5), tested by
[`tests/vm.nix`](tests/vm.nix).

**Core decision:** everything that runs as `claude` is treated as potentially
attacker-controlled. The controls are therefore enforced by the kernel and by
root, never by Claude Code itself. A control that the agent can switch off is
not counted as one.

## 1. System and trust boundaries

```
Internet ── router (NAT, FritzBox) ── home LAN: Mac, NAS, router UI, other devices
                                          │ SSH (keys only)
┌──────────────────────── claude-box ───┴─────────────────────────────────┐
│ root / system.slice: sshd, claude-box-upgrade (pulls main = root), sops │
│ secrets, nix-daemon, auditd, below, claude-box-watch, lan-guard         │
│                                                                         │
│ ┌─ user-<uid>.slice: claude (B1) ─────┐  ┌─ user-<uid>.slice: admin ──┐ │
│ │ Claude Code, tmux, tools, user units│  │ maintenance, sudo          │ │
│ └─────────────────────────────────────┘  └────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────┘
```

| Boundary | Between                     | Enforced by                                          |
| -------- | --------------------------- | ---------------------------------------------------- |
| B1       | `claude` ↔ root/admin       | Unix users, no sudo, cgroup slice (M1, M2), SSH (M3) |
| B2       | box ↔ home LAN              | M2 (outbound from `claude`), firewall (inbound)      |
| B3       | GitHub `main` → root on box | CI split read-only/commit, Renovate policy (README)  |
| B4       | Mac ↔ box                   | SSH keys, pinned host key                            |

## 2. Assets

| Asset                                 | Where                                          | Readable by `claude` today?              |
| ------------------------------------- | ---------------------------------------------- | ---------------------------------------- |
| Root integrity of the box             | –                                              | –                                        |
| Patch path (daily upgrade)            | `claude-box-upgrade`, needs CPU, RAM and disk  | can be starved (M1 prevents)             |
| Claude subscription token             | `/run/secrets/claude_oauth_token`, process env | **yes, by design** (Claude needs it)     |
| GitHub/git credentials of `claude`    | `~claude/.config/gh`, git config               | **yes**, if the owner logs in there (O1) |
| Other devices in the LAN              | router UI, NAS, Mac                            | reachable before M2                      |
| Box host key, ntfy topic, NetBird key | root only                                      | no                                       |
| Code and data Claude works on         | `~claude`                                      | yes, by design                           |

## 3. Threats

| ID  | Threat                                                                                                                                                                                               | Likelihood | Addressed by                                                                   |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------- | ------------------------------------------------------------------------------ |
| T1  | **Hijacked agent**: prompt injection through web pages, repositories, issues or files makes Claude run attacker commands as `claude`. Claude runs unattended, so nobody reviews each command.        | high       | M1–M5, O1–O3                                                                   |
| T1a | – exfiltrates token, GitHub credentials, code                                                                                                                                                        |            | not preventable on the box (R1)                                                |
| T1b | – moves laterally: router UI, NAS, Mac, VPN peers                                                                                                                                                    |            | M2                                                                             |
| T1c | – persists: own SSH key, shell rc files, systemd user units (linger), Claude hooks in `~/.claude/settings.json` (seeded from `home/claude/` only if missing, then writable by `claude`), `CLAUDE.md` |            | M3 (SSH), M4 (records the rest)                                                |
| T1d | – escalates to root: forwarded SSH agent (same key as admin), push to `main` with the box's GitHub credentials, kernel exploit                                                                       |            | M3, O1, weekly kernel updates                                                  |
| T1e | – abuses resources (cryptomining, DoS)                                                                                                                                                               |            | M1, M5                                                                         |
| T1f | – covers its tracks                                                                                                                                                                                  |            | M4 (root-only log), R4                                                         |
| T2  | **Runaway agent**, without an attacker: memory leak, fork loop, full disk, endless build. Starves sshd and the upgrade, i.e. the patch path.                                                         | medium     | M1, M5                                                                         |
| T3  | Supply chain (Claude Code release, nixpkgs, GitHub Actions, herdr and its plugins)                                                                                                                   | low        | existing CI controls (README); herdr plugins only after a manual trust preview |
| T4  | Attacker in the LAN against the box                                                                                                                                                                  | low        | SSH keys only, firewall                                                        |
| T5  | Theft of the box (disk is not encrypted; the host key on it decrypts the secrets)                                                                                                                    | low        | out of scope                                                                   |

## 4. Assumptions

If an assumption is wrong, the listed consequence applies. Check them after
changes to the network, the accounts or the hardware.

| ID  | Assumption                                                                                                                                                                                                                                         | If wrong / how to check                                                                                                                                    |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A1  | One owner; the box sits behind a NAT router; no port forwarding from the internet.                                                                                                                                                                 | Check the router's port sharing. Inbound exposure is not covered here.                                                                                     |
| A2  | Claude Code runs as `claude` with broad autonomy and reads untrusted content. Evidence: the seeded `settings.json` sets `permissions.defaultMode = "auto"`.                                                                                        | If Claude only ran supervised, T1 would be less likely; the measures stay useful.                                                                          |
| A3  | Credentials held by `claude` cannot be protected on the box (the token is in the environment of every Claude process).                                                                                                                             | Scope and rotation are the only levers (O1, O3).                                                                                                           |
| A4  | Root and the kernel are trusted.                                                                                                                                                                                                                   | A kernel exploit defeats every on-box control (R7).                                                                                                        |
| A5  | No log server or SIEM; the owner reacts to ntfy pushes.                                                                                                                                                                                            | With a log server, ship `/var/log/audit` off the box (closes R4).                                                                                          |
| A6  | Monitoring budget on the N3150 (4 cores, 8 GB): a few percent of one core, < 150 MB RAM. _(unverified on the real box)_                                                                                                                            | Check with `systemd-cgtop`; disable `below` with `box.monitoring.below.enable = false`.                                                                    |
| A7  | The uid of `claude` was assigned at install time (probably 1001, not verified) and must not change.                                                                                                                                                | Pinning a different uid would orphan `/home/claude`; therefore a generator resolves it at boot.                                                            |
| A8  | Claude does not need to reach devices in the LAN.                                                                                                                                                                                                  | Add exceptions to `box.hardening.lanIsolation.allow`.                                                                                                      |
| A9  | DNS goes through the systemd-resolved stub `127.0.0.53` (enabled together with networkd; verified in the evaluated config).                                                                                                                        | If DNS went straight to the router, M2 would block it.                                                                                                     |
| A10 | The root filesystem is ext4 with the default 5 % reserved for root (disko passes no `-m`).                                                                                                                                                         | `sudo tune2fs -l /dev/sda2 \| grep Reserved`. Without the reserve a full disk also stops the upgrade.                                                      |
| A11 | Nobody needs SSH agent forwarding to the box or keys in `~claude/.ssh/authorized_keys`.                                                                                                                                                            | `box.hardening.agentForwarding = true` re-enables forwarding; extra keys belong in `hosts/claude-box/authorized_keys`.                                     |
| A12 | Normal work stays below about 4–5 GB RAM and 4096 tasks; more than 60 min of full CPU is rare enough that an alert is welcome. The upgrade compiles herdr on the box (only when its tag changes) in `system.slice`, within the ~2.4 GB left by M1. | Tune `box.hardening.claude.*` and `box.monitoring.watch.*`. If the herdr build runs out of memory, the upgrade fails, notifies and retries the next night. |
| A13 | Claude may use the Nix daemon (`nix shell nixpkgs#…`).                                                                                                                                                                                             | This bypasses M1 and M2 (R3). Restrict with `nix.settings.allowed-users`.                                                                                  |
| A14 | Users are created by the NixOS activation script, so `/etc/passwd` exists when systemd generators run.                                                                                                                                             | With `systemd.sysusers` or `userborn` the slice drop-in would only apply after the next daemon-reload.                                                     |

## 5. Review of the first proposal

The first answer listed monitoring tools by convenience. Measured against the
threats above, the list changed:

| Candidate                                                       | Verdict          | Reason                                                                                                                                                                                                                                                                                                                                                             |
| --------------------------------------------------------------- | ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Prometheus/Grafana, Netdata, Grafana Cloud dashboards           | dropped          | Nobody watches dashboards on a home box. They add listening services and credentials or ship process data to a third party; Netdata is heavy for the N3150. Push alerts plus local history give the same security value (M5).                                                                                                                                      |
| Claude Code OpenTelemetry                                       | dropped          | Needs a collector, measures usage and cost, and the agent controls its own telemetry.                                                                                                                                                                                                                                                                              |
| Claude Code managed settings and logging hooks                  | not in the top 5 | Enforced by the process they constrain; a hijacked agent with a shell is past them. The kernel audit trail (M4) records the same commands without that dependency. Still useful against accidents.                                                                                                                                                                 |
| Claude Code sandbox (`/sandbox`: bubblewrap, network allowlist) | deferred         | The strongest preventive control against T1. `bubblewrap` and `socat` are now in the FHS wrapper, but the sandbox is not enabled in the seeded settings, it is untested nested inside the bubblewrap of the FHS wrapper, and it needs an allowlist policy for the owner's workflows. Not verifiable here.                                                          |
| nftables egress filter per uid                                  | replaced         | By `IPAddressDeny` on the user's slice: no firewall backend switch, covers every process of the user including user services, testable in the VM test.                                                                                                                                                                                                             |
| Slice limits with a pinned uid                                  | corrected        | Pinning a uid on an installed box can change the owner of `/home/claude` (A7); a generator resolves the uid instead.                                                                                                                                                                                                                                               |
| systemd-oomd, auditd, below, own watchdog                       | kept             | Become M1, M4, M5.                                                                                                                                                                                                                                                                                                                                                 |
| **Missed in the first proposal**                                | **added**        | `~/.ssh/authorized_keys` was honoured (verified in the evaluated config) → durable remote access; agent forwarding collapses B1 because `install.sh` uses one key for `claude` and `admin`; IPv6 LAN addresses are global, so a private-range filter alone misses them; the box's GitHub identity can be a path to root (O1); the Nix daemon bypasses limits (R3). |

## 6. Top 5 measures

Ranked by risk reduction per cost on this hardware, limited to what the box
can enforce and the VM test can verify.

### M1 – Resource containment of the `claude` slice

- **Threats:** T2, T1e. Keeps sshd, admin and the upgrade (patch path) working whatever Claude does.
- **Specification:** drop-in for `user-<uid>.slice`, written by the generator `claude-box-slice` at boot and on every switch (`switch-to-configuration` re-executes systemd). The slice holds every process of the user: SSH sessions, tmux, `systemd-run --user` jobs, lingering services.

  | Setting                         | Default | Option (`box.hardening.claude.*`) | Effect                                                             |
  | ------------------------------- | ------- | --------------------------------- | ------------------------------------------------------------------ |
  | `MemoryHigh`                    | 60 %    | `memoryHigh`                      | throttling and reclaim above this                                  |
  | `MemoryMax`                     | 70 %    | `memoryMax`                       | hard limit; the kernel OOM-kills inside the slice                  |
  | `MemorySwapMax`                 | 2G      | `memorySwapMax`                   | zram swap is RAM too                                               |
  | `CPUWeight`                     | 50      | `cpuWeight`                       | admin wins under contention; idle CPU stays usable                 |
  | `TasksMax`                      | 4096    | `tasksMax`                        | stops fork bombs                                                   |
  | `ManagedOOMMemoryPressure`      | kill    | –                                 | systemd-oomd kills the worst cgroup in the slice …                 |
  | `ManagedOOMMemoryPressureLimit` | 80 %    | `oomdPressureLimit`               | … when pressure stays above this for 20 s, before the box thrashes |

  70 % of 8 GB leaves about 2.4 GB for the system, enough for the Nix evaluation of the upgrade. CPU: `user.slice` and `system.slice` have equal weight, so the upgrade gets at least half the CPU under contention.

- **Verification (VM test):** slice properties, `memory.max` set in cgroupfs, the SSH session of `claude` lies inside the slice, and a fork bomb hits `TasksMax`.
- **Residual risk:** the Nix daemon (R3); system services that run as `claude` (token check, home seeding) are in `system.slice` (R10).

### M2 – No LAN access for `claude`

- **Threats:** T1b. A hijacked agent cannot reach the router UI, the NAS, the Mac or VPN peers.
- **Specification:** `IPAddressDeny` on the slice, enforced by cgroup BPF on every packet, in both directions:
  - static (generator, active from boot): `10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16 fc00::/7 fe80::/10 224.0.0.0/4 ff00::/8`;
  - dynamic (`claude-box-lan-guard`, at boot and every 2 min): every route in the main table except the default route, i.e. every directly attached network. This covers the ISP-delegated global IPv6 prefix of the LAN, which no static list can.

  Allowed: the internet (Claude needs it), localhost (the DNS stub, local dev servers). Inbound SSH keeps working: an accepted connection belongs to the cgroup of the listening sshd. Exceptions: `box.hardening.lanIsolation.allow`. Disable: `box.hardening.lanIsolation.enable = false`.

- **Verification (VM test):** the `lan` node serves HTTP. Root on the box reaches it over IPv4 and IPv6; `claude`, in a real SSH session, reaches neither; `claude` still reaches `127.0.0.1`.
- **Residual risk:** exfiltration to the internet (R1); the Nix daemon (R3); a new IPv6 prefix is open for up to 2 min (R5).

### M3 – No durable remote access for a hijacked agent

- **Threats:** T1c, T1d.
- **Specification:**
  - `services.openssh.authorizedKeysInHomedir = false`: sshd reads keys only from `/etc/ssh/authorized_keys.d/%u`, i.e. from the Nix configuration. A key that the agent writes to `~/.ssh/authorized_keys` is ignored, so revoking the token really ends the attacker's access.
  - `AllowAgentForwarding no`: `install.sh` configures the same key for `claude` and `admin`, so an agent forwarded into a `claude` session would let the agent log in as admin, i.e. root. Option: `box.hardening.agentForwarding`.
- **Verification (VM test):** `sshd_config` contains both settings; a key planted in `~/.ssh/authorized_keys` is refused, the configured key works.
- **Residual risk:** other persistence inside the home directory is possible but recorded (R6).

### M4 – Kernel audit trail of everything `claude` executes

- **Threats:** T1 detection and forensics (T1c, T1f).
- **Specification:** auditd with the rules `-a always,exit -S execve,execveat -F uid=claude -k claude-exec` (64- and 32-bit). It catches every program, from every session or service, including ones started by Claude's tools.
  - Stored in `/var/log/audit` (mode 0700, root only), rotated at 10 × 50 MB.
  - `systemd-journald-audit.socket` is masked, so an execve flood cannot push the upgrade and notify logs out of journald (capped at 500 MB).
  - Not added: a watch on the token file. sops-nix replaces the `/run/secrets` directory on every switch, so the watch would go stale after the first upgrade, and the token is in the process environment anyway.
- **Verification (VM test):** the rule is loaded, a command run by `claude` over SSH appears in `ausearch -k claude-exec`, and the journald audit socket is masked.
- **Residual risk:** an agent can rotate the log by executing in a loop (R4); file writes without an exec are not recorded.

### M5 – Continuous resource history and alerts

- **Threats:** T2, T1e. This is the "permanent CPU and memory monitoring", reduced to what someone will actually look at.
- **Specification:**
  - `below` records CPU, memory, IO and pressure per cgroup every 5 s, compressed, kept 14 days or 1 GiB.
  - `claude-box-watch` (every 5 min, root) pushes an ntfy alert, each condition once until it clears:

    | Alert                          | Source                                | Default (`box.monitoring.watch.*`)                  |
    | ------------------------------ | ------------------------------------- | --------------------------------------------------- |
    | claude hit its memory limit    | `memory.events` → `oom_kill` grew     | –                                                   |
    | systemd-oomd killed processes  | journal of `systemd-oomd`             | –                                                   |
    | claude hit its task limit      | `pids.events` → `max` grew            | –                                                   |
    | claude used the CPU for 60 min | `cpu.stat` average since the last run | `cpuMillicores = 3500` (of 4000), `cpuMinutes = 60` |
    | root filesystem N % full       | `df /`                                | `diskPercent = 90`                                  |

    The alerts include the top processes of `claude`. A failed watchdog run is itself notified (`notify-failure@`).
- **Verification (VM test):** `below` runs; the watchdog sends the disk alert (threshold lowered) and the task-limit alert after the fork bomb.
- **Not verified:** the CPU alert (time-based), the oomd path, the overhead on the real N3150 (A6).

## 7. Owner actions (not enforceable on the box)

| ID  | Action                                                                                                                                                                                                                                                                                                                                                              | Why                                                                                          |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| O1  | **Never log in on the box (`gh auth login`, git credentials, SSH deploy keys) with an identity that can push to this repository.** Use a fine-grained token restricted to the repositories Claude works on, or a separate account. Alternative: a ruleset on `main` that only lets GitHub Actions push directly; that ends the owner's own direct pushes to `main`. | A push to `main` is root on the box within a day. This is the shortest path from T1 to root. |
| O2  | Do not forward the SSH agent to the box (now refused anyway). Consider separate keys for `claude` and `admin` in `install.sh`.                                                                                                                                                                                                                                      | B1 currently depends on the same key.                                                        |
| O3  | After any suspicion: stop the slice (see §9), revoke and rotate the Claude token (`bootstrap.sh --secrets`) and every token `claude` held.                                                                                                                                                                                                                          | A3: those credentials must be considered leaked.                                             |
| O4  | With NetBird: restrict ACLs so peers reach only SSH on the box.                                                                                                                                                                                                                                                                                                     | M2 only covers outbound traffic of `claude`.                                                 |

## 8. Residual risks and non-goals

| ID  | Residual risk                                                                                                                                                    | Possible next step                                                                                                      |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| R1  | Exfiltration to the internet: anything `claude` can read can leave the box.                                                                                      | Enable the Claude Code sandbox with a network allowlist once it is verified inside the FHS wrapper; or an egress proxy. |
| R2  | The token is exposed to every process of `claude` (A3).                                                                                                          | O3; short rotation.                                                                                                     |
| R3  | `claude` can submit builds to the Nix daemon (root, `system.slice`): bypasses M1, and fixed-output fetches reach any address (bypasses M2).                      | `nix.settings.allowed-users = [ "root" "@wheel" ]` (ends `nix shell` for Claude).                                       |
| R4  | No off-box copy of the audit log; looping execs rotate it, `logger` can flood journald.                                                                          | Remote log shipping when a log host exists (A5).                                                                        |
| R5  | A new on-link IPv6 prefix is reachable for up to 2 min; LAN segments only reachable through the default route are not covered.                                   | Shorter interval or a networkd dispatcher hook.                                                                         |
| R6  | Persistence inside the home directory (shell rc, user units with linger, Claude hooks, `CLAUDE.md`, git hooks) is not prevented, only recorded when it executes. | Periodic diff of these files; managed Claude settings.                                                                  |
| R7  | Kernel exploits; unprivileged user namespaces stay on because the FHS wrapper needs them.                                                                        | Weekly flake update (existing).                                                                                         |
| R8  | `claude` can fill the disk to 95 % (ext4 reserve, A10); its own work fails before the system's.                                                                  | Separate `/home` (needs reinstall).                                                                                     |
| R9  | Detection latency: 5 min watchdog, 60 min for the CPU alert.                                                                                                     | Tune `box.monitoring.watch.*`.                                                                                          |
| R10 | System services that run as `claude` (`claude-box-token-check`, `claude-seed-home`) are outside the slice.                                                       | They run fixed code from the configuration; acceptable.                                                                 |
| R11 | Physical theft (T5).                                                                                                                                             | Disk encryption with TPM or network unlock (needs reinstall).                                                           |

## 9. Operations

| Task                        | Command (as admin)                                                                                                                        |
| --------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| Limits and policy in effect | `systemctl show user-$(id -u claude).slice -p MemoryHigh -p MemoryMax -p TasksMax -p IPAddressDeny`                                       |
| Live usage per cgroup       | `systemd-cgtop user.slice` or `sudo below live`                                                                                           |
| Usage in the past           | `sudo below replay -t "3h ago"`                                                                                                           |
| What did Claude run?        | `sudo ausearch --input-logs -i -k claude-exec --start today \| less`, summary: `sudo aureport --input-logs -x --summary -i --start today` |
| Watchdog                    | `journalctl -u claude-box-watch`, state in `/var/lib/claude-box-watch`                                                                    |
| Stop Claude immediately     | `sudo systemctl stop user-$(id -u claude).slice` (kills every process of `claude`; SSH as admin is unaffected)                            |
| After suspected compromise  | stop the slice, O3, read `ausearch`, look for persistence in `~claude` (R6), reinstall if in doubt (`README.md`)                          |

## 10. Review triggers

Revisit this document when `claude` gets new credentials, NetBird is enabled,
new services or users are added, a log host becomes available (A5), or the
Claude Code sandbox becomes viable inside the FHS wrapper (R1).
