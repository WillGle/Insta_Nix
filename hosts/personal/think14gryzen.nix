{ ... }:
{
  imports = [
    ./think14gryzen-hardware.nix
    ./think14gryzen-storage.nix
    ./think14gryzen-network.nix
    ../../profiles/shared/base.nix
    ../../profiles/shared/users-will.nix
    ../../profiles/personal/think14gryzen-system.nix
  ];
}
