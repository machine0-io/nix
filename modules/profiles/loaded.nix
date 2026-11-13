# Loaded profile — base + dev stack. Build tools, language runtimes,
# AI agents, rootless Docker, npm, clone-repos-on-init, and a Home
# Manager-driven shell (zsh + starship + zoxide + eza + screen) for the
# `nix` user.
{
  config,
  pkgs,
  lib,
  ...
}:
{
  imports = [
    ./base.nix
    ../development/packages.nix
    ../development/services.nix
    ../development/clone-repos.nix
    ../home
  ];

  machine0.profile.loaded = true;

  # Login shell switches to zsh in the loaded profile. mkForce because
  # core/users.nix sets shell at the same priority.
  users.users.nix.shell = lib.mkForce pkgs.zsh;

  # Sets ~/.gitconfig's [user] identity from the machine0 profile's
  # GIT_USER_NAME/GIT_USER_EMAIL (~/.machine0/env.sh, same inject payload as
  # CLONE_REPOS_ON_INIT in ../development/clone-repos.nix) so a first `git commit`/push
  # doesn't hit git's "Please tell me who you are" prompt. After (not
  # Requires): a VM without a payload, or without these vars set, must still
  # boot clean — git simply stays unconfigured until a real commit needs it.
  systemd.services.machine0-git-identity = {
    description = "Set git user.name/user.email from the profile's GIT_USER_NAME/GIT_USER_EMAIL";
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.git ];
    script = ''
      set -eu
      ENV_FILE="$HOME/.machine0/env.sh"
      if [ ! -r "$ENV_FILE" ]; then
        echo "$ENV_FILE not present; nothing to do"
        exit 0
      fi
      # shellcheck disable=SC1090
      . "$ENV_FILE"
      if [ -n "''${GIT_USER_NAME:-}" ]; then
        git config --global user.name "$GIT_USER_NAME"
      fi
      if [ -n "''${GIT_USER_EMAIL:-}" ]; then
        git config --global user.email "$GIT_USER_EMAIL"
      fi
    '';
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "nix";
      Group = "users";
    };
    unitConfig = {
      After = [ "machine0-profile-inject.service" ];
    };
  };

  # Normal priority (100) overrides base's mkDefault (1000).
  machine0.motd.text = import ../../lib/mkMotd.nix {
    title = "[ m0 ] NixOS ${config.system.nixos.release} · Loaded";
    body = [
      "Built with the #loaded profile, fork to customize:"
      "-> https://github.com/machine0-io/nix"
    ];
  };
}
