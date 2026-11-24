# Lists the unfree packages a profile instantiates, for ci/cache-push.sh.
#
# nixpkgs decides what is unfree in one place (check-meta), and asks
# `allowUnfreePredicate` about every unfree package it is about to
# instantiate. This re-evaluates the profile with `allowUnfree` off and a
# predicate that allows everything but traces each package it is asked
# about, so the report covers exactly the unfree packages in the system,
# including ones reached only through another package.
#
# Evaluating the result prints one line per package on stderr:
#
#   trace: M0-UNFREE <redistributable|blocked> <derivation name>
#
# and returns the drvPath of the system. nixpkgs config never enters a
# derivation, so that drvPath must equal the profile's own; the caller
# checks it, which catches a report made from a different system.
#
# Not covered: packages built by another flake's own nixpkgs instance
# (nix-openclaw, hermes-agent). Their unfree packages, if any, are not
# reported here.
#
#   nix eval --impure --raw --expr \
#     'import ./ci/unfree-report.nix { flake = builtins.getFlake (toString ./.); profile = "loaded"; }'
{ flake, profile }:
let
  inherit (flake.inputs.nixpkgs) lib;
  system = flake.nixosConfigurations.${profile};

  # A package may be pushed to the public cache when every unfree licence
  # it carries is marked redistributable. Anything that is not a licence
  # attrset (a bare string, a missing field) counts as not redistributable.
  redistributable =
    license:
    builtins.isAttrs license && ((license.free or false) || (license.redistributable or false));

  report =
    pkg:
    let
      name = pkg.name or "${pkg.pname or "unnamed"}-${pkg.version or "unversioned"}";
      verdict =
        if lib.all redistributable (lib.toList (pkg.meta.license or [ ])) then
          "redistributable"
        else
          "blocked";
    in
    builtins.trace "M0-UNFREE ${verdict} ${name}" true;

  traced = system.extendModules {
    modules = [
      {
        nixpkgs.config = lib.mkForce (
          system.config.nixpkgs.config
          // {
            allowUnfree = false;
            allowUnfreePredicate = report;
          }
        );
      }
    ];
  };
in
# The report is evaluated with --impure, and in impure mode nixpkgs reads
# NIXPKGS_ALLOW_UNFREE: set to 1, it allows every unfree package without
# asking the predicate, and the report comes out empty.
assert lib.assertMsg (
  builtins.getEnv "NIXPKGS_ALLOW_UNFREE" != "1"
) "unfree-report: unset NIXPKGS_ALLOW_UNFREE, it hides every unfree package from this report";
traced.config.system.build.toplevel.drvPath
