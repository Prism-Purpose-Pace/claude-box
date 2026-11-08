{ config, lib, ... }:
let
  mode = config.box.remoteAccess;
in
{
  options.box.remoteAccess = lib.mkOption {
    type = lib.types.enum [
      "none"
      "netbird"
    ];
    default = "none";
    description = ''
      How the box is reached from outside the LAN.
      "none": LAN only. FritzBox WireGuard also uses this, it needs nothing on the box.
      "netbird": NetBird client, enrolled with a setup key from secrets.
    '';
  };

  config = lib.mkIf (mode == "netbird") {
    assertions = [
      {
        assertion = config.box.hasSecrets;
        message = "box.remoteAccess = \"netbird\" needs secrets/secrets.yaml with netbird_setup_key (run scripts/bootstrap.sh).";
      }
    ];

    sops.secrets.netbird_setup_key = { };

    services.netbird.clients.wt0 = {
      port = 51820;
      openFirewall = true;
      login = {
        enable = true;
        setupKeyFile = config.sops.secrets.netbird_setup_key.path;
      };
    };
  };
}
