#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 <mount-dir> <ssh-dir> [sources-list-file]" >&2
  exit 1
fi

MOUNT_DIR=$1
SSH_DIR=$2
SOURCES_LIST_FILE=${3:-}

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
require_dir "${SSH_DIR}"
require_file "${SSH_DIR}/authorized_keys"

if [[ -n "${SOURCES_LIST_FILE}" ]]; then
  require_file "${SOURCES_LIST_FILE}"
fi

install -d -m 0755 \
  "${MOUNT_DIR}/etc/apt" \
  "${MOUNT_DIR}/root/.ssh"

install -m 0600 "${SSH_DIR}/authorized_keys" "${MOUNT_DIR}/root/.ssh/authorized_keys"
chown root:root "${MOUNT_DIR}/root/.ssh" "${MOUNT_DIR}/root/.ssh/authorized_keys"

if [[ -n "${SOURCES_LIST_FILE}" ]]; then
  install -m 0644 "${SOURCES_LIST_FILE}" "${MOUNT_DIR}/etc/apt/sources.list"
fi
