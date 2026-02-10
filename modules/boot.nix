{ config, lib, pkgs, ... }:

{
  # ───────── Filesystems ─────────
  fileSystems."/mnt/vault" = {
    device = "/dev/disk/by-uuid/86292ded-a2fe-4f4c-bd5a-ab9afdb1e369";
    fsType = "ext4";
    options = [ "defaults" "noatime" ];
  };

  # ───────── Bootloader ─────────
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.kernelParams = [ "amd_pstate=active" ];
  boot.kernelPackages = pkgs.linuxPackages_zen;

  # ───────── Early KMS ─────────
  boot.initrd.kernelModules = [ "amdgpu" ];
}
