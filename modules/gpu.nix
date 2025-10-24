{ pkgs, ... }:
{
  # X.org driver
  services.xserver.videoDrivers = [ "amdgpu" ];

  # Vulkan/VA-API
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
    extraPackages = with pkgs; [
      vulkan-loader vulkan-tools vulkan-validation-layers
      libva libva-utils vaapiVdpau mesa
    ];
    extraPackages32 = with pkgs.pkgsi686Linux; [
      libva libva-utils vaapiVdpau
    ];
  };
}
