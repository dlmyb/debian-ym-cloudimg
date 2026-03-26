#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 4 || $# -gt 6 ]]; then
  echo "Usage: $0 <mount-dir> <resolv-conf-file> <ssh-dir> <scripts-dir> [interfaces-file] [sources-list-file]" >&2
  exit 1
fi

MOUNT_DIR=$1
RESOLV_CONF_FILE=$2
SSH_DIR=$3
SCRIPTS_DIR=$4
INTERFACES_FILE=${5:-}
SOURCES_LIST_FILE=${6:-}

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

require_dir "${MOUNT_DIR}"
require_file "${RESOLV_CONF_FILE}"
require_dir "${SSH_DIR}"
require_file "${SSH_DIR}/authorized_keys"
require_dir "${SCRIPTS_DIR}"

if [[ -n "${INTERFACES_FILE}" ]]; then
  require_file "${INTERFACES_FILE}"
fi

if [[ -n "${SOURCES_LIST_FILE}" ]]; then
  require_file "${SOURCES_LIST_FILE}"
fi

install -d -m 0755 \
  "${MOUNT_DIR}/etc/apt" \
  "${MOUNT_DIR}/etc/network" \
  "${MOUNT_DIR}/root"

install -m 0644 "${RESOLV_CONF_FILE}" "${MOUNT_DIR}/etc/resolv.conf"

rm -rf "${MOUNT_DIR}/root/ssh" "${MOUNT_DIR}/root/scripts"
cp -a "${SSH_DIR}" "${MOUNT_DIR}/root/ssh"
mkdir -p "${MOUNT_DIR}/root/scripts"
cp -a "${SCRIPTS_DIR}/." "${MOUNT_DIR}/root/scripts/"
chown -R root:root "${MOUNT_DIR}/root/ssh" "${MOUNT_DIR}/root/scripts"

if [[ -n "${INTERFACES_FILE}" ]]; then
  install -m 0644 "${INTERFACES_FILE}" "${MOUNT_DIR}/etc/network/interfaces"
fi

if [[ -n "${SOURCES_LIST_FILE}" ]]; then
  install -m 0644 "${SOURCES_LIST_FILE}" "${MOUNT_DIR}/etc/apt/sources.list"
fi
