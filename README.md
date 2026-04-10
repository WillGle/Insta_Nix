# NixOS Flake Configuration

## Purpose

This repository contains the NixOS configuration for two outputs:

- `Think14GRyzen`: the main laptop configuration
- `PlankGeneric`: a generic installer configuration for remote setup

The repository is organized so host-specific files, shared modules, and Home Manager configuration are easy to find.

## Hosts

### `Think14GRyzen`

- Main laptop configuration
- Home Manager enabled
- SSH port `2222`
- `PermitRootLogin = "no"`
- `PasswordAuthentication = false`

### `PlankGeneric`

- Generic installer configuration
- Home Manager disabled
- SSH port `2222`
- `PermitRootLogin = "no"`
- `PasswordAuthentication = false`
- Required disk labels: `NIXOS_BOOT`, `NIXOS_ROOT`, `NIXOS_SWAP`

## Layout

```text
/etc/nixos
├── flake.nix
├── README.md
├── docs
│   ├── README.md
│   ├── STYLE.md
│   ├── guides
│   │   ├── AMD_PERF_SUITE.md
│   │   ├── HOST_ONBOARDING.md
│   │   ├── LOCAL_LLM.md
│   │   └── PLANK_REMOTE_INSTALL.md
│   └── archive
│       ├── REMOTE_MIGRATION.md
│       └── rocm
├── hosts
├── profiles
├── home
├── scripts
└── theme
```

Important directories:

- `hosts/`: host entrypoints and host-specific modules
- `profiles/`: shared and host-specific system modules
- `home/`: shared Home Manager modules
- `docs/guides/`: active documentation
- `docs/archive/`: historical material and retired workflows

## Common Commands

Validate the flake:

```bash
nix flake check --no-build --no-write-lock-file path:/etc/nixos
```

Build both outputs:

```bash
nixos-rebuild build --flake path:/etc/nixos#Think14GRyzen
nixos-rebuild build --flake path:/etc/nixos#PlankGeneric
```

Apply the main laptop configuration:

```bash
sudo nixos-rebuild switch --flake /etc/nixos#Think14GRyzen
```

List available outputs:

```bash
nix flake show --no-write-lock-file path:/etc/nixos
```

Useful local note:

- If untracked files break `--flake .#...`, use `path:/etc/nixos#...` or stage the files first.

## Active Docs

- [`docs/README.md`](./docs/README.md): entrypoint for all documentation
- [`docs/guides/HOST_ONBOARDING.md`](./docs/guides/HOST_ONBOARDING.md): add a new host to this repo
- [`docs/guides/PLANK_REMOTE_INSTALL.md`](./docs/guides/PLANK_REMOTE_INSTALL.md): install `PlankGeneric` on a remote machine
- [`docs/guides/AMD_PERF_SUITE.md`](./docs/guides/AMD_PERF_SUITE.md): use the optional AMD performance tooling
- [`docs/guides/LOCAL_LLM.md`](./docs/guides/LOCAL_LLM.md): local LLM notes for `Think14GRyzen`

## Archive Note

Archived material lives under [`docs/archive/`](./docs/archive/). This includes:

- retired remote-install notes
- ROCm investigation logs and reports

These files are kept for history and reference. They are not the default path for the current daily configuration.
