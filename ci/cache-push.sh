#!/usr/bin/env bash
# Pushes a built profile to the public binary cache, leaving out unfree
# packages that are not marked redistributable.
#
#   ci/cache-push.sh <profile>
#
# The profile's system must already be built (the script builds it if it
# is not). Set DRY_RUN=1 to print what would be pushed without pushing.
#
# What is left out:
#   1. every derivation ci/unfree-report.nix reports as `blocked`: an
#      unfree package with a licence nixpkgs does not mark redistributable
#      (claude-code today);
#   2. every derivation that depends on one of those, at build time or at
#      run time. That covers a path that copies or wraps the package, and
#      it means nothing pushed can reference a path that was left out.
#
# Unfree packages nixpkgs marks redistributable (the NVIDIA driver) are
# pushed. Paths already in cache.nixos.org are skipped by cachix itself.
#
# The script stops without pushing when it cannot tell what to leave out:
# the report came from a different system, or a blocked package matches no
# derivation of the system.
set -euo pipefail

if [ -z "${1:-}" ]; then
  echo "Usage: $0 <profile>" >&2
  exit 1
fi

PROFILE="$1"
CACHE="${CACHIX_CACHE:-machine0}"

cd "$(dirname "$0")/.."

export NIX_CONFIG="extra-experimental-features = nix-command flakes
${NIX_CONFIG:-}"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

ATTR=".#nixosConfigurations.${PROFILE}.config.system.build.toplevel"
DRV=$(nix eval --raw "${ATTR}.drvPath")

REPORT_DRV=$(nix eval --impure --raw --expr \
  "import ./ci/unfree-report.nix { flake = builtins.getFlake (toString ./.); profile = \"${PROFILE}\"; }" \
  2>"$WORK/report")

if [ "$REPORT_DRV" != "$DRV" ]; then
  echo "unfree report describes $REPORT_DRV, not the system $DRV; nothing pushed" >&2
  exit 1
fi

{ grep -o 'M0-UNFREE .*' "$WORK/report" || true; } | sort -u >"$WORK/unfree"
sed -n 's/^M0-UNFREE blocked //p' "$WORK/unfree" >"$WORK/blocked-names"

echo "unfree packages in ${PROFILE}:"
sed 's/^M0-UNFREE /  /' "$WORK/unfree"

# Every derivation the system is built from.
nix-store --query --requisites "$DRV" | grep '\.drv$' >"$WORK/drvs"

# The blocked packages' derivations, matched by exact derivation name.
: >"$WORK/blocked-drvs"
while IFS= read -r name; do
  awk -v want="${name}.drv" \
    '{ base = $0; sub(/^\/nix\/store\/[a-z0-9]+-/, "", base) } base == want' \
    "$WORK/drvs" >"$WORK/match"
  if [ ! -s "$WORK/match" ]; then
    echo "blocked package ${name} matches no derivation of the system; nothing pushed" >&2
    exit 1
  fi
  cat "$WORK/match" >>"$WORK/blocked-drvs"
done <"$WORK/blocked-names"

# Those derivations, everything that depends on them, and their outputs.
: >"$WORK/blocked-outputs"
if [ -s "$WORK/blocked-drvs" ]; then
  xargs nix-store --query --referrers-closure <"$WORK/blocked-drvs" | grep '\.drv$' | sort -u >"$WORK/blocked-closure"
  sed 's/$/^*/' "$WORK/blocked-closure" | xargs nix derivation show |
    grep -oE '"path": *"[^"]+"' | grep -oE '/nix/store/[^"]+' | sort -u >"$WORK/blocked-outputs"
fi

OUT=$(nix build "$ATTR" --no-link --print-out-paths)
nix-store --query --requisites "$OUT" | sort -u >"$WORK/closure"
comm -23 "$WORK/closure" "$WORK/blocked-outputs" >"$WORK/push"

# cachix pushes the closure of what it is given, so check that closure too.
xargs nix-store --query --requisites <"$WORK/push" | sort -u >"$WORK/push-closure"
if [ -n "$(comm -12 "$WORK/push-closure" "$WORK/blocked-outputs")" ]; then
  echo "a path to push references a blocked path; nothing pushed:" >&2
  comm -12 "$WORK/push-closure" "$WORK/blocked-outputs" >&2
  exit 1
fi

echo "closure: $(wc -l <"$WORK/closure") paths, left out: $(comm -12 "$WORK/closure" "$WORK/blocked-outputs" | wc -l), to push: $(wc -l <"$WORK/push")"
comm -12 "$WORK/closure" "$WORK/blocked-outputs" | sed 's/^/  left out: /'

if [ -n "${DRY_RUN:-}" ]; then
  echo "DRY_RUN set; nothing pushed"
  exit 0
fi

cachix push "$CACHE" <"$WORK/push"
