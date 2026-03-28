#!/usr/bin/env bash
set -euo pipefail

SSH_DIR="$(realpath "${SSH_DIR:-stage/ssh}")"
RESOLV_CONF_FILE="$(realpath "${RESOLV_CONF_FILE:-stage/files/resolv.conf}")"
SCRIPTS_DIR="$(realpath "${SCRIPTS_DIR:-stage/scripts/debian}")"
STAGE_IMAGE_CONFIG_SCRIPT="$(realpath "${STAGE_IMAGE_CONFIG_SCRIPT:-scripts/stage-image-config.sh}")"
MOUNT_DIR=""
NBD_DEV=""

INTERFACES_FILE="${INTERFACES_FILE:-stage/files/interfaces}"
if [[ -f "${INTERFACES_FILE}" ]]; then
  INTERFACES_FILE="$(realpath "${INTERFACES_FILE}")"
elif [[ "${INTERFACES_FILE}" == "stage/files/interfaces" ]]; then
  INTERFACES_FILE=""
else
  echo "Missing optional interfaces file: ${INTERFACES_FILE}" >&2
  exit 1
fi

SOURCES_LIST_FILE="${SOURCES_LIST_FILE:-stage/files/sources.list}"
if [[ -f "${SOURCES_LIST_FILE}" ]]; then
  SOURCES_LIST_FILE="$(realpath "${SOURCES_LIST_FILE}")"
elif [[ "${SOURCES_LIST_FILE}" == "stage/files/sources.list" ]]; then
  SOURCES_LIST_FILE=""
else
  echo "Missing optional sources.list file: ${SOURCES_LIST_FILE}" >&2
  exit 1
fi

usage() {
  echo "Usage: sudo $0 <image.qcow2>" >&2
  exit 1
}

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    echo "Run this script with sudo." >&2
    exit 1
  fi
}

require_file() {
  local file=$1
  if [[ ! -f "${file}" ]]; then
    echo "Missing required file: ${file}" >&2
    exit 1
  fi
}

require_dir() {
  local dir=$1
  if [[ ! -d "${dir}" ]]; then
    echo "Missing required directory: ${dir}" >&2
    exit 1
  fi
}

require_cmd() {
  local cmd=$1
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "Missing required command: ${cmd}" >&2
    exit 1
  fi
}

cleanup() {
  set +e

  if [[ -n "${MOUNT_DIR}" ]] && mountpoint -q "${MOUNT_DIR}"; then
    umount "${MOUNT_DIR}"
  fi

  if [[ -n "${NBD_DEV}" ]]; then
    qemu-nbd --disconnect "${NBD_DEV}" >/dev/null 2>&1 || true
  fi

  rm -rf "${MOUNT_DIR}"
}

attach_nbd() {
  local image=$1
  local dev

  modprobe nbd max_part=8

  for dev in /dev/nbd*; do
    [[ -b "${dev}" ]] || continue
    if qemu-nbd --connect="${dev}" "${image}" 2>/dev/null; then
      NBD_DEV="${dev}"
      return 0
    fi
  done

  echo "Unable to find a free /dev/nbd device." >&2
  exit 1
}

find_root_part() {
  local part
  local label

  for part in "${NBD_DEV}"p*; do
    [[ -b "${part}" ]] || continue
    label="$(blkid -s LABEL -o value "${part}" 2>/dev/null || true)"
    if [[ "${label}" == "rootfs" ]]; then
      printf '%s\n' "${part}"
      return 0
    fi
  done

  if [[ -b "${NBD_DEV}p2" ]]; then
    printf '%s\n' "${NBD_DEV}p2"
    return 0
  fi

  echo "Unable to identify the root partition for ${NBD_DEV}." >&2
  exit 1
}

mount_root_part() {
  local root_part=$1
  local root_fs_type

  root_fs_type="$(blkid -s TYPE -o value "${root_part}")"
  MOUNT_DIR="$(mktemp -d)"

  case "${root_fs_type}" in
    btrfs)
      mount -o subvol=@ "${root_part}" "${MOUNT_DIR}"
      ;;
    *)
      mount "${root_part}" "${MOUNT_DIR}"
      ;;
  esac
}

trap cleanup EXIT

if [[ $# -ne 1 ]]; then
  usage
fi

require_root
INPUT_QCOW2="$(realpath "$1")"

require_file "${INPUT_QCOW2}"
require_file "${RESOLV_CONF_FILE}"
require_file "${STAGE_IMAGE_CONFIG_SCRIPT}"
require_dir "${SSH_DIR}"
require_file "${SSH_DIR}/authorized_keys"
require_dir "${SCRIPTS_DIR}"

for cmd in \
  blkid \
  chattr \
  modprobe \
  mount \
  mountpoint \
  partprobe \
  qemu-nbd \
  udevadm \
  umount; do
  require_cmd "${cmd}"
done

attach_nbd "${INPUT_QCOW2}"
udevadm settle
partprobe "${NBD_DEV}"
udevadm settle

ROOT_PART="$(find_root_part)"
mount_root_part "${ROOT_PART}"

if [[ -e "${MOUNT_DIR}/etc/resolv.conf" ]]; then
  chattr -i "${MOUNT_DIR}/etc/resolv.conf" 2>/dev/null || true
fi

bash "${STAGE_IMAGE_CONFIG_SCRIPT}" \
  "${MOUNT_DIR}" \
  "${RESOLV_CONF_FILE}" \
  "${SSH_DIR}" \
  "${SCRIPTS_DIR}" \
  "${INTERFACES_FILE}" \
  "${SOURCES_LIST_FILE}"

if [[ -e "${MOUNT_DIR}/etc/resolv.conf" ]]; then
  chattr +i "${MOUNT_DIR}/etc/resolv.conf" 2>/dev/null || true
fi

echo "Updated qcow2 image:"
ls -lh "${INPUT_QCOW2}"
