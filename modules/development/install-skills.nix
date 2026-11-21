# Install-skills-on-init — imported by loaded.nix, so every loaded+ profile has it.
#
# VMs created with a machine0 profile that carries INSTALL_SKILLS_ON_INIT
# (comma-separated skill sources, e.g. `machine0-io/skills,vercel-labs/agent-skills`)
# get those skills installed for both Claude Code and Codex at boot. Without
# the variable the unit is a no-op, so the images also work profile-less.
#
# Each entry is handed to the `skills` CLI (github.com/vercel-labs/skills), so
# it takes whatever `skills add` takes: `owner/repo`, `owner/repo@skill`, or a
# full git URL. The CLI copies each skill to ~/.agents/skills/<name>, which
# Codex reads, and symlinks ~/.claude/skills/<name> to it for Claude Code.
#
# Not supported: repos that need their own installer. The CLI only copies
# skill folders, so `garrytan/gstack` (root SKILL.md plus a `./setup` that
# builds and registers everything else) yields just its `/gstack` router
# skill. Install those by hand.
{ pkgs, ... }:
{
  # On the system path too, so `skills update -g` / `skills list -g` work for
  # the user — the unit below installs once and never updates.
  environment.systemPackages = [ pkgs.skills ];

  # Installs happen after machine0-profile-inject because both inputs come
  # from the inject payload: INSTALL_SKILLS_ON_INIT (~/.machine0/env.sh) and
  # the GitHub credential (~/.config/gh/hosts.yml + the gh credential helper
  # in ~/.gitconfig) that private sources clone through.
  # After (not Requires): a VM without a payload must still boot clean.
  systemd.services.machine0-install-skills = {
    description = "Install INSTALL_SKILLS_ON_INIT skills for Claude Code and Codex";
    wantedBy = [ "multi-user.target" ];
    path = [
      pkgs.skills
      pkgs.git
      pkgs.gh
    ];
    environment = {
      # Never prompt for credentials — fail the install instead of hanging.
      GIT_TERMINAL_PROMPT = "0";
      # An unattended unit reports nothing to skills.sh (install telemetry
      # and the security-audit lookup both honour this).
      DISABLE_TELEMETRY = "1";
      # Static progress lines: without this the CLI's spinner writes every
      # animation frame into the journal.
      CI = "true";
    };
    script = ''
      set -eu
      ENV_FILE="$HOME/.machine0/env.sh"
      if [ ! -r "$ENV_FILE" ]; then
        echo "$ENV_FILE not present; nothing to do"
        exit 0
      fi
      # shellcheck disable=SC1090
      . "$ENV_FILE"
      if [ -z "''${INSTALL_SKILLS_ON_INIT:-}" ]; then
        echo "INSTALL_SKILLS_ON_INIT not set; nothing to do"
        exit 0
      fi

      # One marker per installed entry: later boots skip it, so a reboot
      # costs no network and never overwrites local edits to a skill.
      STATE_DIR="$HOME/.local/state/machine0/install-skills"
      mkdir -p "$STATE_DIR"
      cd "$HOME"
      failed=0
      IFS=',' read -ra sources <<< "$INSTALL_SKILLS_ON_INIT"
      for source in "''${sources[@]}"; do
        # Trim surrounding whitespace; skip empty entries.
        source="''${source#"''${source%%[![:space:]]*}"}"
        source="''${source%"''${source##*[![:space:]]}"}"
        [ -n "$source" ] || continue

        # A leading dash would be read by the CLI as an option, not a source.
        case "$source" in
          -*)
            echo "FAILED: '$source' is not a skill source"
            failed=1
            continue
            ;;
        esac

        marker="$STATE_DIR/$(printf '%s' "$source" | sha256sum | cut -d' ' -f1)"
        if [ -e "$marker" ]; then
          echo "skipping $source: already installed"
          continue
        fi
        echo "installing $source"
        if skills add "$source" --global --agent claude-code --agent codex --yes < /dev/null; then
          printf '%s\n' "$source" > "$marker"
        else
          echo "FAILED to install $source"
          failed=1
        fi
      done
      # A failed unit is visible in systemctl and retries on the next boot;
      # installed entries are skipped, so reruns stay cheap.
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
