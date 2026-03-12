#!/usr/bin/env bash
set -euo pipefail

# Watchdog for long ROCm rollout runs.
# - Monitors kernel fatal patterns while a rollout process is running.
# - Stops the rollout safely on fatal kernel signals.
# - Writes a Markdown report for later review.

PID=""
ROOT=""
POLL_SEC=60

usage() {
  cat <<'EOF'
Usage:
  rocm-night-watchdog.sh --pid <pid> --root <evidence_root> [--poll-sec <seconds>]

Example:
  ./scripts/rocm-night-watchdog.sh \
    --pid 12345 \
    --root /var/tmp/rocm-rollout-20260312-040328
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pid)
      PID="${2:-}"
      shift 2
      ;;
    --root)
      ROOT="${2:-}"
      shift 2
      ;;
    --poll-sec)
      POLL_SEC="${2:-}"
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

if [[ -z "${PID}" || -z "${ROOT}" ]]; then
  usage
  exit 2
fi

if ! [[ "${PID}" =~ ^[0-9]+$ ]]; then
  echo "Invalid --pid value: ${PID}" >&2
  exit 2
fi

if [[ ! -d "${ROOT}" ]]; then
  echo "Evidence root not found: ${ROOT}" >&2
  exit 2
fi

START_ISO="$(date -Iseconds)"
START_EPOCH="$(date +%s)"
SUMMARY="${ROOT}/summary.tsv"
WATCHDOG_LOG="${ROOT}/watchdog.log"
FATAL_LOG="${ROOT}/watchdog-fatal-kernel.log"
REPORT="${ROOT}/night-report.md"

log() {
  printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "${WATCHDOG_LOG}" >/dev/null
}

kernel_fatal_regex='amdgpu.*(ring.*timeout|gpu reset|fault|hang)|amdgpu_job_timedout|kfd.*(timeout|fault|error)|kernel panic|BUG:|soft lockup|hard LOCKUP'

safe_stop_rollout() {
  local target_pid="$1"
  local pgid
  pgid="$(ps -o pgid= -p "${target_pid}" 2>/dev/null | tr -d ' ' || true)"

  if [[ -n "${pgid}" ]]; then
    log "Fatal detected, sending TERM to process group -${pgid}"
    kill -TERM "-${pgid}" 2>/dev/null || true
  else
    log "Fatal detected, sending TERM to pid ${target_pid}"
    kill -TERM "${target_pid}" 2>/dev/null || true
  fi

  for _ in $(seq 1 30); do
    if ! kill -0 "${target_pid}" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done

  if [[ -n "${pgid}" ]]; then
    log "Process still alive, sending KILL to process group -${pgid}"
    kill -KILL "-${pgid}" 2>/dev/null || true
  else
    log "Process still alive, sending KILL to pid ${target_pid}"
    kill -KILL "${target_pid}" 2>/dev/null || true
  fi
}

write_report() {
  local result="$1"
  local note="$2"
  local finished_iso
  local pass_count fail_count skip_count todo_count
  finished_iso="$(date -Iseconds)"
  pass_count=0
  fail_count=0
  skip_count=0
  todo_count=0

  if [[ -f "${SUMMARY}" ]]; then
    pass_count="$(awk -F'\t' 'NR>1 && $2=="PASS"{c++} END{print c+0}' "${SUMMARY}")"
    fail_count="$(awk -F'\t' 'NR>1 && $2=="FAIL"{c++} END{print c+0}' "${SUMMARY}")"
    skip_count="$(awk -F'\t' 'NR>1 && $2=="SKIP"{c++} END{print c+0}' "${SUMMARY}")"
    todo_count="$(awk -F'\t' 'NR>1 && $2=="TODO"{c++} END{print c+0}' "${SUMMARY}")"
  fi

  {
    echo "# ROCm Night Watchdog Report"
    echo
    echo "- Started: ${START_ISO}"
    echo "- Finished: ${finished_iso}"
    echo "- Evidence root: \`${ROOT}\`"
    echo "- Monitored PID: \`${PID}\`"
    echo "- Result: **${result}**"
    echo "- Note: ${note}"
    echo
    echo "## Phase Summary"
    echo
    if [[ -f "${SUMMARY}" ]]; then
      echo "- PASS: ${pass_count}"
      echo "- FAIL: ${fail_count}"
      echo "- SKIP: ${skip_count}"
      echo "- TODO: ${todo_count}"
      echo
      echo "| Phase | Status | Message |"
      echo "|---|---|---|"
      tail -n +2 "${SUMMARY}" | while IFS=$'\t' read -r phase status message; do
        message="${message//|/\\|}"
        echo "| ${phase} | ${status} | ${message} |"
      done
    else
      echo "- summary.tsv chưa tồn tại, có thể rollout bị dừng quá sớm."
    fi
    echo
    if [[ -f "${FATAL_LOG}" ]]; then
      echo "## Fatal Kernel Snippet"
      echo
      echo '```text'
      tail -n 120 "${FATAL_LOG}"
      echo '```'
      echo
    fi
    echo "## Safe Exit / Rollback"
    echo
    echo "1. Rollback runtime NixOS: \`sudo nixos-rebuild switch --rollback\`"
    echo "2. Nếu boot lỗi: chọn generation trước trong boot menu."
    echo "3. Rollback CPDA logic: \`git -C /home/will/dev/CPDA switch <stable-branch>\`"
  } > "${REPORT}"
}

log "Watchdog started for PID=${PID}, ROOT=${ROOT}, poll=${POLL_SEC}s"
fatal_note=""

while kill -0 "${PID}" 2>/dev/null; do
  if command -v journalctl >/dev/null 2>&1; then
    journalctl -k --since "@${START_EPOCH}" --no-pager > "${FATAL_LOG}.tmp" 2>/dev/null || true
  else
    dmesg -T > "${FATAL_LOG}.tmp" 2>/dev/null || true
  fi

  if rg -qi "${kernel_fatal_regex}" "${FATAL_LOG}.tmp"; then
    mv -f "${FATAL_LOG}.tmp" "${FATAL_LOG}"
    fatal_note="Phat hien kernel fatal pattern (amdgpu/kfd), rollout duoc dung an toan."
    log "${fatal_note}"
    safe_stop_rollout "${PID}"
    break
  fi

  rm -f "${FATAL_LOG}.tmp"
  sleep "${POLL_SEC}"
done

if [[ -n "${fatal_note}" ]]; then
  write_report "INTERRUPTED" "${fatal_note}"
  log "Report written: ${REPORT}"
  exit 0
fi

if [[ -f "${SUMMARY}" ]] && awk -F'\t' 'NR>1 && $2=="FAIL"{exit 1} END{exit 0}' "${SUMMARY}"; then
  write_report "PASS_OR_PARTIAL" "Khong thay FAIL trong summary (co the con SKIP/TODO)."
  log "Report written: ${REPORT}"
  exit 0
fi

if [[ -f "${SUMMARY}" ]]; then
  write_report "FAIL" "Co it nhat 1 phase FAIL theo summary."
else
  write_report "UNKNOWN" "Khong tim thay summary.tsv sau khi process ket thuc."
fi

log "Report written: ${REPORT}"
exit 0
