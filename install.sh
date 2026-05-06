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
DKMS_SRC_DIR="/usr/src/${PKG_NAME}-${PKG_VER}"

ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }

log()  { echo "[$(ts)] $*"; }
warn() { echo "[$(ts)] WARNING: $*" >&2; }
err()  { echo "[$(ts)] ERROR: $*" >&2; }
die()  { err "$*"; exit 1; }

need_root() {
  [[ "${EUID}" -eq 0 ]] || die "Please run as root (sudo ./install.sh)"
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

must_exec() {
  if ! exec_cmd "$@"; then
    err "Aborting due to previous error"
    exit 1
  fi
}

section() {
  echo
  log "=== $* ==="
}

check_prereqs() {
  [[ -f "${SCRIPT_DIR}/dkms.conf" ]] || die "Missing dkms.conf"
  [[ -f "${SCRIPT_DIR}/Makefile"  ]] || die "Missing Makefile"
  [[ -f "${SCRIPT_DIR}/${DT_NAME}.dts" ]] || die "Missing ${DT_NAME}.dts"
  [[ -f "${SCRIPT_DIR}/VERSION" ]] || die "Missing VERSION"
  [[ -f "${CONFIG_TXT}" ]] || die "Missing ${CONFIG_TXT}"
  [[ -d "${CURRENT_OVERLAY_DIR}" ]] || die "Missing ${CURRENT_OVERLAY_DIR}"

  for cmd in dkms make dtc rsync install sed grep uname depmod python3; do
    command -v "${cmd}" >/dev/null 2>&1 || die "Missing dependency: ${cmd}"
  done

  [[ -d "/lib/modules/$(uname -r)/build" ]] || die \
    "Kernel headers missing for $(uname -r). Install headers for your running kernel."
}

remove_dkms_versions() {
  section "Remove existing DKMS entries for this module"

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
    log "No existing DKMS entries for ${PKG_NAME}"
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

remove_old_source_trees() {
  section "Remove old /usr/src trees"

  shopt -s nullglob
  local trees=(/usr/src/"${PKG_NAME}"-*)
  shopt -u nullglob

  if [[ ${#trees[@]} -eq 0 ]]; then
    log "No old /usr/src trees found"
    return 0
  fi

  local t
  for t in "${trees[@]}"; do
    exec_cmd rm -rf "${t}" || true
  done
}

sync_sources() {
  section "Sync DKMS source tree"

  must_exec mkdir -p "${DKMS_SRC_DIR}"

  must_exec rsync -a --delete \
    --exclude '.git' \
    --exclude '*.dtbo' \
    --exclude 'install.sh' \
    --exclude 'uninstall.sh' \
    "${SCRIPT_DIR}/" "${DKMS_SRC_DIR}/"
}

dkms_install() {
  section "DKMS add / build / install"

  if [[ -d "/var/lib/dkms/${PKG_NAME}/${PKG_VER}" ]]; then
    warn "Removing stale DKMS tree /var/lib/dkms/${PKG_NAME}/${PKG_VER}"
    exec_cmd rm -rf "/var/lib/dkms/${PKG_NAME}/${PKG_VER}" || true
  fi

  must_exec dkms add     -m "${PKG_NAME}" -v "${PKG_VER}"
  must_exec dkms build   -m "${PKG_NAME}" -v "${PKG_VER}"
  must_exec dkms install -m "${PKG_NAME}" -v "${PKG_VER}"
}

install_overlay_sets() {
  section "Install device-tree overlay"

  local dtbo_tmp
  dtbo_tmp="$(mktemp "/tmp/${DT_NAME}.XXXXXX.dtbo")"

  must_exec dtc -I dts -O dtb \
    -o "${dtbo_tmp}" \
    "${SCRIPT_DIR}/${DT_NAME}.dts"

  must_exec install -m 0644 \
    "${dtbo_tmp}" \
    "${CURRENT_OVERLAY_DIR}/${DT_NAME}.dtbo"

  [[ -f "${CURRENT_OVERLAY_DIR}/${DT_NAME}.dtbo" ]] || die \
    "Overlay install failed for ${CURRENT_OVERLAY_DIR}/${DT_NAME}.dtbo"

  if [[ -d "${NEW_OVERLAY_DIR}" ]]; then
    must_exec install -m 0644 \
      "${dtbo_tmp}" \
      "${NEW_OVERLAY_DIR}/${DT_NAME}.dtbo"

    [[ -f "${NEW_OVERLAY_DIR}/${DT_NAME}.dtbo" ]] || die \
      "Overlay install failed for ${NEW_OVERLAY_DIR}/${DT_NAME}.dtbo"
  else
    log "No pending boot asset set found (${NEW_OVERLAY_DIR} absent)"
  fi

  if [[ -f "${OLD_OVERLAY_DIR}/${DT_NAME}.dtbo" ]]; then
    exec_cmd rm -f "${OLD_OVERLAY_DIR}/${DT_NAME}.dtbo" || true
  fi

  rm -f "${dtbo_tmp}"

  log "Overlay installed into active boot assets"
}

adjust_one_config() {
  local cfg="$1"

  [[ -f "${cfg}" ]] || return 0

  python3 - "${cfg}" "${DT_NAME}" <<'PY'
from pathlib import Path
import sys

config = Path(sys.argv[1])
dt_name = sys.argv[2]

lines = config.read_text().splitlines()

required_cm5 = [
    "dtoverlay=dwc2,dr_mode=host",
    "dtoverlay=vc4-kms-v3d",
    f"dtoverlay={dt_name}",
]

project_entries = set(required_cm5)

def comment_exact(lines, active, commented):
    out = []
    for line in lines:
        if line.strip() == active:
            out.append(commented)
        else:
            out.append(line)
    return out

lines = comment_exact(lines, "dtparam=i2c_arm=on", "#dtparam=i2c_arm=on")
lines = comment_exact(lines, "dtparam=spi=on", "#dtparam=spi=on")

cleaned = []
for line in lines:
    if line.strip() in project_entries:
        continue
    cleaned.append(line)
lines = cleaned

cm5_idx = None
for i, line in enumerate(lines):
    if line.strip() == "[cm5]":
        cm5_idx = i
        break

if cm5_idx is None:
    if lines and lines[-1].strip() != "":
        lines.append("")
    lines.append("[cm5]")
    cm5_idx = len(lines) - 1

end_idx = len(lines)
for i in range(cm5_idx + 1, len(lines)):
    s = lines[i].strip()
    if s.startswith("[") and s.endswith("]"):
        end_idx = i
        break

block = lines[cm5_idx + 1:end_idx]
filtered_block = [line for line in block if line.strip()]
existing = {line.strip() for line in filtered_block}

for entry in required_cm5:
    if entry not in existing:
        filtered_block.append(entry)

lines = lines[:cm5_idx + 1] + filtered_block + lines[end_idx:]
config.write_text("\n".join(lines) + "\n")
PY
}

configure_config_sets() {
  section "Adjust config.txt"

  adjust_one_config "${BOOT_BASE}/config.txt"

  if [[ -f "${BOOT_BASE}/new/config.txt" ]]; then
    adjust_one_config "${BOOT_BASE}/new/config.txt"
  fi

  log "config.txt adjusted for HackberryPi Q20 on CM5"
}

refresh_module_deps() {
  section "Refresh module dependency map"
  exec_cmd depmod -a || true
}

print_status() {
  section "Status"

  log "Running kernel: $(uname -r)"
  log "DKMS status:"
  dkms status 2>/dev/null | while IFS= read -r line; do
    log "  ${line}"
  done || true

  log "Overlay present in current: $(test -f "${CURRENT_OVERLAY_DIR}/${DT_NAME}.dtbo" && echo yes || echo no)"
  log "Overlay present in new: $(test -f "${NEW_OVERLAY_DIR}/${DT_NAME}.dtbo" && echo yes || echo no)"
  log "Overlay enabled in ${CONFIG_TXT}: $(grep -qx "dtoverlay=${DT_NAME}" "${CONFIG_TXT}" && echo yes || echo no)"
}

main() {
  need_root
  check_prereqs
  remove_dkms_versions
  remove_old_source_trees
  sync_sources
  dkms_install
  install_overlay_sets
  configure_config_sets
  refresh_module_deps
  print_status

  echo
  log "[✓] Install complete. Reboot required: sudo reboot"
}

main "$@"
