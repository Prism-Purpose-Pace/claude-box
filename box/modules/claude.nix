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
    exec ${pkgs.claude-code-box}/bin/claude "$@"
  '';

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
    pkgs.claude-smoke-test
  ]
  ++ (with pkgs; [
    tmux
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
    '';
  };

  sops.secrets.claude_oauth_token = lib.mkIf config.box.hasSecrets {
    owner = "claude";
    mode = "0400";
  };
}
