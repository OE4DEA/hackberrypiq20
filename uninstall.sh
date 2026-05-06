#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PKG_NAME="hackberrypi-max17048"
PKG_VER="$(tr -d ' \t\r\n' < "${SCRIPT_DIR}/VERSION")"
DT_NAME="hackberrypicm5"

BOOT_BASE="/boot/firmware"
CONFIG_TXT="${BOOT_BASE}/config.txt"
CURRENT_OVERLAY_DIR="${BOOT_BASE}/current/overlays"
NEW_OVERLAY_DIR="${BOOT_BASE}/new/overlays"
OLD_OVERLAY_DIR="${BOOT_BASE}/old/overlays"

ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }

log()  { echo "[$(ts)] $*"; }
warn() { echo "[$(ts)] WARNING: $*" >&2; }
err()  { echo "[$(ts)] ERROR: $*" >&2; }
die()  { err "$*"; exit 1; }

need_root() {
  [[ "${EUID}" -eq 0 ]] || die "Please run as root (sudo ./uninstall.sh)"
}

exec_cmd() {
  local cmd=("$@")

  printf '[%s] [*] ' "$(ts)"
  printf '%q ' "${cmd[@]}"
  printf '\n'

  set +e
  "${cmd[@]}"
  local status=$?
  set -e

  if [[ $status -eq 0 ]]; then
    log "[✓] Success"
  else
    err "[✗] Failed (exit code ${status})"
  fi

  return $status
}

section() {
  echo
  log "=== $* ==="
}

cleanup_one_config() {
  local cfg="$1"

  [[ -f "${cfg}" ]] || return 0

  python3 - "${cfg}" "${DT_NAME}" <<'PY'
from pathlib import Path
import sys

config = Path(sys.argv[1])
dt_name = sys.argv[2]

lines = config.read_text().splitlines()

project_entries = {
    "dtoverlay=dwc2,dr_mode=host",
    "dtoverlay=vc4-kms-v3d",
    f"dtoverlay={dt_name}",
}

restored = []
for line in lines:
    stripped = line.strip()
    if stripped == "#dtparam=i2c_arm=on":
        restored.append("dtparam=i2c_arm=on")
    elif stripped == "#dtparam=spi=on":
        restored.append("dtparam=spi=on")
    else:
        restored.append(line)
lines = restored

lines = [line for line in lines if line.strip() not in project_entries]

cm5_idx = None
for i, line in enumerate(lines):
    if line.strip() == "[cm5]":
        cm5_idx = i
        break

if cm5_idx is not None:
    end_idx = len(lines)
    for i in range(cm5_idx + 1, len(lines)):
        s = lines[i].strip()
        if s.startswith("[") and s.endswith("]"):
            end_idx = i
            break

    block = lines[cm5_idx + 1:end_idx]
    if not any(line.strip() for line in block):
        lines = lines[:cm5_idx] + lines[end_idx:]

compacted = []
previous_blank = False
for line in lines:
    blank = (line.strip() == "")
    if blank and previous_blank:
        continue
    compacted.append(line)
    previous_blank = blank

config.write_text("\n".join(compacted).rstrip() + "\n")
PY
}

remove_config_txt_sets() {
  section "Remove project-specific config.txt setup"

  cleanup_one_config "${BOOT_BASE}/config.txt"

  if [[ -f "${BOOT_BASE}/new/config.txt" ]]; then
    cleanup_one_config "${BOOT_BASE}/new/config.txt"
  fi

  log "Project-specific config.txt changes removed"
}

remove_overlay_files() {
  section "Remove overlay files"

  local removed=0
  local p

  for p in \
    "${CURRENT_OVERLAY_DIR}/${DT_NAME}.dtbo" \
    "${NEW_OVERLAY_DIR}/${DT_NAME}.dtbo" \
    "${OLD_OVERLAY_DIR}/${DT_NAME}.dtbo"
  do
    if [[ -e "${p}" ]]; then
      exec_cmd rm -f "${p}" || true
      removed=1
    fi
  done

  if [[ "${removed}" -eq 0 ]]; then
    log "No overlay file found for ${DT_NAME}"
  fi
}

remove_dkms_versions() {
  section "Remove DKMS module (all installed versions)"

  local found=0
  local line
  local version

  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    found=1

    version="$(sed -n 's/^'"${PKG_NAME}"', \([^,]*\),.*$/\1/p' <<< "${line}")"

    if [[ -n "${version}" ]]; then
      log "Removing DKMS entry: ${PKG_NAME}/${version}"
      exec_cmd dkms remove -m "${PKG_NAME}" -v "${version}" --all || true
    else
      warn "Could not parse DKMS version from: ${line}"
    fi
  done < <(dkms status 2>/dev/null | grep -E "^${PKG_NAME}," || true)

  if [[ "${found}" -eq 0 ]]; then
    log "No DKMS entry found for ${PKG_NAME}"
  fi

  if [[ -d "/var/lib/dkms/${PKG_NAME}" ]]; then
    section "Remove stale DKMS tree entries from /var/lib/dkms"

    shopt -s nullglob
    local trees=(/var/lib/dkms/"${PKG_NAME}"/*)
    shopt -u nullglob

    if [[ ${#trees[@]} -gt 0 ]]; then
      local t
      for t in "${trees[@]}"; do
        exec_cmd rm -rf "${t}" || true
      done
    fi

    rmdir "/var/lib/dkms/${PKG_NAME}" 2>/dev/null || true
  fi
}

remove_sources_all_versions() {
  section "Remove DKMS sources (/usr/src)"

  shopt -s nullglob
  local paths=(/usr/src/"${PKG_NAME}"-*)
  shopt -u nullglob

  if [[ ${#paths[@]} -eq 0 ]]; then
    log "No /usr/src/${PKG_NAME}-* trees found"
    return 0
  fi

  local p
  for p in "${paths[@]}"; do
    exec_cmd rm -rf "${p}" || true
  done
}

refresh_module_deps() {
  section "Refresh module dependency map"

  if command -v depmod >/dev/null 2>&1; then
    exec_cmd depmod -a || true
  else
    warn "depmod not found (skipping)"
  fi
}

print_status() {
  section "Status"

  log "DKMS status (matching package name):"
  dkms status 2>/dev/null | grep -F "${PKG_NAME}" | while IFS= read -r line; do
    log "  ${line}"
  done || true

  log "Overlay in current: $(test -f "${CURRENT_OVERLAY_DIR}/${DT_NAME}.dtbo" && echo yes || echo no)"
  log "Overlay in new: $(test -f "${NEW_OVERLAY_DIR}/${DT_NAME}.dtbo" && echo yes || echo no)"
  log "Overlay in old: $(test -f "${OLD_OVERLAY_DIR}/${DT_NAME}.dtbo" && echo yes || echo no)"
  log "Overlay enabled in ${CONFIG_TXT}: $(test -f "${CONFIG_TXT}" && grep -qx "dtoverlay=${DT_NAME}" "${CONFIG_TXT}" && echo yes || echo no)"
}

main() {
  need_root

  remove_config_txt_sets
  remove_overlay_files
  remove_dkms_versions
  remove_sources_all_versions
  refresh_module_deps
  print_status

  echo
  log "[✓] Uninstall complete. Reboot recommended: sudo reboot"
}

main "$@"
