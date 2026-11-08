{
  config,
  lib,
  pkgs,
  ...
}:
let
  tokenPath = "/run/secrets/claude_oauth_token";

  # `claude` for every login (interactive, `ssh box claude -p …`, tmux, cron):
  # picks up the subscription token from sops unless one is already set.
  claude = pkgs.writeShellScriptBin "claude" ''
    if [ -z "''${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -r ${tokenPath} ]; then
      CLAUDE_CODE_OAUTH_TOKEN="$(< ${tokenPath})"
      export CLAUDE_CODE_OAUTH_TOKEN
    fi
    exec ${pkgs.claude-code-box-fhs}/bin/claude "$@"
  '';

  # Starting configuration of the claude user (Claude Code settings, herdr
  # config), copied from box/home/claude only where a file does not exist yet:
  # changes made on the box are kept, and a reinstall gets the same setup.
  seedHome = pkgs.writeShellScript "claude-seed-home" ''
    set -eu
    cd ${../home/claude}
    find . -type f | while read -r f; do
      [ -e "$HOME/$f" ] || install -D -m 0644 "$f" "$HOME/$f"
    done
  '';

  # herdr plugins to install after a (re)install. Not done on activation:
  # herdr shows a trust preview (commit, build commands, hooks) that you
  # approve per plugin, and third-party code should not run without that.
  herdrPlugins = [
    "persiyanov/herdr-reviewr"
    "tdi/herdr-worktree-setup"
  ];
  herdrPluginInstaller = pkgs.writeShellApplication {
    name = "claude-box-herdr-plugins";
    runtimeInputs = [
      pkgs.herdr
      pkgs.jq
    ];
    text = ''
      [ "$(id -un)" = claude ] || {
        echo "Run this as user claude (ssh claude-box)." >&2
        exit 1
      }
      registry="$HOME/.config/herdr/plugins.json"
      for p in ${lib.escapeShellArgs herdrPlugins}; do
        if [ -f "$registry" ] && jq -e --arg o "''${p%%/*}" --arg r "''${p#*/}" \
          'any(.[]; .source.owner == $o and .source.repo == $r)' "$registry" >/dev/null; then
          echo "already installed: $p"
          continue
        fi
        herdr plugin install "$p"
      done
    '';
  };

  # Skip the first-run wizard so headless use works on a fresh box.
  onboarding = pkgs.writeText "claude.json" (
    builtins.toJSON {
      hasCompletedOnboarding = true;
      theme = "dark";
    }
  );
in
{
  users.users.claude = {
    isNormalUser = true;
    description = "Claude Code (unprivileged)";
    openssh.authorizedKeys.keys = config.box.sshKeys;
    # Keep user services (tmux sessions started via systemd-run --user) alive after logout.
    linger = true;
  };

  environment.systemPackages = [
    claude
    herdrPluginInstaller
    pkgs.claude-smoke-test
  ]
  ++ (with pkgs; [
    tmux
    herdr
    gh
    git
    ripgrep
    fd
    jq
    python3
    nodejs
  ]);

  system.activationScripts.claudeOnboarding = {
    deps = [ "users" ];
    text = ''
      if [ -d /home/claude ] && [ ! -e /home/claude/.claude.json ]; then
        install -m 0600 -o claude -g users ${onboarding} /home/claude/.claude.json
      fi
      if [ -d /home/claude ]; then
        ${pkgs.util-linux}/bin/runuser -u claude -- env HOME=/home/claude ${seedHome} \
          || echo "warning: could not seed /home/claude from box/home/claude" >&2
      fi
    '';
  };

  sops.secrets.claude_oauth_token = lib.mkIf config.box.hasSecrets {
    owner = "claude";
    mode = "0400";
  };
}
