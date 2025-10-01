{ lib, config, pkgs, ... }:

{
  imports = [ ./hardware-configuration.nix ];

  fileSystems."/mnt/vault" = {
    device = "/dev/disk/by-uuid/86292ded-a2fe-4f4c-bd5a-ab9afdb1e369";
    fsType = "ext4";
    options = [ "defaults" "noatime" ];
  };

  # ───────── Environment vars ─────────
  environment.variables = {
    GTK_IM_MODULE = lib.mkForce null;
    QT_IM_MODULE  = lib.mkForce null;
  };


  environment.sessionVariables = {
    # UI
    XCURSOR_THEME = "Bibata-Modern-Ice";
    XCURSOR_SIZE  = "24";
    QT_FONT_DPI   = "144";
    QT_SCALE_FACTOR = "1";
    QT_AUTO_SCREEN_SCALE_FACTOR = "0";

    # Input
    INPUT_METHOD = "fcitx";
    XMODIFIERS   = "@im=fcitx"; # giúp app X11 qua XWayland gõ được

    # ép UNSET hai biến gây cảnh báo Wayland:
    GTK_IM_MODULE = null;
    QT_IM_MODULE  = null;
  }; 

  # ───────── Bootloader ─────────
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.kernelParams = [ "amd_pstate=active" ];

  # ───────── CPU / FW ─────────
  hardware.cpu.amd.updateMicrocode = true;

  # ───────── Power ─────────
  powerManagement.enable = true;
  services.tlp = {
    enable = true;
    settings = {
      CPU_SCALING_GOVERNOR_ON_AC = "performance";
      CPU_BOOST_ON_AC = 1;
      CPU_MAX_PERF_ON_AC = "100";
      CPU_MIN_PERF_ON_AC = "20";

      CPU_SCALING_GOVERNOR_ON_BAT = "powersave";
      CPU_BOOST_ON_BAT = 0;
      CPU_MAX_PERF_ON_BAT = "35";
      CPU_MIN_PERF_ON_BAT = "5";

      PLATFORM_PROFILE_ON_AC  = "performance";
      PLATFORM_PROFILE_ON_BAT = "low-power";

       STOP_CHARGE_THRESH_BAT0 = "1"; # ~80%
     # STOP_CHARGE_THRESH_BAT0 = "0";   # full
    };
  };

  # ───────── Networking ─────────
  networking = {
    hostName = "Think14GRyzen";
    networkmanager = { enable = true; dns = "systemd-resolved"; };
    firewall = {
      enable = true;
      checkReversePath = "loose";
      trustedInterfaces = [ "proton0" "ipv6leakintrf0" ];
    };
    resolvconf.enable = false;
  };

  services.resolved = {
    enable      = true;
    dnssec      = "false";
    fallbackDns = [ "1.1.1.1" "8.8.8.8" ];
    domains     = [ "~." ];
  };

  environment.etc."resolv.conf".source = "/run/systemd/resolve/stub-resolv.conf";

  # ───────── Locale / Time ─────────
  time.timeZone = "Asia/Ho_Chi_Minh";
  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "vi_VN"; LC_IDENTIFICATION = "vi_VN"; LC_MEASUREMENT = "vi_VN";
    LC_MONETARY = "vi_VN"; LC_NAME = "vi_VN"; LC_NUMERIC = "vi_VN";
    LC_PAPER = "vi_VN"; LC_TELEPHONE = "vi_VN"; LC_TIME = "vi_VN";
  };

  # ───────── Fonts ─────────
  fonts.enableDefaultPackages = true;
  fonts.fontconfig.enable = true;
  fonts.packages = with pkgs; [
    nerd-fonts.meslo-lg
    nerd-fonts.fira-code
    nerd-fonts.jetbrains-mono
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-emoji
    roboto
    unifont
    freefont_ttf
    ipaexfont
    corefonts
  ];

  # ───────── Virtualization ─────────
  virtualisation.docker.enable = true;

  # ───────── GPU / Display ─────────
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

  # ───────── Display Manager / WM ─────────
  programs.hyprland.enable = true;

  # Make Hyprland visible to SDDM as a Wayland session
  services.displayManager.sessionPackages = [ pkgs.hyprland ];

  services.displayManager.sddm = {
    enable = true;
    wayland.enable = true;
    theme = "sugar-dark";
  };

  # Tell the display manager which session to start by default
  services.displayManager.defaultSession = "hyprland";

  # ───────── Core Services ─────────
  services.dbus.enable = true;
  services.openssh.enable = true;
  services.flatpak.enable = true;
  services.upower.enable = true;
  services.udev.enable = true;
  services.acpid.enable = true;
  security.polkit.enable = true;
  services.udisks2.enable = true;
  services.gvfs.enable = true;

  # sudo rule for tlp
  security.sudo.extraRules = [{
    users = [ "will" ];
    commands = [{ command = "/run/current-system/sw/bin/tlp"; options = [ "NOPASSWD" ]; }];
  }];

  # ───────── Packages ─────────
  environment.systemPackages = with pkgs; [
    # Wayland & desktop
    alacritty
    brightnessctl
    mission-center
    waybar

    # WM helpers
    dunst
    hyprland
    hyprpaper
    hyprshot
    rofi-wayland
    sway
    swayidle
    swaylock
    wofi

    # Utilities
    acpid
    cliphist
    eza
    fastfetch
    htop
    # kanshi
    jq
    lm_sensors
    nautilus
    pciutils
    playerctl
    usbutils
    wget
    wl-clipboard
    wob
    xdg-utils
    grim
    slurp
    udiskie
    dosfstools
    exfatprogs
    ntfs3g
    ffmpeg
    v4l-utils
    libheif
    libavif
    wlr-randr

    # Audio & network
    alsa-utils
    bind
    blueman
    networkmanagerapplet
    pavucontrol
    pipewire
    protonvpn-gui
    upower
    pulseaudio

    # SDDM themes
    catppuccin-sddm
    sddm-astronaut
    sddm-chili-theme
    sddm-sugar-dark

    # Apps
    adwaita-icon-theme
    brave
    deadbeef
    docker
    firefox
    gsimplecal
    obs-studio
    obsidian
    signal-desktop
    vscode
    steam
    wpsoffice
    vlc
    gnome-disk-utility
    xournalpp
    libreoffice-fresh
    guvcview
    gthumb
    nomacs

    # Gaming tools
    mesa-demos
    vulkan-tools
    libva-utils
    steam-run
    mangohud

    # Input (VN)
   # fcitx5-configtool
   # fcitx5-unikey

    # Shell & prompt
    fish
    git
    gnome-console
    starship
    bash
    gawk

    # Cursors
    bibata-cursors
  ];

  # ───────── User services ─────────


# ───────── Nix (flakes) ─────────
nix.settings = {
  experimental-features = [ "nix-command" "flakes" ];
  auto-optimise-store = true;
};
nix.gc = {
  automatic = true;
  dates = "weekly";
  options = "--delete-older-than 14d";
};

  # ───────── Nix settings ─────────
  nixpkgs.config.allowUnfree = true;

  system.stateVersion = "25.05";
}
