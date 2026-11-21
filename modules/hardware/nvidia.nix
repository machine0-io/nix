# NVIDIA datacenter userland for machine0 GPU droplets. One module covers
# every SKU machine0 sells — H100/H200 (Hopper), RTX 4000/6000 Ada and L40S
# (Ada): the R580 datacenter driver's release notes list the H-Series,
# L-Series AND the RTX Ada workstation cards as supported products
# (docs.nvidia.com/datacenter/tesla/tesla-release-notes-580-159-03).
#
# Driver is pinned to dc_580 (580.159.03) instead of following
# `nvidiaPackages.dc`, so a nixpkgs bump can't silently move every GPU
# image to a new driver branch. The pin has to move with the kernel: the
# previous pin, dc_570 (570.172.08), does not compile against the 6.18
# kernel NixOS 26.05 ships (the DRM fb_create callback gained a parameter
# in 6.17), which broke the gpu build after the 26.05 upgrade. The eval
# checks cannot see that; only a build of the profile does.
#
# Boot ordering:
#
#   systemd-modules-load  (nvidia.ko; softdep pulls nvidia-uvm after udev)
#        |
#        +- nvidia-persistenced -- ExecCondition: driver loaded?
#        |      keeps the GPU initialized on a headless box
#        |      no GPU (image build VM) -> skipped, not failed
#        +- nvidia-fabricmanager -- ExecCondition: NVSwitch present?
#        |      1x VM   -> skipped (exit 1: unit inactive, not failed)
#        |      8x box  -> runs (NVLink fabric requires it)
#        |
#        +- nvidia-container-toolkit-cdi-generator -- ExecCondition: driver loaded?
#               |  no GPU (image build VM) -> skipped, not failed
#               |  writes the CDI spec into /var/run/cdi/
#               v
#           docker  (rootful; features.cdi=true so `--gpus all` resolves
#                    through CDI)
#
# fabricmanager must NOT run unconditionally: it errors on anything that
# isn't an NVSwitch system (i.e. everything but 8x H100/H200 boxes). The
# nixpkgs datacenter module enables the unit with no off switch, so we gate
# it with an ExecCondition that runs after the driver module has settled —
# a bare ConditionPathExistsGlob could race device creation.
#
# This image is gpuOnly on the machine0 platform: on non-GPU hardware the
# explicit module load fails and the boot comes up degraded-but-SSHable.
# That path is out of contract and deliberately not defended against.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  toolkitTools = lib.getOutput "tools" config.hardware.nvidia-container-toolkit.package;

  # Unit gate: succeeds iff nvidia.ko is (or can be) loaded. Same rules as
  # the fabricmanager gate below — full-path modprobe (the unit environment
  # carries no useful PATH), stderr kept so a real driver-load failure on a
  # GPU droplet shows in the journal.
  driverLoaded = pkgs.writeShellScript "nvidia-driver-loaded" ''
    ${pkgs.kmod}/bin/modprobe nvidia || exit 1
  '';
in
{
  # NVIDIA userland/kernel modules are unfree, and the datacenter (Tesla)
  # driver additionally requires explicit license acceptance. Base doesn't
  # set either; setting them here also keeps runtime `nixos-rebuild` evals
  # working.
  nixpkgs.config.allowUnfree = true;
  nixpkgs.config.nvidia.acceptLicense = true;

  hardware.nvidia = {
    datacenter.enable = true;
    package = config.boot.kernelPackages.nvidiaPackages.dc_580;
    nvidiaPersistenced = true;
    # nixpkgs 26.05 dropped the default for `hardware.nvidia.open`, making it
    # mandatory. Pin it to the pre-26.05 default (closed kernel modules) so the
    # driver variant doesn't silently change across every GPU SKU.
    open = false;
  };

  # The datacenter path only installs nvidia.ko (udev modalias autoload).
  # Load it explicitly so the fabricmanager gate below can never run before
  # the module is in.
  boot.kernelModules = [ "nvidia" ];

  # Gate fabricmanager on NVSwitch hardware. /proc/driver/nvidia-nvswitch/
  # devices is populated synchronously at module init iff NVSwitch exists.
  # The unit environment carries no useful PATH, so no external commands
  # besides full-path modprobe (idempotent — covers ordering drift). Keep
  # modprobe stderr: a driver-load failure must be visible in the journal,
  # not indistinguishable from a clean no-NVSwitch skip.
  systemd.services.nvidia-fabricmanager = {
    after = [ "systemd-modules-load.service" ];
    serviceConfig.ExecCondition = pkgs.writeShellScript "nvswitch-present" ''
      ${pkgs.kmod}/bin/modprobe nvidia || exit 1
      set -- /proc/driver/nvidia-nvswitch/devices/*
      [ -e "$1" ]
    '';
  };

  # GPU containers: generates CDI specs at boot and turns on docker's cdi
  # feature (docker >= 25), which is what `--gpus all` resolves through.
  # nixpkgs wires requiredBy=docker.service but no ordering — add After so
  # a boot-time `--gpus` container can never race the spec generation.
  hardware.nvidia-container-toolkit.enable = true;
  systemd.services.docker.after = [ "nvidia-container-toolkit-cdi-generator.service" ];

  # Skip the driver-dependent units when the driver isn't loaded. The image
  # is built by `nixos-rebuild switch` on a build VM with no GPU: there the
  # CDI generator exits 1 ("failed to initialize NVML: Driver Not Loaded")
  # and nvidia-persistenced crash-loops into start-limit-hit. Either one
  # going failed makes switch-to-configuration exit 4, which aborts the
  # image build. An ExecCondition exit of 1 marks the unit skipped instead
  # (inactive, not failed; Restart= does not apply), and docker's Requires=
  # on the generator is still satisfied. On a GPU droplet modprobe is a
  # no-op and both units start at boot as before.
  systemd.services.nvidia-container-toolkit-cdi-generator = {
    after = [ "systemd-modules-load.service" ];
    serviceConfig.ExecCondition = driverLoaded;
  };
  systemd.services.nvidia-persistenced = {
    after = [ "systemd-modules-load.service" ];
    serviceConfig.ExecCondition = driverLoaded;
  };

  # Rootful docker — unlike loaded's rootless daemon — because it is the
  # reliable path for `--gpus all`. The nix user drives it sudo-free via
  # group membership (extraGroups lists merge with core/users.nix's wheel).
  # Boundary note: rootful dockerd programs its own iptables chains, so
  # `docker run -p` published ports bypass the NixOS firewall (base's
  # SSH-only posture) and are world-reachable. Deliberate: GPU boxes serve
  # models; single-tenant VMs, same permissive posture as loaded's 80/443.
  virtualisation.docker.enable = true;
  users.users.nix.extraGroups = [ "docker" ];

  # `docker run --gpus all` needs three more pieces on docker 28 +
  # toolkit 1.18 (each verified on real GPU hardware; CDI alone only
  # covers `--device nvidia.com/gpu=all`):
  #  1. nvidia-container-runtime-hook on dockerd's PATH — moby registers
  #     its "nvidia" GPU device driver only if it finds the hook at
  #     daemon start (moby daemon/devices_nvidia_linux.go init()).
  #  2. the nvidia runtime as docker's default runtime — the hook itself
  #     refuses non-legacy modes ("use the NVIDIA Container Runtime"), so
  #     device injection must happen in the runtime, which also strips
  #     the hook from the container spec. Side effect (standard on every
  #     default-runtime=nvidia host, e.g. DGX): images that bake
  #     ENV NVIDIA_VISIBLE_DEVICES=all (all nvidia/cuda bases) get the GPU
  #     even without `--gpus`. Fine on single-tenant machine0 VMs.
  #  3. mode = "cdi" so the runtime injects from the generated CDI spec
  #     instead of the legacy nvidia-container-cli stack (deprecated on
  #     NixOS and not on the daemon PATH).
  systemd.services.docker.path = [ toolkitTools ];
  virtualisation.docker.daemon.settings = {
    default-runtime = "nvidia";
    runtimes.nvidia.path = "${toolkitTools}/bin/nvidia-container-runtime";
  };
  environment.etc."nvidia-container-runtime/config.toml".text = ''
    [nvidia-container-runtime]
    mode = "cdi"
  '';
}
