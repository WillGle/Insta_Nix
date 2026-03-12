#!/usr/bin/env bash
set -euo pipefail

# Continuous ROCm stability supervisor:
# - Runs rollout precheck in cycles.
# - Uses watchdog for safe-stop on kernel fatal signals.
# - Requires consecutive successful cycles before declaring stable.
# - Writes an aggregate report for post-mortem and review.

PRECHECK="/etc/nixos/scripts/rocm-rollout-precheck.sh"
WATCHDOG="/etc/nixos/scripts/rocm-night-watchdog.sh"

CPDA_DIR="/home/will/dev/CPDA"
TARGET_USER="${USER}"
STABLE_CONSECUTIVE=2
MAX_CYCLES=0
COOLDOWN_SEC=120
POLL_SEC=60
RUN_SOAK=1
RUN_FRAMEWORK=1
FRAMEWORK_EVERY=1
SOAK_EVERY=1
ROOT_BASE=""
ATTACH_PID=""
ATTACH_ROOT=""

usage() {
  cat <<'EOF'
Usage:
  rocm-stability-supervisor.sh [options]

Options:
  --cpda-dir <dir>             CPDA path (default: /home/will/dev/CPDA)
  --user <name>                User for precheck group checks
  --stable-consecutive <n>     Required PASS cycles in a row (default: 2)
  --max-cycles <n>             0 = unlimited (default: 0)
  --cooldown-sec <n>           Pause between cycles (default: 120)
  --poll-sec <n>               Watchdog poll interval (default: 60)
  --no-soak                    Disable phase 3 in new cycles
  --no-framework               Disable phase 4 in new cycles
  --framework-every <n>        Run framework every n cycles (default: 1)
  --soak-every <n>             Run soak every n cycles (default: 1)
  --root-base <dir>            Aggregate output root (default: /var/tmp/rocm-supervisor-<ts>)
  --attach-pid <pid>           Attach to current running precheck pid for cycle 1
  --attach-root <dir>          Evidence root for attached cycle
  --help                       Show this help

Examples:
  ./scripts/rocm-stability-supervisor.sh --stable-consecutive 3
  ./scripts/rocm-stability-supervisor.sh --attach-pid 119270 --attach-root /var/tmp/rocm-rollout-20260312-040328
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cpda-dir)
      CPDA_DIR="${2:-}"
      shift 2
      ;;
    --user)
      TARGET_USER="${2:-}"
      shift 2
      ;;
    --stable-consecutive)
      STABLE_CONSECUTIVE="${2:-}"
      shift 2
      ;;
    --max-cycles)
      MAX_CYCLES="${2:-}"
      shift 2
      ;;
    --cooldown-sec)
      COOLDOWN_SEC="${2:-}"
      shift 2
      ;;
    --poll-sec)
      POLL_SEC="${2:-}"
      shift 2
      ;;
    --no-soak)
      RUN_SOAK=0
      shift
      ;;
    --no-framework)
      RUN_FRAMEWORK=0
      shift
      ;;
    --framework-every)
      FRAMEWORK_EVERY="${2:-}"
      shift 2
      ;;
    --soak-every)
      SOAK_EVERY="${2:-}"
      shift 2
      ;;
    --root-base)
      ROOT_BASE="${2:-}"
      shift 2
      ;;
    --attach-pid)
      ATTACH_PID="${2:-}"
      shift 2
      ;;
    --attach-root)
      ATTACH_ROOT="${2:-}"
      shift 2
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

if [[ -n "${SUDO_USER:-}" ]]; then
  TARGET_USER="${SUDO_USER}"
fi

for n in "${STABLE_CONSECUTIVE}" "${MAX_CYCLES}" "${COOLDOWN_SEC}" "${POLL_SEC}" "${FRAMEWORK_EVERY}" "${SOAK_EVERY}"; do
  if ! [[ "${n}" =~ ^[0-9]+$ ]]; then
    echo "Numeric option invalid: ${n}" >&2
    exit 2
  fi
done

if [[ "${STABLE_CONSECUTIVE}" -eq 0 ]]; then
  echo "--stable-consecutive must be >= 1" >&2
  exit 2
fi
if [[ "${FRAMEWORK_EVERY}" -eq 0 || "${SOAK_EVERY}" -eq 0 ]]; then
  echo "--framework-every and --soak-every must be >= 1" >&2
  exit 2
fi

if [[ -n "${ATTACH_PID}" ]] && ! [[ "${ATTACH_PID}" =~ ^[0-9]+$ ]]; then
  echo "Invalid --attach-pid: ${ATTACH_PID}" >&2
  exit 2
fi

if [[ -n "${ATTACH_PID}" && -z "${ATTACH_ROOT}" ]]; then
  echo "--attach-root is required when --attach-pid is set" >&2
  exit 2
fi

if [[ -n "${ATTACH_ROOT}" && ! -d "${ATTACH_ROOT}" ]]; then
  echo "Attach root not found: ${ATTACH_ROOT}" >&2
  exit 2
fi

if [[ ! -x "${PRECHECK}" ]]; then
  echo "Precheck script not executable: ${PRECHECK}" >&2
  exit 2
fi
if [[ ! -x "${WATCHDOG}" ]]; then
  echo "Watchdog script not executable: ${WATCHDOG}" >&2
  exit 2
fi

TS="$(date +%Y%m%d-%H%M%S)"
ROOT_BASE="${ROOT_BASE:-/var/tmp/rocm-supervisor-${TS}}"
mkdir -p "${ROOT_BASE}"
SUP_LOG="${ROOT_BASE}/supervisor.log"
SUP_TSV="${ROOT_BASE}/cycles.tsv"
SUP_MD="${ROOT_BASE}/final-report.md"

printf "cycle\troot\tstatus\tneeded\tpass_count\tfail_count\tnote\n" > "${SUP_TSV}"

log() {
  printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "${SUP_LOG}" >/dev/null
}

get_phase_status() {
  local summary="$1"
  local phase="$2"
  awk -F'\t' -v p="${phase}" 'NR>1 && $1==p {print $2; found=1} END{if (!found) print "MISSING"}' "${summary}"
}

evaluate_cycle() {
  local root="$1"
  local need_soak="$2"
  local need_fw="$3"
  local summary="${root}/summary.tsv"

  if [[ ! -f "${summary}" ]]; then
    echo "FAIL|summary.tsv missing"
    return 0
  fi

  local s0 s1 s2 s3 s4 s5 fail_count
  s0="$(get_phase_status "${summary}" 0)"
  s1="$(get_phase_status "${summary}" 1)"
  s2="$(get_phase_status "${summary}" 2)"
  s3="$(get_phase_status "${summary}" 3)"
  s4="$(get_phase_status "${summary}" 4)"
  s5="$(get_phase_status "${summary}" 5)"
  fail_count="$(awk -F'\t' 'NR>1 && $2=="FAIL"{c++} END{print c+0}' "${summary}")"

  if [[ "${fail_count}" -gt 0 ]]; then
    echo "FAIL|phase FAIL found in summary"
    return 0
  fi
  if [[ "${s0}" != "PASS" || "${s1}" != "PASS" || "${s2}" != "PASS" || "${s5}" != "PASS" ]]; then
    echo "FAIL|required gate 0/1/2/5 not PASS (0=${s0},1=${s1},2=${s2},5=${s5})"
    return 0
  fi
  if [[ "${need_soak}" -eq 1 && "${s3}" != "PASS" ]]; then
    echo "FAIL|soak requested but phase 3 is ${s3}"
    return 0
  fi
  if [[ "${need_fw}" -eq 1 && "${s4}" != "PASS" ]]; then
    echo "FAIL|framework requested but phase 4 is ${s4}"
    return 0
  fi

  echo "PASS|all required phase gates passed"
}

write_final_report() {
  local result="$1"
  local note="$2"
  local pass_count fail_count last_cycle
  pass_count="$(awk -F'\t' 'NR>1 && $3=="PASS"{c++} END{print c+0}' "${SUP_TSV}")"
  fail_count="$(awk -F'\t' 'NR>1 && $3=="FAIL"{c++} END{print c+0}' "${SUP_TSV}")"
  last_cycle="$(awk -F'\t' 'END{if (NR>1) print $1; else print 0}' "${SUP_TSV}")"

  {
    echo "# ROCm Stability Supervisor Report"
    echo
    echo "- Result: **${result}**"
    echo "- Note: ${note}"
    echo "- Required consecutive PASS: ${STABLE_CONSECUTIVE}"
    echo "- Executed cycles: ${last_cycle}"
    echo "- PASS cycles: ${pass_count}"
    echo "- FAIL cycles: ${fail_count}"
    echo "- Aggregate root: \`${ROOT_BASE}\`"
    echo
    echo "## Cycle Table"
    echo
    echo "| Cycle | Root | Status | Needed | Pass | Fail | Note |"
    echo "|---|---|---|---|---:|---:|---|"
    tail -n +2 "${SUP_TSV}" | while IFS=$'\t' read -r cycle root status needed passc failc note_line; do
      local_note="${note_line//|/\\|}"
      local_root="${root//|/\\|}"
      echo "| ${cycle} | ${local_root} | ${status} | ${needed} | ${passc} | ${failc} | ${local_note} |"
    done
    echo
    echo "## Safe Exit"
    echo
    echo "1. Runtime rollback nếu cần: \`sudo nixos-rebuild switch --rollback\`"
    echo "2. Nếu boot có vấn đề: chọn generation trước trong boot menu."
    echo "3. CPDA logic rollback: \`git -C /home/will/dev/CPDA switch <stable-branch>\`"
  } > "${SUP_MD}"
}

safe_exit_and_stop() {
  local reason="$1"
  log "SAFE EXIT: ${reason}"
  write_final_report "SAFE_EXIT" "${reason}"
  echo "Supervisor safe exit. Report: ${SUP_MD}"
  exit 0
}

pass_streak=0
fail_count_total=0
cycle=0

log "Supervisor started. root=${ROOT_BASE} stable_consecutive=${STABLE_CONSECUTIVE}"

if [[ -n "${ATTACH_PID}" ]]; then
  cycle=1
  attached_pid="${ATTACH_PID}"
  attached_root="${ATTACH_ROOT}"
  need_soak=0
  need_fw=1
  needed_label="attach(framework)"

  log "Cycle ${cycle}: attaching existing PID=${attached_pid}, root=${attached_root}"
  wd_pid=""
  "${WATCHDOG}" --pid "${attached_pid}" --root "${attached_root}" --poll-sec "${POLL_SEC}" &
  wd_pid=$!

  while kill -0 "${attached_pid}" 2>/dev/null; do
    sleep 5
  done
  if kill -0 "${wd_pid}" 2>/dev/null; then
    kill -TERM "${wd_pid}" 2>/dev/null || true
    wait "${wd_pid}" || true
  fi

  eval_result="$(evaluate_cycle "${attached_root}" "${need_soak}" "${need_fw}")"
  cycle_status="${eval_result%%|*}"
  cycle_note="${eval_result#*|}"

  if [[ "${cycle_status}" == "PASS" ]]; then
    pass_streak=$((pass_streak + 1))
  else
    pass_streak=0
    fail_count_total=$((fail_count_total + 1))
  fi

  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "${cycle}" "${attached_root}" "${cycle_status}" "${needed_label}" "${pass_streak}" "${fail_count_total}" "${cycle_note}" >> "${SUP_TSV}"
  log "Cycle ${cycle} result=${cycle_status} note=${cycle_note} pass_streak=${pass_streak}"

  if [[ "${cycle_status}" != "PASS" ]]; then
    safe_exit_and_stop "Attach cycle failed: ${cycle_note}"
  fi
fi

while :; do
  if [[ "${pass_streak}" -ge "${STABLE_CONSECUTIVE}" ]]; then
    log "Reached stable threshold (${pass_streak}/${STABLE_CONSECUTIVE})."
    write_final_report "STABLE" "Reached required consecutive PASS cycles."
    echo "System reached stability threshold. Report: ${SUP_MD}"
    exit 0
  fi

  if [[ "${MAX_CYCLES}" -gt 0 && "${cycle}" -ge "${MAX_CYCLES}" ]]; then
    safe_exit_and_stop "Reached max cycles=${MAX_CYCLES} before stability threshold."
  fi

  cycle=$((cycle + 1))
  need_soak=0
  need_fw=0
  if [[ "${RUN_SOAK}" -eq 1 && $((cycle % SOAK_EVERY)) -eq 0 ]]; then
    need_soak=1
  fi
  if [[ "${RUN_FRAMEWORK}" -eq 1 && $((cycle % FRAMEWORK_EVERY)) -eq 0 ]]; then
    need_fw=1
  fi

  run_cmd=("${PRECHECK}" "--cpda-dir" "${CPDA_DIR}" "--user" "${TARGET_USER}")
  needed_label="core"
  if [[ "${need_soak}" -eq 1 ]]; then
    run_cmd+=("--run-soak")
    needed_label="${needed_label}+soak"
  fi
  if [[ "${need_fw}" -eq 1 ]]; then
    run_cmd+=("--run-framework")
    needed_label="${needed_label}+framework"
  fi

  log "Cycle ${cycle}: start precheck (${needed_label})"
  cycle_log="${ROOT_BASE}/cycle-${cycle}.log"
  "${run_cmd[@]}" > "${cycle_log}" 2>&1 &
  pre_pid=$!

  # Detect evidence root from precheck log line.
  cycle_root=""
  for _ in $(seq 1 60); do
    if [[ -f "${cycle_log}" ]]; then
      cycle_root="$(rg -n '^\\[[0-9]{2}:[0-9]{2}:[0-9]{2}\\] Evidence root: ' "${cycle_log}" | tail -n1 | sed -E 's/.*Evidence root: //' || true)"
      if [[ -n "${cycle_root}" && -d "${cycle_root}" ]]; then
        break
      fi
    fi
    if ! kill -0 "${pre_pid}" 2>/dev/null; then
      break
    fi
    sleep 1
  done

  if [[ -z "${cycle_root}" || ! -d "${cycle_root}" ]]; then
    # Best effort fallback by reading last created rollout directory.
    cycle_root="$(ls -td /var/tmp/rocm-rollout-* 2>/dev/null | head -n1 || true)"
  fi

  if [[ -z "${cycle_root}" || ! -d "${cycle_root}" ]]; then
    kill -TERM "${pre_pid}" 2>/dev/null || true
    wait "${pre_pid}" || true
    safe_exit_and_stop "Cannot determine cycle evidence root for cycle ${cycle}."
  fi

  "${WATCHDOG}" --pid "${pre_pid}" --root "${cycle_root}" --poll-sec "${POLL_SEC}" &
  wd_pid=$!

  wait "${pre_pid}" || true
  if kill -0 "${wd_pid}" 2>/dev/null; then
    kill -TERM "${wd_pid}" 2>/dev/null || true
    wait "${wd_pid}" || true
  fi

  eval_result="$(evaluate_cycle "${cycle_root}" "${need_soak}" "${need_fw}")"
  cycle_status="${eval_result%%|*}"
  cycle_note="${eval_result#*|}"

  if [[ "${cycle_status}" == "PASS" ]]; then
    pass_streak=$((pass_streak + 1))
  else
    pass_streak=0
    fail_count_total=$((fail_count_total + 1))
  fi

  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "${cycle}" "${cycle_root}" "${cycle_status}" "${needed_label}" "${pass_streak}" "${fail_count_total}" "${cycle_note}" >> "${SUP_TSV}"

  log "Cycle ${cycle} result=${cycle_status} note=${cycle_note} pass_streak=${pass_streak} fail_total=${fail_count_total}"

  if [[ "${cycle_status}" != "PASS" ]]; then
    safe_exit_and_stop "Cycle ${cycle} failed: ${cycle_note}"
  fi

  log "Cooldown ${COOLDOWN_SEC}s before next cycle"
  sleep "${COOLDOWN_SEC}"
done
