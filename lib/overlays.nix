# Single source of truth for the unstable-nixpkgs overlay. Two forms:
#
#   unstableModule  — a real overlay function used at flake-eval time.
#   unstableText    — the same overlay, hash-pinned, emitted as text into
#                     /etc/nixos/configuration.nix so a runtime rebuild on
#                     the live VM evaluates the *same* nixpkgs-unstable
#                     revision and can't be tricked by a substituted tree.
#
# Both forms must yield the same closure for the inherited attrs.
{ nixpkgsUnstable }:
{
  unstableModule =
    _final: prev:
    let
      # Follow the system's unfree policy (the modules that use this
      # overlay set allowUnfree = true) rather than hard-coding it, so
      # ci/unfree-report.nix also sees the unfree packages taken from
      # unstable.
      unstable = import nixpkgsUnstable {
        inherit (prev.stdenv.hostPlatform) system;
        config = {
          inherit (prev.config) allowUnfree;
          allowUnfreePredicate = prev.config.allowUnfreePredicate or (_: false);
        };
      };
    in
    {
      inherit (unstable) claude-code codex playwright-driver;
    };

  unstableText = ''
    nixpkgs.overlays = [
      (final: prev:
        let
          unstable = import (builtins.fetchTarball {
            url = "https://github.com/NixOS/nixpkgs/archive/${nixpkgsUnstable.rev}.tar.gz";
            sha256 = "${nixpkgsUnstable.narHash}";
          }) { inherit (prev.stdenv.hostPlatform) system; config.allowUnfree = true; };
        in {
          inherit (unstable) claude-code codex playwright-driver;
        })
    ];
    nixpkgs.config.allowUnfree = true;
  '';
}
