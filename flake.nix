{
  description = "machine0 NixOS images — base, loaded, openclaw, hermes, gpu";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Agent profiles. Both pin nixos-unstable upstream; we deliberately do
    # NOT make them follow our 26.05 nixpkgs to avoid eval breakage.
    nix-openclaw.url = "github:openclaw/nix-openclaw";
    hermes-agent.url = "github:NousResearch/hermes-agent";
  };

  outputs =
    inputs@{ self, nixpkgs, ... }:
    let
      system = "x86_64-linux";

      mkSystem = import ./lib/mksystem.nix {
        inherit nixpkgs inputs system;
        stateVersion = "26.05";
      };

      mkImage = import ./lib/mkimage.nix { inherit mkSystem; };

      # Each profile is the list of modules layered to produce that system.
      profiles = {
        base = [ ./modules/profiles/base.nix ];
        loaded = [ ./modules/profiles/loaded.nix ];
        openclaw = [ ./modules/profiles/openclaw.nix ];
        hermes = [ ./modules/profiles/hermes.nix ];
        gpu = [ ./modules/profiles/gpu.nix ];
      };
    in
    {
      packages.${system} = builtins.mapAttrs (_: mkImage) profiles // {
        default = self.packages.${system}.loaded;
      };

      nixosConfigurations = builtins.mapAttrs (_: mkSystem) profiles // {
        default = self.nixosConfigurations.loaded;
      };

      # Reusable builders. mkSystem/mkImage are closed over this flake's
      # inputs; consumers pass a module list:
      #   machine0.lib.mkSystem [ machine0.nixosModules.loaded ./mine.nix ]
      # mkMotd is the pure banner builder ({ title, body ? [], width ? null }
      # -> string) used by the profiles' MOTDs, exported so consumer profiles
      # can build a styled banner instead of a plain string.
      lib = {
        inherit mkSystem mkImage;
        mkMotd = import ./lib/mkMotd.nix;
      };

      # Profile entry-point modules (each imports its full parent chain).
      # These require machine0.lib.mkSystem — they read machine0-specific
      # specialArgs and will not evaluate under a plain nixosSystem.
      nixosModules =
        builtins.mapAttrs (
          name: modules:
          nixpkgs.lib.setDefaultModuleLocation "machine0-nixos#nixosModules.${name}" {
            imports = modules;
          }
        ) profiles
        // {
          default = self.nixosModules.loaded;
        };

      # Eval-only guards for the exported consumer API (lib + nixosModules),
      # one per profile plus the image path. Each check is a trivial
      # runCommand whose *instantiation* forces the full system eval, so
      # `nix flake check` and the CI drvPath step both catch API regressions
      # without ever building a system or disk image.
      checks.${system} =
        let
          pkgs = nixpkgs.legacyPackages.${system};
          evalGuard =
            name: drv:
            pkgs.runCommand "consumer-api-${name}" { } ''
              echo "${builtins.unsafeDiscardStringContext drv.drvPath}" > "$out"
            '';

          expect =
            name: cond: msg:
            if cond then true else throw "checks.${system}.${name}: ${msg}";

          # Per-profile contract assertions, forced before the guard's
          # derivation so they ride on the system eval the guard already does.
          #
          # Value: protects=machine0-clone-repos unit exists on loaded,
          #   openclaw, hermes and is absent on base and gpu;
          #   fails_when=clone-repos.nix import is dropped from loaded.nix or
          #   added to base.nix; why_new=eval guards only prove the system
          #   evaluates, not which units it carries; seam=none;
          #   no_claim=the unit's clone script behaviour at boot (eval only,
          #   nothing is built or run)
          # Value: protects=cl and clc zsh aliases exist for the nix user on
          #   every loaded-derived profile and set CLAUDE_CODE_SANDBOXED=1;
          #   fails_when=the aliases are removed from home/nix-user.nix or
          #   moved back to a dev-only module; why_new=no check reads Home
          #   Manager shell aliases; seam=none; no_claim=that claude accepts
          #   these flags or that the alias works in a live shell (eval only)
          profileContracts =
            name: cfg:
            let
              # Set by loaded.nix, so true exactly on loaded-derived profiles.
              isLoadedPlus = cfg.machine0.profile.loaded;
              aliases = cfg.home-manager.users.nix.programs.zsh.shellAliases;
              launcher = alias: nixpkgs.lib.hasInfix "CLAUDE_CODE_SANDBOXED=1 claude" (aliases.${alias} or "");
            in
            [
              (expect name (
                (cfg.systemd.services ? machine0-clone-repos) == isLoadedPlus
              ) "machine0-clone-repos must be present on loaded-derived profiles and absent elsewhere")
              (expect name (
                !isLoadedPlus || (launcher "cl" && launcher "clc" && nixpkgs.lib.hasSuffix "--continue" aliases.clc)
              ) "cl/clc claude launcher aliases must exist on loaded-derived profiles")
              (expect name (nixpkgs.lib.hasPrefix "github:machine0-io/nix" cfg.system.autoUpgrade.flake)
                "nightly auto-upgrade must track this repo on every profile"
              )
            ];
        in
        builtins.mapAttrs (
          name: _:
          (
            sys:
            builtins.deepSeq (profileContracts name sys.config) (
              evalGuard name sys.config.system.build.toplevel
            )
          )
            (mkSystem [
              self.nixosModules.${name}
              {
                # Route the override through self.lib.mkMotd so the eval
                # guards also pin the exported banner-builder API (every
                # body-line convention: plain, blank, command, comment, link).
                machine0.motd.text = nixpkgs.lib.mkOverride 10 (
                  self.lib.mkMotd {
                    title = "consumer-api check";
                    body = [
                      "plain line"
                      ""
                      "$ machine0 ssh check"
                      "# dim comment"
                      "-> machine0.io"
                    ];
                  }
                );
                system.autoUpgrade.enable = nixpkgs.lib.mkForce false;
              }
            ])
        ) profiles
        // {
          consumer-image = evalGuard "image" (mkImage [ self.nixosModules.base ]);
        };
    };
}
