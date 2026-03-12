# NixOS Flake Configuration (Hard-Migrated IA)

This repository is organized for:

- Clear ownership boundaries (`personal` vs `generic` vs `shared`)
- Low-friction day-to-day maintenance
- Stable personal daily machine + generic remote install profile

Primary outputs:

- `Think14GRyzen`
- `PlankGeneric`

## Current Architecture

```text
/etc/nixos
├── flake.nix
├── flake.lock
├── README.md
├── docs
│   ├── HOST_ONBOARDING.md
│   ├── PLANK_REMOTE_INSTALL.md
│   └── REMOTE_MIGRATION.md
├── hosts
│   ├── personal
│   │   ├── think14gryzen.nix
│   │   ├── think14gryzen-hardware.nix
│   │   ├── think14gryzen-network.nix
│   │   ├── think14gryzen-storage.nix
│   │   └── think14gryzen-home.nix
│   ├── generic
│   │   └── plank.nix
│   └── _template
├── profiles
│   ├── shared
│   │   ├── base.nix
│   │   ├── users-will.nix
│   │   ├── users-plank.nix
│   │   ├── ssh-strict.nix
│   │   └── ssh-plank.nix
│   └── personal
│       └── think14gryzen-system.nix
├── home
│   ├── base.nix
│   └── desktop-common.nix
└── dotfiles
    ├── common
    └── hosts/ryzen14
```

## Ownership Map

- Personal (Ryzen):
  - `hosts/personal/think14gryzen*.nix`
  - `profiles/personal/think14gryzen-system.nix`
  - `dotfiles/hosts/ryzen14/*`
- Generic (Plank):
  - `hosts/generic/plank.nix`
- Shared:
  - `profiles/shared/*`
  - `home/base.nix`
  - `home/desktop-common.nix`

## Flake Outputs

### `Think14GRyzen` (strict daily profile)

- SSH port: `2222`
- `PermitRootLogin = "no"`
- `PasswordAuthentication = false`
- Resolver: `services.resolved.dnsovertls = "opportunistic"`

### `PlankGeneric` (generic installer profile)

- SSH port: `2222`
- `PermitRootLogin = "no"`
- `PasswordAuthentication = false`
- Label-based storage contract: `NIXOS_BOOT`, `NIXOS_ROOT`, `NIXOS_SWAP`
- Home Manager disabled for lean installer profile

## Command Matrix

### Validate flake structure

```bash
nix flake check --no-build --no-write-lock-file path:/etc/nixos
```

### Build outputs

```bash
nixos-rebuild build --flake path:/etc/nixos#Think14GRyzen
nixos-rebuild build --flake path:/etc/nixos#PlankGeneric
```

### Apply daily profile on Ryzen

```bash
sudo nixos-rebuild switch --flake /etc/nixos#Think14GRyzen
```

### Verify output surface

```bash
nix flake show --no-write-lock-file path:/etc/nixos
nix eval --json path:/etc/nixos#nixosConfigurations.Think14GRyzen.config.services.openssh.ports
nix eval --json path:/etc/nixos#nixosConfigurations.PlankGeneric.config.services.openssh.ports
```

## Remote Install / Migration

- New installs should use `PlankGeneric`.
- Public guide: `docs/PLANK_REMOTE_INSTALL.md`
- Legacy notes: `docs/REMOTE_MIGRATION.md`

## AMD Performance Suite

Run quantitative performance suite (CPU/GPU/CPDA lanes):

```bash
./scripts/amd-perf-suite.sh
```

Common variants:

```bash
# Balanced profile, 3 measured rounds
./scripts/amd-perf-suite.sh --profile balanced --rounds 3

# Include kernel log safety scan (recommended with sudo)
sudo ./scripts/amd-perf-suite.sh --with-kernel-log

# Baseline capture run (no compare, stable location in /var/lib)
BASE="/var/lib/amd-perf-suite/baselines/safe-r5-$(date +%Y%m%d-%H%M%S)"
sudo mkdir -p /var/lib/amd-perf-suite/baselines
sudo env "HOME=$HOME" "USER=$USER" "PATH=$PATH" ./scripts/amd-perf-suite.sh \
  --root "$BASE" \
  --profile safe \
  --rounds 5 \
  --cpda-cli-repeats 5 \
  --cpda-cli-cooldown-sec 2 \
  --cpda-thread-count 16 \
  --secondary-kpi-mode both \
  --with-kernel-log \
  --cpda-dir /home/will/dev/CPDA

# Promote baseline manually when gate is satisfied
sudo ln -sfn "$BASE" /var/lib/amd-perf-suite/baselines/current-safe

# Compare run (canonical baseline source for KPI scoring)
sudo env "HOME=$HOME" "USER=$USER" "PATH=$PATH" ./scripts/amd-perf-suite.sh \
  --profile safe \
  --rounds 5 \
  --cpda-cli-repeats 5 \
  --cpda-cli-cooldown-sec 2 \
  --cpda-thread-count 16 \
  --secondary-kpi-mode both \
  --with-kernel-log \
  --compare /var/lib/amd-perf-suite/baselines/current-safe \
  --cpda-dir /home/will/dev/CPDA
```

Notes:

- `--compare <root>` is the only baseline source for primary/secondary KPI scoring.
- `--baseline-root <root>` is an alias of `--compare`.
- Baseline governance policy is tracked in `manifest/baseline.json` (`baseline_policy`).
- Without `--compare`, baseline-relative KPI entries are `WARN` (`no_baseline_mapping`) instead of hard-failing.
- CPDA primary KPI uses internal timing (`pytest passed in X.XXs` / CPDA CSV `total_time`), with wall-time fallback marked as `WARN`.
- CPDA CLI lane is stabilized by repeat runs (`--cpda-cli-repeats`) and fixed BLAS/OMP threads (`--cpda-thread-count`).
- `--secondary-kpi-mode=both` enforces strict secondary regression gating on both median and p95.

## ROCm Archive + Retry Notes

ROCm rollout scripts were removed from active configuration to prioritize stability after GPU reset/logout incidents during framework canary runs.

For full incident history, safety gates, rollback rules, and fast-track retry runbook, use:

- `docs/ROCM_RETRY_CHECKPOINT_20260313.md`

## Local-Private Remote Install Assets

Store keys/runbooks locally (ignored from public repo) under:

- `/etc/nixos/.local/remote-install/keys/`
- `/etc/nixos/.local/remote-install/seed/etc/plank/authorized_keys`
- `/etc/nixos/.local/remote-install/seed/home/will/.ssh/authorized_keys`
- `/etc/nixos/.local/remote-install/runbooks/plank-install.md`
- `/etc/nixos/.local/remote-install/hardware/`
- `/etc/nixos/.local/remote-install/modules/plank-host-local.nix`

## Adding a New Host

1. Copy template:

```bash
cp -r hosts/_template hosts/<host-id>
```

2. Fill host files:

- `hosts/<host-id>/hardware-configuration.nix`
- `hosts/<host-id>/networking.nix`
- `hosts/<host-id>/home-overlay.nix`

3. Add output in `flake.nix`.
4. Build and validate.

Detailed guide: `docs/HOST_ONBOARDING.md`

## Operational Notes

- If your Git tree has untracked new files, `--flake .#...` may fail because `git+file` flakes only include tracked files.
- Use `path:/etc/nixos#...` during local refactors, or stage files with `git add -A`.
- `.local/`, `local-private/`, and `secrets-local/` are intentionally ignored to keep keys/runbooks out of the public repo.
- Keep `hosts/personal/think14gryzen-hardware.nix` and `hosts/personal/think14gryzen-storage.nix` as source of truth for Ryzen boot/storage.
