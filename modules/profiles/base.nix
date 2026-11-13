# Base profile — minimal cloud VM. Boot, networking, hardened SSH,
# fail2ban, the metadata-driven systemd services, and a small set of
# always-useful CLI utilities. No dev stack, no MOTD.
{
  config,
  pkgs,
  lib,
  ...
}:
{
  imports = [
    ../core/boot.nix
    ../core/networking.nix
    ../core/nix.nix
    ../core/ssh.nix
    ../core/fail2ban.nix
    ../core/system.nix
    ../core/users.nix
    ../machine0.nix
    ../motd.nix
    ../services/codex-app-server.nix
  ];

  # Banner shown on SSH login.
  # mkDefault so loaded/openclaw/hermes can override at normal priority.
  machine0.motd.text = lib.mkDefault (
    import ../../lib/mkMotd.nix {
      title = "[ m0 ] NixOS ${config.system.nixos.release} · Minimal";
      body = [
        "Built with the #base profile, fork to customize:"
        "-> https://github.com/machine0-io/nix"
      ];
    }
  );

  environment.systemPackages = with pkgs; [
    vim
    git
    curl
    htop
    wget
    tmux
    jq
  ];
}
