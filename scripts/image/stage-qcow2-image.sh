#!/usr/bin/env bash
set -euo pipefail

SSH_DIR="$(realpath "${SSH_DIR:-stage/ssh}")"
RESOLV_CONF_FILE="$(realpath "${RESOLV_CONF_FILE:-stage/files/resolv.conf}")"
SCRIPTS_DIR="$(realpath "${SCRIPTS_DIR:-stage/scripts/debian}")"
COPY_QCOW2_CONFIG_SCRIPT="$(realpath "${COPY_QCOW2_CONFIG_SCRIPT:-scripts/image/copy-config-to-qcow2.sh}")"
EXPORT_QCOW2_SCRIPT="$(realpath "${EXPORT_QCOW2_SCRIPT:-scripts/image/export-qcow2-to-raw-xz.sh}")"
WORKDIR="${WORKDIR:-$PWD/out}"
RUN_VIRT_SYSPREP="${RUN_VIRT_SYSPREP:-1}"

usage() {
  cat <<'EOF' >&2
Usage: sudo ./scripts/image/stage-qcow2-image.sh <image.qcow2> [output.raw.xz]

Stages config into an existing qcow2 image, then converts it to raw.xz.

Environment variables:
  SSH_DIR                    Default: stage/ssh
  RESOLV_CONF_FILE           Default: stage/files/resolv.conf
  SCRIPTS_DIR                Default: stage/scripts/debian
  INTERFACES_FILE            Default: stage/files/interfaces
  SOURCES_LIST_FILE          Default: stage/files/sources.list
  COPY_QCOW2_CONFIG_SCRIPT   Default: scripts/image/copy-config-to-qcow2.sh
  EXPORT_QCOW2_SCRIPT        Default: scripts/image/export-qcow2-to-raw-xz.sh
  WORKDIR                    Default: ./out
  RUN_VIRT_SYSPREP           Default: 1
EOF
  exit 1
}

require_file() {
  local file=$1
  if [[ ! -f "${file}" ]]; then
    echo "Missing required file: ${file}" >&2
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

resolve_output_paths() {
  local output_arg=${1:-}
  local output_path

  if [[ -z "${output_arg}" ]]; then
    local image_name
    image_name="$(basename "${INPUT_QCOW2}")"
    image_name="${image_name%.qcow2}"
    OUT_RAW="${WORKDIR}/${image_name}.raw"
    OUT_RAW_XZ="${OUT_RAW}.xz"
    return 0
  fi

  if [[ "${output_arg}" = /* ]]; then
    output_path="${output_arg}"
  else
    output_path="${PWD}/${output_arg}"
  fi

  case "${output_path}" in
    *.raw.xz)
      OUT_RAW_XZ="${output_path}"
      OUT_RAW="${output_path%.xz}"
      ;;
    *.raw)
      OUT_RAW="${output_path}"
      OUT_RAW_XZ="${output_path}.xz"
      ;;
    *.xz)
      OUT_RAW_XZ="${output_path}"
      OUT_RAW="${output_path%.xz}"
      ;;
    *)
      OUT_RAW="${output_path}.raw"
      OUT_RAW_XZ="${OUT_RAW}.xz"
      ;;
  esac
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
fi

INPUT_QCOW2="$(realpath "$1")"
resolve_output_paths "${2:-}"

require_file "${INPUT_QCOW2}"
require_file "${COPY_QCOW2_CONFIG_SCRIPT}"
require_file "${EXPORT_QCOW2_SCRIPT}"

for cmd in qemu-img xz; do
  require_cmd "${cmd}"
done

if [[ "${RUN_VIRT_SYSPREP}" == "1" ]]; then
  require_cmd virt-sysprep
fi

mkdir -p "${WORKDIR}" "$(dirname "${OUT_RAW_XZ}")"
SSH_DIR="${SSH_DIR}" \
RESOLV_CONF_FILE="${RESOLV_CONF_FILE}" \
SCRIPTS_DIR="${SCRIPTS_DIR}" \
INTERFACES_FILE="${INTERFACES_FILE:-stage/files/interfaces}" \
SOURCES_LIST_FILE="${SOURCES_LIST_FILE:-stage/files/sources.list}" \
bash "${COPY_QCOW2_CONFIG_SCRIPT}" "${INPUT_QCOW2}"

if [[ "${RUN_VIRT_SYSPREP}" == "1" ]]; then
  virt-sysprep -a "${INPUT_QCOW2}" \
    --operations machine-id,ssh-hostkeys,tmp-files,logfiles,package-manager-cache
fi

WORKDIR="${WORKDIR}" bash "${EXPORT_QCOW2_SCRIPT}" "${INPUT_QCOW2}" "${OUT_RAW_XZ}"
