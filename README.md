# NixOS Flake Configuration (Multi-host)

This repository is organized for:

- Multi-host management
- Safe remote migration
- Minimal complexity (shared base + host overlays)

It keeps backward-compatible flake output naming for the current laptop:

- `Think14GRyzen`
- `Think14GRyzen-bootstrap`

## Current Architecture

```text
/etc/nixos
├── flake.nix
├── flake.lock
├── README.md
├── ATOMIC_NOTE_USAGE.md
├── YAZI_USAGE.md
├── profiles
│   ├── common/
│   ├── roles/
│   └── hardware/
├── hosts
│   ├── ryzen14
│   │   ├── default.nix
│   │   ├── hardware-configuration.nix
│   │   ├── storage.nix
│   │   ├── networking.nix
│   │   └── home-overlay.nix
│   └── _template
├── home
│   ├── base.nix
│   └── desktop-common.nix
├── dotfiles
│   ├── common
│   │   ├── fastfetch
│   │   ├── waybar
│   │   └── wofi
│   └── hosts/ryzen14
│       ├── hypr
│       ├── kanshi
│       └── local-bin
└── docs
    ├── HOST_ONBOARDING.md
    └── REMOTE_MIGRATION.md
```

## Composition Model

- `profiles/common/*`: shared baseline, no host identity
- `profiles/hardware/*`: hardware-class tuning, reusable by similar machines
- `profiles/roles/*`: functional stacks (desktop, apps, gaming)
- `hosts/<host>/*`: host identity (hostname, disk UUIDs, host networking, host HM overlay)
- `home/base.nix`: shared Home Manager baseline
- `home/desktop-common.nix`: shared desktop HM layer
- `hosts/<host>/home-overlay.nix`: host-specific HM additions

## Flake Outputs

### `Think14GRyzen` (strict daily profile)

- SSH port: `2222`
- `PermitRootLogin = "no"`
- `PasswordAuthentication = false`

### `Think14GRyzen-bootstrap` (temporary remote install profile)

- SSH ports: `22`, `2222`
- `PermitRootLogin = "prohibit-password"` (key-based rescue)
- `PasswordAuthentication = false`

## Command Matrix

### Validate flake structure

```bash
nix flake check --no-build --no-write-lock-file path:/etc/nixos
```

### Build strict profile

```bash
nixos-rebuild build --flake path:/etc/nixos#Think14GRyzen
```

### Build bootstrap profile

```bash
nixos-rebuild build --flake path:/etc/nixos#Think14GRyzen-bootstrap
```

### Apply strict profile

```bash
sudo nixos-rebuild switch --flake /etc/nixos#Think14GRyzen
```

### Verify key runtime values

```bash
nix eval --raw path:/etc/nixos#nixosConfigurations.Think14GRyzen.config.networking.hostName
nix eval --json path:/etc/nixos#nixosConfigurations.Think14GRyzen.config.services.openssh.ports
nix eval --json path:/etc/nixos#nixosConfigurations.\"Think14GRyzen-bootstrap\".config.services.openssh.ports
```

### Local lint/format hygiene

```bash
nix shell nixpkgs#statix nixpkgs#deadnix nixpkgs#nixfmt-rfc-style --command bash -lc \
  'statix check . && deadnix . && nixfmt --check flake.nix $(find profiles hosts home -name "*.nix" | sort)'
```

## Remote Migration Flow

1. Boot target machine into NixOS installer with SSH enabled.
2. Install bootstrap output:

```bash
npx nixos-anywhere --flake .#Think14GRyzen-bootstrap root@<ip>
```

3. Verify normal user access:

```bash
ssh -p 2222 will@<ip>
```

4. Harden to strict profile:

```bash
sudo nixos-rebuild switch --flake /etc/nixos#Think14GRyzen
```

5. Re-verify SSH on `2222`.

See full runbook: `docs/REMOTE_MIGRATION.md`

## Adding a New Host

1. Copy template:

```bash
cp -r hosts/_template hosts/<host-id>
```

2. Fill:
- `hosts/<host-id>/hardware-configuration.nix`
- `hosts/<host-id>/networking.nix`
- `hosts/<host-id>/home-overlay.nix`

3. Register new output(s) in `flake.nix`.
4. Build and validate.

Detailed guide: `docs/HOST_ONBOARDING.md`

## Maintenance

### Update flake inputs

```bash
nix flake update
```

### Garbage collection & Store optimization

```bash
# Delete older generations and optimize the store
sudo nix-collect-garbage -d
nix-store --optimize
```

### Check store for corruption

```bash
nix-store --verify --check-contents
```

## Operational Notes

- If your Git tree has untracked new files, `--flake .#...` may fail because `git+file` flakes only include tracked files.
- Use `path:/etc/nixos#...` during local refactors, or stage files with `git add -A`.
- Host-specific storage for Ryzen14 is defined in `hosts/ryzen14/storage.nix`.
- Wallpaper is now local (`~/.config/hypr/wallpaper.png`) to avoid hard dependency on `/mnt/vault` at session startup.
- Battery reserve mode defaults to `ON` at boot via `systemd.tmpfiles` (`conservation_mode=1`).
- Waybar has a dedicated `battery mode` button between power profile and refresh-rate modules.
- Right-click the `battery mode` button to toggle reserve mode at runtime; `system energy flow` remains read-only monitoring.
