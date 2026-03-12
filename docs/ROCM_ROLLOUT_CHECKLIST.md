# ROCm Rollout Checklist (No-CUDA, Pre-Implementation)

This document implements the phased checklist as an executable workflow.

## Scope

- Keep `power-profiles-daemon` as the only active power daemon.
- Keep baseline CPU policy:
  - `amd_pstate=active`
  - `scaling_driver=amd-pstate-epp`
  - `governor=performance`
  - `energy_performance_preference=performance`
- Do not use CUDA path on this AMD iGPU machine.
- Gate every phase with PASS/FAIL and rollback hints.

## Automation coverage

Automated by script:

- Phase 0: Baseline freeze
- Phase 1: Guardrails
- Phase 2: ROCm/Vulkan runtime preflight
- Phase 3: Soak (optional)
- Phase 4: Torch ROCm framework canary (optional, pinned env + retry x2)
- Phase 5: CPDA readiness gate

Manual (after precheck PASS):

- Phase 6: CPDA canary integration
- Phase 7: Go/No-Go wide rollout

## Script

Path:

- `scripts/rocm-rollout-precheck.sh`

Help:

```bash
./scripts/rocm-rollout-precheck.sh --help
```

Fast run (Phase 0,1,2,5):

```bash
./scripts/rocm-rollout-precheck.sh
```

Full precheck run (includes soak and framework canary):

```bash
./scripts/rocm-rollout-precheck.sh --run-soak --run-framework
```

Phase 4 now runs in a pinned flake environment:

- `path:/etc/nixos#rocm-phase4-python`
- no implicit `nixpkgs#python311Packages.torchWithRocm` shell path
- 2 attempts with the same pin before hard fail
- sets `HSA_OVERRIDE_GFX_VERSION=11.0.0` for reproducible Torch ROCm canary on `gfx1103`

Full run + create CPDA canary branch:

```bash
./scripts/rocm-rollout-precheck.sh --run-soak --run-framework --create-cpda-branch
```

Custom evidence root:

```bash
./scripts/rocm-rollout-precheck.sh --root /var/tmp/rocm-rollout-manual-001 --run-framework
```

## Evidence and outputs

Each run creates:

- `/var/tmp/rocm-rollout-<timestamp>/`
- `summary.tsv` with phase status
- per-phase logs under `0/` to `7/`

Phase 4 specific logs:

- `4/phase4-env-meta.log`: pin metadata (`nixpkgs-rocm` rev/hash, path info, torch/hip runtime info)
- `4/torch-rocm-canary.attempt1.log`
- `4/torch-rocm-canary.attempt2.log`
- `4/torch-rocm-canary.log`: final selected attempt log (pass/final fail)

Status meanings:

- `PASS`: gate met
- `FAIL`: gate failed, stop rollout immediately
- `SKIP`: optional phase not requested
- `TODO`: manual phase not executed by script

## Rollback gates

System rollback:

```bash
sudo nixos-rebuild switch --rollback
```

If boot issue:

- choose previous generation in boot menu

CPDA logic rollback:

```bash
cd /home/will/dev/CPDA
git switch <stable-branch>
```

## Manual Phase 6 checklist (CPDA canary integration)

1. Keep changes on a canary branch only.
2. Scope is Torch ROCm first, TensorFlow remains CPU.
3. Apply dependency changes in CPDA.
4. Resolve lock and environment.
5. Run CPDA smoke tests:
   - import test
   - one short pipeline
   - one short training/inference workload
6. Compare against Phase 0 baseline logs.
7. If any crash/regression, stop and switch back to stable branch.

## Manual Phase 7 checklist (Go/No-Go)

Go only if all are true:

1. Runtime gates (Phase 1-4) are PASS.
2. No severe kernel errors (`gpu reset`, `ring timeout`, hard lock).
3. CPDA canary is stable and reproducible.
4. Rollback drill is confirmed working.

No-Go if any are true:

1. severe amdgpu/kfd kernel errors
2. non-reproducible behavior
3. CPDA functional regression
4. rollback path is unclear
