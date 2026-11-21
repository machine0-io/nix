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
          # Value: protects=the gpu profile, and only it, declares itself a
          #   GPU image (machine0.image.gpu, published in
          #   /etc/machine0/image.json); fails_when=the declaration is dropped
          #   from hardware/nvidia.nix, set on a non-GPU profile, or the file
          #   is removed or its `gpu` key renamed;
          #   why_new=nothing else reads the marker; seam=none;
          #   no_claim=that the machine0 platform reads the file or acts on it
          # Value: protects=machine0-install-skills unit exists on loaded,
          #   openclaw, hermes, is absent on base and gpu, and installs for
          #   both Claude Code and Codex; fails_when=install-skills.nix import
          #   is dropped from loaded.nix or added to base.nix, or either
          #   `--agent` flag is removed from the unit's script; why_new=no
          #   check reads this unit; seam=none; no_claim=that the skills CLI
          #   accepts these flags or that an install succeeds at boot (eval
          #   only, nothing is built or run)
          # Value: protects=machine0-install-skills starts only after
          #   machine0-profile-inject, the unit that writes the env file it
          #   reads; fails_when=the ordering is dropped, so on first boot the
          #   unit can run before the file exists, log "nothing to do" and
          #   exit 0 with no skills installed; why_new=the presence check
          #   passes with or without the ordering; seam=none; no_claim=that
          #   systemd honours it at boot or that the payload carries the
          #   variable (eval only)
          # Value: protects=the `skills` CLI is on the system path of
          #   loaded-derived profiles, so the documented `skills update -g`
          #   works in a user shell; fails_when=it is dropped from
          #   environment.systemPackages while staying on the unit's own
          #   path; why_new=the unit keeps evaluating and installing without
          #   it; seam=none; no_claim=which nixpkgs the package comes from or
          #   that the binary runs (eval only)
          profileContracts =
            name: cfg:
            let
              # Set by loaded.nix, so true exactly on loaded-derived profiles.
              isLoadedPlus = cfg.machine0.profile.loaded;
              aliases = cfg.home-manager.users.nix.programs.zsh.shellAliases;
              launcher = alias: nixpkgs.lib.hasInfix "CLAUDE_CODE_SANDBOXED=1 claude" (aliases.${alias} or "");
              isGpu = name == "gpu";
              # What the platform reads is the published file, not the option.
              imageJson = builtins.fromJSON (cfg.environment.etc."machine0/image.json".text or "{}");
              installSkills = cfg.systemd.services.machine0-install-skills or { };
              installSkillsScript = installSkills.script or "";
              # Either spelling of the ordering counts: `after` or unitConfig.After.
              installSkillsUnitAfter = installSkills.unitConfig.After or [ ];
              installSkillsAfter = (installSkills.after or [ ]) ++ installSkillsUnitAfter;
              systemPackageNames = map nixpkgs.lib.getName cfg.environment.systemPackages;
              hasSkillsCli = builtins.elem "skills" systemPackageNames;
            in
            [
              (expect name
                (
                  (cfg.systemd.services ? machine0-install-skills) == isLoadedPlus
                  && (
                    !isLoadedPlus
                    || (
                      nixpkgs.lib.hasInfix "--agent claude-code" installSkillsScript
                      && nixpkgs.lib.hasInfix "--agent codex" installSkillsScript
                    )
                  )
                )
                "machine0-install-skills must be present on loaded-derived profiles, targeting Claude Code and Codex, and absent elsewhere"
              )
              (expect name (
                !isLoadedPlus || builtins.elem "machine0-profile-inject.service" installSkillsAfter
              ) "machine0-install-skills must start after machine0-profile-inject")
              (expect name (
                hasSkillsCli == isLoadedPlus
              ) "the skills CLI must be on the system path on loaded-derived profiles only")
              (expect name (
                (cfg.systemd.services ? machine0-clone-repos) == isLoadedPlus
              ) "machine0-clone-repos must be present on loaded-derived profiles and absent elsewhere")
              (expect name (
                !isLoadedPlus || (launcher "cl" && launcher "clc" && nixpkgs.lib.hasSuffix "--continue" aliases.clc)
              ) "cl/clc claude launcher aliases must exist on loaded-derived profiles")
              (expect name (nixpkgs.lib.hasPrefix "github:machine0-io/nix" cfg.system.autoUpgrade.flake)
                "nightly auto-upgrade must track this repo on every profile"
              )
              (expect name (
                cfg.machine0.image.gpu == isGpu && (imageJson.gpu or null) == isGpu
              ) "machine0.image.gpu must be true, and published in /etc/machine0/image.json, on gpu only")
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
