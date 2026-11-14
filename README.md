# machine0-nixos

The NixOS profiles behind the [machine0](https://machine0.io) system images. Use an image as-is, or build your own from any profile.

### Usage
```bash
# install the machine0 CLI
curl -LsSf https://machine0.io/install.sh | sh

# create a VM from a prebuilt image
machine0 new my-vm --image nixos-26-05-loaded --size medium

# or build your own image from a profile (this repo or your fork)
machine0 images new my-image --flake 'github:machine0-io/nix#loaded'
```

Building from a fork? Every profile auto-upgrades nightly from `github:machine0-io/nix`. Point `system.autoUpgrade.flake` at your fork or disable it, otherwise the VM reverts to this repo's profile overnight.

To build an image file yourself on a NixOS machine, run `./make-image.sh <profile>`. It prints the path of the resulting `.qcow2.gz`.

### Profiles

| Image | Profile | Description |
|---|---|---|
| `nixos-26-05` | `#base` | Minimal NixOS: hardened SSH, fail2ban, basic CLI tools (vim, git, curl, htop, wget, tmux, jq). |
| `nixos-26-05-loaded` | `#loaded` | Base + Claude Code, Codex and the machine0 CLI; build tools and runtimes (Node, Bun, Python, Rust, Go); rootless Docker; zsh; ports 80/443 open. Clones the repos in `CLONE_REPOS_ON_INIT` into `~/Projects` at boot. |
| `nixos-26-05-openclaw` | `#openclaw` | Loaded + [OpenClaw](https://github.com/openclaw/nix-openclaw) CLI and Playwright browsers. |
| `nixos-26-05-hermes` | `#hermes` | Loaded + [Hermes Agent](https://github.com/NousResearch/hermes-agent) CLI and Playwright browsers. |
| `nixos-26-05-nvidia` | `#gpu` | Base + NVIDIA datacenter driver (570.172.08) and GPU containers (`docker --gpus all`). GPU VMs only. |
