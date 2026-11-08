{
  config,
  lib,
  pkgs,
  ...
}:
let
  secretsFile = ../secrets/secrets.yaml;
in
{
  options.box = {
    sshKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "SSH public keys allowed to log in as admin and claude.";
    };
    hasSecrets = lib.mkOption {
      type = lib.types.bool;
      default = builtins.pathExists secretsFile;
      description = "Whether bootstrap.sh has created the encrypted secrets file yet.";
    };
  };

  config = {
    boot = {
      loader.systemd-boot = {
        enable = true;
        configurationLimit = 10; # rollback targets in the boot menu
        editor = false;
      };
      loader.efi.canTouchEfiVariables = true;
      tmp.cleanOnBoot = true;
    };

    networking = {
      useNetworkd = true;
      useDHCP = true; # both GbE ports, whichever has a cable
      wireless.enable = false;
      firewall.enable = true;
    };

    time.timeZone = "Europe/Berlin";
    i18n.defaultLocale = "en_US.UTF-8";
    console.keyMap = "de";

    services = {
      # Reachable as claude-box.local from the Mac, independent of the DHCP address.
      avahi = {
        enable = true;
        nssmdns4 = true;
        publish = {
          enable = true;
          addresses = true;
        };
      };

      openssh = {
        enable = true;
        openFirewall = true;
        settings = {
          PasswordAuthentication = false;
          KbdInteractiveAuthentication = false;
          PermitRootLogin = "no";
          AllowUsers = [
            "admin"
            "claude"
          ];
          X11Forwarding = false;
        };
      };

      fstrim.enable = true;
      journald.extraConfig = "SystemMaxUse=500M";
    };

    users.mutableUsers = false;
    users.users.admin = {
      isNormalUser = true;
      description = "Administration (sudo)";
      extraGroups = [ "wheel" ];
      openssh.authorizedKeys.keys = config.box.sshKeys;
    };
    # No passwords exist on this machine; sudo is protected by the SSH key.
    security.sudo = {
      wheelNeedsPassword = false;
      execWheelOnly = true;
    };

    nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "claude" ];
    nix = {
      settings = {
        experimental-features = [
          "nix-command"
          "flakes"
        ];
        trusted-users = [ "admin" ];
        auto-optimise-store = true;
      };
      gc = {
        automatic = true;
        dates = "weekly";
        options = "--delete-older-than 21d";
      };
      channel.enable = false;
    };

    zramSwap.enable = true;

    environment.systemPackages = with pkgs; [
      vim
      htop
      git
      curl
      lm_sensors
    ];

    # Decrypted on the box with its own SSH host key (age recipient set by bootstrap.sh).
    sops = lib.mkIf config.box.hasSecrets {
      defaultSopsFile = secretsFile;
      age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    };
  };
}
