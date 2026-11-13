# Clone-repos-on-init — imported by loaded.nix, so every loaded+ profile has it.
#
# VMs created with a machine0 profile that carries CLONE_REPOS_ON_INIT
# (comma-separated `owner/repo` slugs or full git URLs, e.g.
# `machine0 new dev --image nixos-26-05-loaded --profile engineering`) get
# those repos cloned into ~/Projects at boot. Without the variable the unit is
# a no-op, so the images also work profile-less.
{ pkgs, ... }:
{
  # Clones happen after machine0-profile-inject because both inputs come
  # from the inject payload: CLONE_REPOS_ON_INIT (~/.machine0/env.sh) and
  # the GitHub credential (~/.config/gh/hosts.yml + the gh credential
  # helper in ~/.gitconfig) that private clones authenticate through.
  # After (not Requires): a VM without a payload must still boot clean.
  systemd.services.machine0-clone-repos = {
    description = "Clone CLONE_REPOS_ON_INIT repos into ~/Projects";
    wantedBy = [ "multi-user.target" ];
    path = [
      pkgs.git
      pkgs.gh
    ];
    # Never prompt for credentials — fail the clone instead of hanging.
    environment.GIT_TERMINAL_PROMPT = "0";
    script = ''
      set -eu
      ENV_FILE="$HOME/.machine0/env.sh"
      if [ ! -r "$ENV_FILE" ]; then
        echo "$ENV_FILE not present; nothing to do"
        exit 0
      fi
      # shellcheck disable=SC1090
      . "$ENV_FILE"
      if [ -z "''${CLONE_REPOS_ON_INIT:-}" ]; then
        echo "CLONE_REPOS_ON_INIT not set; nothing to do"
        exit 0
      fi

      mkdir -p "$HOME/Projects"
      failed=0
      # Destination -> URL claimed in this run, to catch name collisions.
      declare -A claimed=()
      IFS=',' read -ra repos <<< "$CLONE_REPOS_ON_INIT"
      for repo in "''${repos[@]}"; do
        # Trim surrounding whitespace; skip empty entries.
        repo="''${repo#"''${repo%%[![:space:]]*}"}"
        repo="''${repo%"''${repo##*[![:space:]]}"}"
        [ -n "$repo" ] || continue

        case "$repo" in
          # Full URLs and git's scp-like form (git@host:owner/repo.git).
          *://* | *@*:*) url="$repo" ;;
          *) url="https://github.com/$repo.git" ;;
        esac
        # Last path component; the scp-like form may have no slash at all
        # (git@host:repo.git), so also drop everything up to the last colon.
        name="$(basename "$repo" .git)"
        dest="$HOME/Projects/''${name##*:}"

        # Two different sources with the same final name would share one
        # destination; without this the second is skipped as already cloned.
        if [ -n "''${claimed[$dest]:-}" ]; then
          if [ "''${claimed[$dest]}" != "$url" ]; then
            echo "FAILED: $url and ''${claimed[$dest]} both map to $dest; not cloning $url"
            failed=1
          fi
          continue
        fi
        claimed[$dest]="$url"

        if [ -e "$dest" ]; then
          echo "skipping $repo: $dest already exists"
          continue
        fi
        echo "cloning $url -> $dest"
        if ! git clone "$url" "$dest"; then
          echo "FAILED to clone $url"
          failed=1
        fi
      done
      # A failed unit is visible in systemctl and retries on the next boot;
      # already-cloned repos are skipped, so reruns stay cheap.
      exit "$failed"
    '';
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "nix";
      Group = "users";
    };
    unitConfig = {
      After = [
        "machine0-profile-inject.service"
        "network-online.target"
      ];
      Wants = [ "network-online.target" ];
    };
  };
}
