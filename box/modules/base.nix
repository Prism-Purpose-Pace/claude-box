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
    # ---- Boot ----------------------------------------------------------------
    boot.loader.systemd-boot = {
      enable = true;
      configurationLimit = 10; # rollback targets in the boot menu
      editor = false;
    };
    boot.loader.efi.canTouchEfiVariables = true;
    boot.tmp.cleanOnBoot = true;

    # ---- Network -------------------------------------------------------------
    networking.useNetworkd = true;
    networking.useDHCP = true; # both GbE ports, whichever has a cable
    networking.wireless.enable = false;
    networking.firewall.enable = true;

    # Reachable as claude-box.local from the Mac, independent of the DHCP address.
    services.avahi = {
      enable = true;
      nssmdns4 = true;
      publish = {
        enable = true;
        addresses = true;
      };
    };

    time.timeZone = "Europe/Berlin";
    i18n.defaultLocale = "en_US.UTF-8";
    console.keyMap = "de";

    # ---- Access --------------------------------------------------------------
    services.openssh = {
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

    users.mutableUsers = false;
    users.users.admin = {
      isNormalUser = true;
      description = "Administration (sudo)";
      extraGroups = [ "wheel" ];
      openssh.authorizedKeys.keys = config.box.sshKeys;
    };
    # No passwords exist on this machine; sudo is protected by the SSH key.
    security.sudo.wheelNeedsPassword = false;
    security.sudo.execWheelOnly = true;

    # ---- Nix -----------------------------------------------------------------
    nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "claude" ];
    nix.settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      trusted-users = [ "admin" ];
      auto-optimise-store = true;
    };
    nix.gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 21d";
    };
    nix.channel.enable = false;

    # ---- Housekeeping --------------------------------------------------------
    zramSwap.enable = true;
    services.fstrim.enable = true;
    services.journald.extraConfig = "SystemMaxUse=500M";

    environment.systemPackages = with pkgs; [
      vim
      htop
      git
      curl
      lm_sensors
    ];

    # ---- Secrets -------------------------------------------------------------
    # Decrypted on the box with its own SSH host key (age recipient set by bootstrap.sh).
    sops = lib.mkIf config.box.hasSecrets {
      defaultSopsFile = secretsFile;
      age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    };
  };
}
