#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PKG_NAME="hackberrypi-max17048"
PKG_VER="$(tr -d ' \t\r\n' < "${SCRIPT_DIR}/VERSION")"
DT_NAME="hackberrypicm5"

CONFIG_TXT="/boot/firmware/config.txt"
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

resolve_overlay_dir() {
  if [[ -d /boot/firmware/overlays ]]; then
    OVERLAY_DIR="/boot/firmware/overlays"
  elif [[ -d /boot/firmware/current/overlays ]]; then
    OVERLAY_DIR="/boot/firmware/current/overlays"
    warn "Using fallback overlay dir: ${OVERLAY_DIR}"
  else
    die "Missing overlay directory: neither /boot/firmware/overlays nor /boot/firmware/current/overlays exists"
  fi
}

check_prereqs() {
  [[ -f "${SCRIPT_DIR}/dkms.conf" ]] || die "Missing dkms.conf"
  [[ -f "${SCRIPT_DIR}/Makefile"  ]] || die "Missing Makefile"
  [[ -f "${SCRIPT_DIR}/${DT_NAME}.dts" ]] || die "Missing ${DT_NAME}.dts"
  [[ -f "${SCRIPT_DIR}/VERSION" ]] || die "Missing VERSION"
  [[ -f "${CONFIG_TXT}" ]] || die "Missing ${CONFIG_TXT}"

  resolve_overlay_dir

  for cmd in dkms make dtc rsync install sed grep uname depmod; do
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

  must_exec dkms add     -m "${PKG_NAME}" -v "${PKG_VER}"
  must_exec dkms build   -m "${PKG_NAME}" -v "${PKG_VER}"
  must_exec dkms install -m "${PKG_NAME}" -v "${PKG_VER}"
}

install_overlay() {
  section "Install device-tree overlay"

  local dtbo_tmp
  dtbo_tmp="$(mktemp "/tmp/${DT_NAME}.XXXXXX.dtbo")"

  must_exec dtc -I dts -O dtb \
    -o "${dtbo_tmp}" \
    "${SCRIPT_DIR}/${DT_NAME}.dts"

  must_exec install -m 0644 \
    "${dtbo_tmp}" \
    "${OVERLAY_DIR}/${DT_NAME}.dtbo"

  rm -f "${dtbo_tmp}"

  if grep -qx "dtoverlay=${DT_NAME}" "${CONFIG_TXT}"; then
    log "Overlay already enabled in config.txt"
  else
    echo "dtoverlay=${DT_NAME}" >> "${CONFIG_TXT}"
    log "Overlay enabled in config.txt"
  fi

  log "Overlay installed to ${OVERLAY_DIR}/${DT_NAME}.dtbo"
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

  log "Overlay dir: ${OVERLAY_DIR}"
  log "Overlay present: $(test -f "${OVERLAY_DIR}/${DT_NAME}.dtbo" && echo yes || echo no)"
  log "Overlay enabled: $(grep -qx "dtoverlay=${DT_NAME}" "${CONFIG_TXT}" && echo yes || echo no)"
}

main() {
  need_root
  check_prereqs
  remove_dkms_versions
  remove_old_source_trees
  sync_sources
  dkms_install
  install_overlay
  refresh_module_deps
  print_status

  echo
  log "[✓] Install complete. Reboot required: sudo reboot"
}

main "$@"
