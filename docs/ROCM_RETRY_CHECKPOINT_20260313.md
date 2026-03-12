# ROCm Retry Checkpoint (2026-03-13)

## Intent

This checkpoint captures the exact state after safe-lane stabilization work,
so future retries can be resumed with full context and reproducibility.

## Host and active system

- Host: Think14GRyzen
- Active system path:
  - /nix/store/rg43gz304m5ffsqlnmi3yjpbds6xlpms-nixos-system-Think14GRyzen-25.11.20260306.71caefc
- Kernel baseline policy kept:
  - amd_pstate=active
  - scaling_driver=amd-pstate-epp
  - governor=performance
  - energy_performance_preference=performance

## Scope implemented in this checkpoint

1. Keep ROCm enabled (do not remove ROCm runtime path).
2. Freeze risky framework canary path for now (no --run-framework in safe lane).
3. Add high-safety observability/perf tools only.
4. Keep power guardrails:
   - power-profiles-daemon active
   - tlp not enabled
   - lactd not enabled

## Nix/flake changes

- Added dedicated pinned ROCm input in flake:
  - nixpkgs-rocm rev: 71caefce12ba78d84fe618cf61644dce01cf3a96
- Exported pinned package for phase4 canary:
  - packages.x86_64-linux.rocm-phase4-python

## System package changes (high-safety set)

Added to think14gryzen system packages:

- cpupower-gui
- ryzen-monitor-ng (binary: ryzen_monitor)
- nvtopPackages.amd (binary: nvtop)
- btop-rocm (binary remains btop)
- vulkan-caps-viewer (binary: vulkanCapsViewer)
- rocmPackages.rocm-smi (binary: rocm-smi)

Also ensured runtime diagnostics are present in config path:

- rocmPackages.clr.icd
- linuxPackages.cpupower
- vulkan-tools
- clinfo
- amdgpu_top
- radeontop
- rocmPackages.rocminfo

## Script and tooling introduced

- scripts/rocm-rollout-precheck.sh
- scripts/amd-perf-suite.sh
- scripts/rocm-night-watchdog.sh
- scripts/rocm-stability-supervisor.sh
- docs/ROCM_ROLLOUT_CHECKLIST.md
- README sections for ROCm precheck + amd-perf-suite runbook

## Critical incidents and findings

1. Framework canary can trigger GPU reset/logout under load.
   - Example evidence:
     - /var/tmp/rocm-stable-cycle1-20260312-224453/4/torch-rocm-canary.attempt1.log
     - /var/tmp/rocm-safe-install-20260312-224203/4/precheck-cycle1.log

2. Safe lane (no framework) is stable enough to run repeatedly.
   - Precheck safe runs PASS:
     - /var/tmp/rocm-safe-no-framework-1-20260312-232948
     - /var/tmp/rocm-safe-no-framework-2-20260312-235100

3. Performance policy still reports NO-GO in benchmark scoring,
   even with hard_fail_count=0 in safe benchmark runs.
   - /var/tmp/amd-perf-safe-1-20260313-001254/scorecard.tsv
   - /var/tmp/amd-perf-safe-2-20260313-001804/scorecard.tsv

## Latest consolidated report (safe lane)

- /var/tmp/amd-rocm-safe-stabilization-report-20260313-002404.md

## Replay commands used for this checkpoint

Build/switch:

```bash
sudo nixos-rebuild build --flake /etc/nixos#Think14GRyzen
sudo nixos-rebuild switch --flake /etc/nixos#Think14GRyzen
```

Precheck safe lane (without framework):

```bash
/etc/nixos/scripts/rocm-rollout-precheck.sh --run-soak --root /var/tmp/rocm-safe-no-framework-<n>-<ts>
```

Benchmark safe lane:

```bash
sudo env "HOME=$HOME" "USER=$USER" "PATH=$PATH" /etc/nixos/scripts/amd-perf-suite.sh \
  --root /var/tmp/amd-perf-safe-<n>-<ts> \
  --profile safe \
  --rounds 5 \
  --run-cpu --run-gpu --run-cpda \
  --with-kernel-log \
  --baseline-root /var/tmp/amd-perf-suite/baselines/current-safe \
  --cpda-dir /home/will/dev/CPDA
```

## Retry policy for next serious attempt

1. Keep safe-lane first: no --run-framework.
2. Require 2 safe precheck passes + 2 benchmark passes with hard_fail_count=0.
3. Re-enable Phase 4 with one controlled attempt only.
4. If GPU reset/logout appears once more in Phase 4, freeze Phase 4 long-term.

## Rollback reminders

```bash
sudo nixos-rebuild switch --rollback
```

If boot issue: select previous generation from boot menu.
