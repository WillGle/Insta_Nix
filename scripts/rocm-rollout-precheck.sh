#!/usr/bin/env bash
set -euo pipefail

# ROCm pre-implementation checklist runner (Phase 0-5).
# This script is intentionally read/verify heavy and avoids changing
# system configuration. Optional CPDA canary branch creation is gated.

RUN_SOAK=0
RUN_FRAMEWORK=0
CREATE_CPDA_BRANCH=0
CPDA_DIR="/home/will/dev/CPDA"
TARGET_USER="${USER}"
ROOT_DIR=""
PHASE4_FLAKE_REF="path:/etc/nixos#rocm-phase4-python"
PHASE4_HSA_OVERRIDE_GFX_VERSION="${PHASE4_HSA_OVERRIDE_GFX_VERSION:-11.0.0}"
PHASE4_TIMEOUT_SEC="${PHASE4_TIMEOUT_SEC:-120}"
PHASE4_MATMUL_SIZE="${PHASE4_MATMUL_SIZE:-1024}"
PHASE4_MATMUL_ITERS="${PHASE4_MATMUL_ITERS:-8}"
PHASE4_RETRY_SLEEP_SEC="${PHASE4_RETRY_SLEEP_SEC:-10}"
PHASE4_STOP_ON_KERNEL_ERROR="${PHASE4_STOP_ON_KERNEL_ERROR:-1}"

usage() {
  cat <<'EOF'
Usage:
  rocm-rollout-precheck.sh [options]

Options:
  --root <dir>             Evidence output directory
  --cpda-dir <dir>         CPDA repo path (default: /home/will/dev/CPDA)
  --user <name>            User for render-group checks (default: current user)
  --run-soak               Run Phase 3 soak (stress + thermal + GPU micro)
  --run-framework          Run Phase 4 Torch ROCm canary in pinned nix shell
  --create-cpda-branch     Create rocm-canary-YYYYMMDD branch in CPDA (Phase 5)
  --help                   Show this help

Examples:
  ./scripts/rocm-rollout-precheck.sh
  ./scripts/rocm-rollout-precheck.sh --run-soak --run-framework
  ./scripts/rocm-rollout-precheck.sh --root /var/tmp/rocm-run-001 --run-framework
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      ROOT_DIR="${2:-}"
      shift 2
      ;;
    --cpda-dir)
      CPDA_DIR="${2:-}"
      shift 2
      ;;
    --user)
      TARGET_USER="${2:-}"
      shift 2
      ;;
    --run-soak)
      RUN_SOAK=1
      shift
      ;;
    --run-framework)
      RUN_FRAMEWORK=1
      shift
      ;;
    --create-cpda-branch)
      CREATE_CPDA_BRANCH=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if ! command -v rg >/dev/null 2>&1; then
  echo "Missing required command: rg" >&2
  exit 2
fi

if [[ -n "${SUDO_USER:-}" ]]; then
  TARGET_USER="${SUDO_USER}"
fi

START_TS_ISO="$(date -Iseconds)"
TS="$(date +%Y%m%d-%H%M%S)"
ROOT_DIR="${ROOT_DIR:-/var/tmp/rocm-rollout-${TS}}"
SUMMARY="${ROOT_DIR}/summary.tsv"

mkdir -p "${ROOT_DIR}"/{0,1,2,3,4,5,6,7}
echo -e "phase\tstatus\tmessage" >"${SUMMARY}"

log() {
  printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"
}

write_summary() {
  local phase="$1"
  local status="$2"
  local message="$3"
  printf '%s\t%s\t%s\n' "${phase}" "${status}" "${message}" >>"${SUMMARY}"
}

rollback_hint() {
  cat <<'EOF'
ROLLBACK GATE:
  - NixOS runtime rollback: sudo nixos-rebuild switch --rollback
  - If boot issue: choose previous generation from boot menu
  - CPDA logical rollback: git -C /home/will/dev/CPDA switch <stable-branch>
EOF
}

phase_fail() {
  local phase="$1"
  local msg="$2"
  echo
  echo "FAIL ${phase}: ${msg}" >&2
  write_summary "${phase}" "FAIL" "${msg}"
  rollback_hint >&2
  echo "Evidence directory: ${ROOT_DIR}" >&2
  exit 1
}

phase_pass() {
  local phase="$1"
  local msg="$2"
  log "PASS ${phase}: ${msg}"
  write_summary "${phase}" "PASS" "${msg}"
}

run_to_file() {
  local outfile="$1"
  shift
  "$@" >"${outfile}" 2>&1
}

find_store_bin() {
  local pattern="$1"
  local bin="$2"
  local resolved
  resolved="$(ls -1d /nix/store/${pattern} 2>/dev/null | rg -v '\.drv$' | sort | tail -n1 || true)"
  if [[ -n "${resolved}" ]] && [[ -x "${resolved}/bin/${bin}" ]]; then
    printf '%s\n' "${resolved}/bin/${bin}"
  fi
}

kernel_error_scan() {
  local outfile="$1"
  if command -v journalctl >/dev/null 2>&1; then
    journalctl -k --since "${START_TS_ISO}" --no-pager >"${outfile}" 2>&1 || true
  else
    dmesg -T >"${outfile}" 2>&1 || true
  fi
  if rg -qi 'amdgpu.*(ring.*timeout|gpu reset|fault|hang)|amdgpu_job_timedout|kfd.*(timeout|fault|error)' "${outfile}"; then
    return 1
  fi
  return 0
}

capture_phase4_metadata() {
  local outfile="$1"
  {
    echo "timestamp=$(date -Iseconds)"
    echo "flake_ref=${PHASE4_FLAKE_REF}"
    echo "phase4_hsa_override_gfx_version=${PHASE4_HSA_OVERRIDE_GFX_VERSION}"
    echo "phase4_timeout_sec=${PHASE4_TIMEOUT_SEC}"
    echo "phase4_matmul_size=${PHASE4_MATMUL_SIZE}"
    echo "phase4_matmul_iters=${PHASE4_MATMUL_ITERS}"
    echo "phase4_stop_on_kernel_error=${PHASE4_STOP_ON_KERNEL_ERROR}"
    if command -v jq >/dev/null 2>&1 && [[ -r /etc/nixos/flake.lock ]]; then
      jq -r '
        .nodes["nixpkgs-rocm"].locked
        | "nixpkgs_rocm_rev=\(.rev // "unknown")\n"
        + "nixpkgs_rocm_lastModified=\(.lastModified // "unknown")\n"
        + "nixpkgs_rocm_narHash=\(.narHash // "unknown")"
      ' /etc/nixos/flake.lock || true
    else
      echo "nixpkgs_rocm_rev=unknown"
      echo "nixpkgs_rocm_lastModified=unknown"
      echo "nixpkgs_rocm_narHash=unknown"
    fi

    echo "-- path-info rocm-phase4-python --"
    nix path-info "${PHASE4_FLAKE_REF}" || true

    echo "-- torch runtime metadata --"
    HSA_OVERRIDE_GFX_VERSION="${PHASE4_HSA_OVERRIDE_GFX_VERSION}" nix shell "${PHASE4_FLAKE_REF}" -c python - <<'PY' || true
import torch
print(f"torch_version={torch.__version__}")
print(f"hip={getattr(torch.version, 'hip', None)}")
print(f"cuda_is_available={torch.cuda.is_available()}")
if torch.cuda.is_available():
    print(f"device={torch.cuda.get_device_name(0)}")
PY
  } >"${outfile}" 2>&1
}

run_phase4_canary_attempt() {
  local attempt="$1"
  local canary_out="$2"
  local kernel_out="$3"
  local cmd_rc=0

  set +e
  run_to_file "${canary_out}" env \
    HSA_OVERRIDE_GFX_VERSION="${PHASE4_HSA_OVERRIDE_GFX_VERSION}" \
    AMD_SERIALIZE_KERNEL=3 \
    HIP_LAUNCH_BLOCKING=1 \
    PHASE4_MATMUL_SIZE="${PHASE4_MATMUL_SIZE}" \
    PHASE4_MATMUL_ITERS="${PHASE4_MATMUL_ITERS}" \
    timeout "${PHASE4_TIMEOUT_SEC}" \
    nix shell "${PHASE4_FLAKE_REF}" -c python - <<'PY'
import json, os, time, torch
size = int(os.getenv("PHASE4_MATMUL_SIZE", "1024"))
iters = int(os.getenv("PHASE4_MATMUL_ITERS", "8"))
if size <= 0 or iters <= 0:
    raise SystemExit("invalid safe canary parameters")
res = {}
res["torch_version"] = torch.__version__
res["cuda_is_available"] = torch.cuda.is_available()
res["hip"] = getattr(torch.version, "hip", None)
res["matmul_size"] = size
res["matmul_iters"] = iters
if not torch.cuda.is_available():
    raise SystemExit("cuda_is_available=False")
if res["hip"] is None:
    raise SystemExit("hip backend is None")
res["device"] = torch.cuda.get_device_name(0)
x = torch.randn((size, size), device="cuda")
y = torch.randn((size, size), device="cuda")
torch.cuda.synchronize()
t0 = time.time()
for _ in range(iters):
    _ = x @ y
torch.cuda.synchronize()
res["avg_iter_ms"] = ((time.time() - t0) / float(iters)) * 1000.0
print(json.dumps(res))
PY
  cmd_rc=$?
  set -e

  if [[ "${cmd_rc}" -ne 0 ]]; then
    if [[ "${cmd_rc}" -eq 124 ]]; then
      echo "phase4_timeout=true timeout_sec=${PHASE4_TIMEOUT_SEC}" >>"${canary_out}"
      kernel_error_scan "${kernel_out}" || true
      return 3
    fi
    kernel_error_scan "${kernel_out}" || true
    return 1
  fi

  if ! kernel_error_scan "${kernel_out}"; then
    return 2
  fi
  return 0
}

log "Evidence root: ${ROOT_DIR}"
log "Start ISO time: ${START_TS_ISO}"

# ---------------------------
# Phase 0 - Baseline freeze
# ---------------------------
log "Phase 0: Baseline freeze"
run_to_file "${ROOT_DIR}/0/uname.log" uname -a
run_to_file "${ROOT_DIR}/0/lscpu.log" lscpu
run_to_file "${ROOT_DIR}/0/free.log" free -h
run_to_file "${ROOT_DIR}/0/lsblk.log" lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS
run_to_file "${ROOT_DIR}/0/swapon.log" swapon --show
run_to_file "${ROOT_DIR}/0/zramctl.log" zramctl

if ! run_to_file "${ROOT_DIR}/0/generations.log" nix-env -p /nix/var/nix/profiles/system --list-generations; then
  if ! run_to_file "${ROOT_DIR}/0/generations.log" bash -lc 'ls -l /nix/var/nix/profiles/system*'; then
    phase_fail "0" "Could not capture rollback generation references"
  fi
fi
run_to_file "${ROOT_DIR}/0/current-system.log" readlink -f /run/current-system

if ! run_to_file "${ROOT_DIR}/0/cpda-runtime.log" direnv exec "${CPDA_DIR}" python - <<'PY'
import torch, tensorflow as tf
print("torch", torch.__version__)
print("torch.cuda.is_available", torch.cuda.is_available())
print("torch.version.hip", getattr(torch.version, "hip", None))
print("tensorflow", tf.__version__)
print("tf.gpus", tf.config.list_physical_devices("GPU"))
PY
then
  phase_fail "0" "Could not capture CPDA runtime baseline"
fi
phase_pass "0" "Baseline evidence captured"

# ---------------------------
# Phase 1 - Guardrails
# ---------------------------
log "Phase 1: Guardrails"
run_to_file "${ROOT_DIR}/1/no-cuda.log" bash -lc 'command -v nvidia-smi || true; command -v nvcc || true; lsmod | rg -i "nvidia|nouveau" || true'

if lsmod | rg -qi 'nvidia|nouveau'; then
  phase_fail "1" "Unexpected NVIDIA/Nouveau modules loaded"
fi

PPD_STATE="$(systemctl is-enabled power-profiles-daemon 2>/dev/null || true)"
TLP_STATE="$(systemctl is-enabled tlp 2>/dev/null || true)"
LACTD_STATE="$(systemctl is-enabled lactd 2>/dev/null || true)"
{
  echo "power-profiles-daemon=${PPD_STATE}"
  echo "tlp=${TLP_STATE}"
  echo "lactd=${LACTD_STATE}"
} >"${ROOT_DIR}/1/power-daemons.log"

if [[ ! "${PPD_STATE}" =~ ^(enabled|linked|enabled-runtime)$ ]]; then
  phase_fail "1" "power-profiles-daemon must be enabled"
fi
if [[ "${TLP_STATE}" == "enabled" || "${LACTD_STATE}" == "enabled" ]]; then
  phase_fail "1" "Conflicting power daemons enabled (tlp/lactd)"
fi

CPU_STATUS="$(cat /sys/devices/system/cpu/amd_pstate/status)"
CPU_DRIVER="$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_driver)"
CPU_GOV="$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor)"
CPU_EPP="$(cat /sys/devices/system/cpu/cpufreq/policy0/energy_performance_preference)"
{
  echo "amd_pstate=${CPU_STATUS}"
  echo "scaling_driver=${CPU_DRIVER}"
  echo "governor=${CPU_GOV}"
  echo "epp=${CPU_EPP}"
} >"${ROOT_DIR}/1/cpu-policy.log"

[[ "${CPU_STATUS}" == "active" ]] || phase_fail "1" "amd_pstate must be active"
[[ "${CPU_DRIVER}" == "amd-pstate-epp" ]] || phase_fail "1" "scaling_driver must be amd-pstate-epp"
[[ "${CPU_GOV}" == "performance" ]] || phase_fail "1" "governor must be performance"
[[ "${CPU_EPP}" == "performance" ]] || phase_fail "1" "EPP must be performance"
phase_pass "1" "Guardrails validated"

# ---------------------------
# Phase 2 - Runtime preflight
# ---------------------------
log "Phase 2: ROCm/Vulkan runtime preflight"
if [[ ! -e /dev/kfd ]]; then
  phase_fail "2" "/dev/kfd missing"
fi
run_to_file "${ROOT_DIR}/2/kfd.log" ls -l /dev/kfd
run_to_file "${ROOT_DIR}/2/user-groups.log" id "${TARGET_USER}"
if ! id "${TARGET_USER}" | rg -q 'render'; then
  phase_fail "2" "User ${TARGET_USER} is not in render group"
fi

ROCINFO_BIN="$(command -v rocminfo || true)"
if [[ -z "${ROCINFO_BIN}" ]]; then
  ROCINFO_BIN="$(find_store_bin '*-rocminfo-*' 'rocminfo' || true)"
fi
if [[ -z "${ROCINFO_BIN}" ]]; then
  phase_fail "2" "rocminfo binary not found"
fi
run_to_file "${ROOT_DIR}/2/rocminfo.log" "${ROCINFO_BIN}"
if ! rg -q 'gfx1103|Radeon 780M|Agent 2' "${ROOT_DIR}/2/rocminfo.log"; then
  phase_fail "2" "rocminfo does not show expected AMD 780M agent"
fi

VULKANINFO_BIN="$(command -v vulkaninfo || true)"
if [[ -z "${VULKANINFO_BIN}" ]]; then
  VULKANINFO_BIN="$(find_store_bin '*-vulkan-tools-*' 'vulkaninfo' || true)"
fi
if [[ -z "${VULKANINFO_BIN}" ]]; then
  phase_fail "2" "vulkaninfo binary not found"
fi
run_to_file "${ROOT_DIR}/2/vulkaninfo-summary.log" "${VULKANINFO_BIN}" --summary
if ! rg -q 'Radeon 780M|RADV PHOENIX' "${ROOT_DIR}/2/vulkaninfo-summary.log"; then
  phase_fail "2" "vulkaninfo summary does not show expected AMD iGPU"
fi

if ! kernel_error_scan "${ROOT_DIR}/2/kernel-errors.log"; then
  phase_fail "2" "Kernel scan detected severe amdgpu/kfd errors"
fi
phase_pass "2" "Runtime ROCm/Vulkan preflight passed"

# ---------------------------
# Phase 3 - Optional soak
# ---------------------------
if [[ "${RUN_SOAK}" -eq 1 ]]; then
  log "Phase 3: Soak test (optional)"
  run_to_file "${ROOT_DIR}/3/sensors-before.log" sensors
  if ! run_to_file "${ROOT_DIR}/3/stress-ng.log" stress-ng --cpu 16 --vm 4 --vm-bytes 70% --timeout 20m --metrics-brief; then
    phase_fail "3" "stress-ng failed"
  fi
  run_to_file "${ROOT_DIR}/3/sensors-after.log" sensors

  if command -v ollama >/dev/null 2>&1; then
    if ! run_to_file "${ROOT_DIR}/3/ollama-gpu-micro.log" timeout 180 ollama run qwen3.5:9b "ROCm rollout micro test. Return exactly: OK"; then
      phase_fail "3" "GPU micro workload via ollama failed"
    fi
  else
    phase_fail "3" "ollama not found for GPU micro workload"
  fi

  if ! kernel_error_scan "${ROOT_DIR}/3/kernel-errors.log"; then
    phase_fail "3" "Kernel scan detected severe amdgpu/kfd errors after soak"
  fi
  phase_pass "3" "Soak test passed"
else
  write_summary "3" "SKIP" "Run with --run-soak to execute"
  log "SKIP 3: Run with --run-soak"
fi

# ---------------------------
# Phase 4 - Optional framework canary
# ---------------------------
if [[ "${RUN_FRAMEWORK}" -eq 1 ]]; then
  log "Phase 4: Torch ROCm canary (optional)"
  capture_phase4_metadata "${ROOT_DIR}/4/phase4-env-meta.log"

  phase4_pass=0
  last_attempt=0
  phase4_fail_reason="Torch ROCm canary failed after 2 attempts (same pin)"
  for attempt in 1 2; do
    last_attempt="${attempt}"
    canary_attempt_log="${ROOT_DIR}/4/torch-rocm-canary.attempt${attempt}.log"
    kernel_attempt_log="${ROOT_DIR}/4/kernel-errors.attempt${attempt}.log"
    log "Phase 4: attempt ${attempt}/2"

    attempt_rc=0
    if run_phase4_canary_attempt "${attempt}" "${canary_attempt_log}" "${kernel_attempt_log}"; then
      phase4_pass=1
      cp "${canary_attempt_log}" "${ROOT_DIR}/4/torch-rocm-canary.log"
      cp "${kernel_attempt_log}" "${ROOT_DIR}/4/kernel-errors.log"
      break
    else
      attempt_rc=$?
    fi

    if [[ "${attempt_rc}" -eq 2 && "${PHASE4_STOP_ON_KERNEL_ERROR}" -eq 1 ]]; then
      phase4_fail_reason="Torch ROCm canary hit severe kernel errors on attempt ${attempt}"
      log "Phase 4: severe kernel error detected, stop retry for safety"
      break
    fi

    if [[ "${attempt}" -eq 1 ]]; then
      log "Phase 4: attempt 1 failed, retrying in ${PHASE4_RETRY_SLEEP_SEC}s with same pin"
      sleep "${PHASE4_RETRY_SLEEP_SEC}"
    fi
  done

  if [[ "${phase4_pass}" -ne 1 ]]; then
    cp "${ROOT_DIR}/4/torch-rocm-canary.attempt${last_attempt}.log" "${ROOT_DIR}/4/torch-rocm-canary.log" || true
    if [[ -f "${ROOT_DIR}/4/kernel-errors.attempt${last_attempt}.log" ]]; then
      cp "${ROOT_DIR}/4/kernel-errors.attempt${last_attempt}.log" "${ROOT_DIR}/4/kernel-errors.log" || true
    fi
    phase_fail "4" "${phase4_fail_reason}"
  fi

  phase_pass "4" "Framework canary passed (pinned env, retry policy applied)"
else
  write_summary "4" "SKIP" "Run with --run-framework to execute"
  log "SKIP 4: Run with --run-framework"
fi

# ---------------------------
# Phase 5 - CPDA readiness gate
# ---------------------------
log "Phase 5: CPDA readiness gate"
if [[ ! -f "${CPDA_DIR}/pyproject.toml" || ! -f "${CPDA_DIR}/poetry.lock" ]]; then
  phase_fail "5" "CPDA dependency files not found"
fi

{
  echo "CPDA_DIR=${CPDA_DIR}"
  echo "---- pyproject blockers ----"
  rg -n 'tensorflow-cpu|torch|tensorflow' "${CPDA_DIR}/pyproject.toml" || true
  echo "---- lock blockers ----"
  rg -n 'name = "tensorflow-cpu"|name = "torch"|nvidia-cuda|nvidia-cudnn|nvidia-cublas' "${CPDA_DIR}/poetry.lock" || true
} >"${ROOT_DIR}/5/cpda-blockers.log"

if ! rg -q 'tensorflow-cpu' "${CPDA_DIR}/pyproject.toml"; then
  phase_fail "5" "Expected tensorflow-cpu marker missing in pyproject (check scope assumption)"
fi
if ! rg -q 'name = "torch"' "${CPDA_DIR}/poetry.lock"; then
  phase_fail "5" "Torch package entry missing in poetry.lock"
fi
if ! rg -q 'nvidia-cuda|nvidia-cudnn|nvidia-cublas' "${CPDA_DIR}/poetry.lock"; then
  phase_fail "5" "Expected CUDA marker not found in lock (check baseline assumptions)"
fi

if [[ "${CREATE_CPDA_BRANCH}" -eq 1 ]]; then
  BRANCH="rocm-canary-$(date +%Y%m%d)"
  if ! run_to_file "${ROOT_DIR}/5/cpda-branch.log" git -C "${CPDA_DIR}" switch -c "${BRANCH}"; then
    phase_fail "5" "Failed to create CPDA canary branch ${BRANCH}"
  fi
fi
phase_pass "5" "CPDA blockers and scope validated"

write_summary "6" "TODO" "Manual implementation phase"
write_summary "7" "TODO" "Manual go/no-go phase"

echo
echo "All requested phases completed."
echo "Evidence directory: ${ROOT_DIR}"
echo "Summary file: ${SUMMARY}"
echo "Next steps:"
echo "  - Review ${ROOT_DIR}/summary.tsv"
echo "  - If all PASS, continue with manual Phase 6-7 rollout"
