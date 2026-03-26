#!/usr/bin/env bash
set -euo pipefail

WORKDIR="${WORKDIR:-$PWD/out}"
WRITE_SHA256="${WRITE_SHA256:-0}"

usage() {
  cat <<'EOF' >&2
Usage: ./scripts/image/export-qcow2-to-raw-xz.sh <image.qcow2> [output.raw.xz]

Environment variables:
  WORKDIR       Default: ./out
  WRITE_SHA256  Default: 0
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

for cmd in qemu-img xz; do
  require_cmd "${cmd}"
done

if [[ "${WRITE_SHA256}" == "1" ]]; then
  require_cmd sha256sum
fi

mkdir -p "${WORKDIR}" "$(dirname "${OUT_RAW_XZ}")"
rm -f "${OUT_RAW}" "${OUT_RAW_XZ}" "${OUT_RAW_XZ}.sha256"

qemu-img convert -f qcow2 -O raw "${INPUT_QCOW2}" "${OUT_RAW}"
xz -T0 -9 -z "${OUT_RAW}"

if [[ "${WRITE_SHA256}" == "1" ]]; then
  sha256sum "${OUT_RAW_XZ}" > "${OUT_RAW_XZ}.sha256"
fi

echo "Built artifacts:"
if [[ "${WRITE_SHA256}" == "1" ]]; then
  ls -lh "${OUT_RAW_XZ}" "${OUT_RAW_XZ}.sha256"
else
  ls -lh "${OUT_RAW_XZ}"
fi
