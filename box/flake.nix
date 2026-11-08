{
  description = "claude-box: unattended NixOS host running Claude Code (Zotac ZBOX CI323 nano)";

  inputs = {
    # channels.nixos.org only advances after Hydra has built and tested the
    # channel, so everything is in cache.nixos.org and the box never compiles.
    nixpkgs.url = "https://channels.nixos.org/nixos-26.05/nixexprs.tar.xz";

    disko = {
      url = "git+https://github.com/nix-community/disko?shallow=1";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "git+https://github.com/Mic92/sops-nix?shallow=1";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      disko,
      sops-nix,
    }:
    let
      system = "x86_64-linux";
      inherit (nixpkgs) lib;

      # The Claude Code package comes from the parent directory (this fork).
      # box/claude-version is only advanced by CI after the version passed the
      # non-AVX smoke test, so the box never sees an untested release.
      claudeVersion = lib.trim (builtins.readFile ./claude-version);
      claudeOverlay = final: _prev: {
        claude-code-box = final.callPackage ../package.nix {
          sourcesFile = ../versions/${claudeVersion + ".json"};
          additionalPaths = [
            "${final.gh}/bin"
            "${final.git}/bin"
            "${final.poppler-utils}/bin"
          ];
        };
        # FHS wrapper: agent teams download helper binaries at runtime that expect
        # /lib64/ld-linux-x86-64.so.2, which NixOS does not provide.
        claude-code-box-fhs = final.callPackage ../package-fhs.nix {
          claude-code = final.claude-code-box;
        };
        claude-smoke-test = final.callPackage ./pkgs/smoke-test.nix { };
      };

      pkgsFor =
        sys:
        import nixpkgs {
          system = sys;
          overlays = [ claudeOverlay ];
          config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "claude" ];
        };
      pkgs = pkgsFor system;
    in
    {
      nixosConfigurations.claude-box = lib.nixosSystem {
        inherit system;
        specialArgs = { inherit self; };
        modules = [
          disko.nixosModules.disko
          sops-nix.nixosModules.sops
          { nixpkgs.overlays = [ claudeOverlay ]; }
          ./hosts/claude-box/configuration.nix
        ];
      };

      packages.${system} = {
        claude = pkgs.claude-code-box;
        smoke-test = pkgs.claude-smoke-test;
        toplevel = self.nixosConfigurations.claude-box.config.system.build.toplevel;
        default = self.packages.${system}.toplevel;
      };

      # Tools the Mac needs for bootstrap/install, pinned with this flake.
      devShells = lib.genAttrs [ "aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux" ] (
        sys:
        let
          p = import nixpkgs { system = sys; };
        in
        {
          default = p.mkShell {
            packages = [
              p.sops
              p.ssh-to-age
              p.nixos-anywhere
              p.git
              p.openssh
            ];
          };
        }
      );

      checks.${system}.vm = import ./tests/vm.nix { inherit pkgs self; };
    };
}
