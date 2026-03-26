#!/usr/bin/env bash
set -euo pipefail

QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
SEED_DIR="${SEED_DIR:-seed}"
SEED_IMAGE="${SEED_IMAGE:-${SEED_DIR}/seed.img}"
VM_MEMORY="${VM_MEMORY:-2048}"
VM_CPUS="${VM_CPUS:-2}"
SSH_FWD_PORT="${SSH_FWD_PORT:-2222}"
NET_MODEL="${NET_MODEL:-virtio-net-pci}"
EXTRA_QEMU_ARGS="${EXTRA_QEMU_ARGS:-}"

usage() {
  cat <<'EOF' >&2
Usage: ./scripts/image/start-qcow2.sh <image.qcow2>

Environment variables:
  QEMU_BIN        Default: qemu-system-x86_64
  SEED_DIR        Default: seed
  SEED_IMAGE      Default: seed/seed.img
  VM_MEMORY       Default: 2048
  VM_CPUS         Default: 2
  SSH_FWD_PORT    Default: 2222
  NET_MODEL       Default: virtio-net-pci
  EXTRA_QEMU_ARGS Extra QEMU arguments appended at the end
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

build_seed_image() {
  local seed_dir=$1
  local seed_image=$2
  local temp_dir
  local mkisofs_bin
  local -a seed_files

  require_file "${seed_dir}/meta-data"

  temp_dir="$(mktemp -d)"
  trap 'rm -rf "${temp_dir}"' RETURN

  install -m 0644 "${seed_dir}/meta-data" "${temp_dir}/meta-data"

  if [[ -f "${seed_dir}/user-data" ]]; then
    install -m 0644 "${seed_dir}/user-data" "${temp_dir}/user-data"
  else
    : > "${temp_dir}/user-data"
  fi

  seed_files=("meta-data" "user-data")

  if [[ -f "${seed_dir}/network-config" ]]; then
    install -m 0644 "${seed_dir}/network-config" "${temp_dir}/network-config"
    seed_files+=("network-config")
  fi

  mkdir -p "$(dirname "${seed_image}")"
  rm -f "${seed_image}"

  for mkisofs_bin in xorriso genisoimage mkisofs; do
    if command -v "${mkisofs_bin}" >/dev/null 2>&1; then
      case "${mkisofs_bin}" in
        xorriso)
          (
            cd "${temp_dir}"
            xorriso -as mkisofs \
              -output "${seed_image}" \
              -volid cidata \
              -joliet \
              -rock \
              "${seed_files[@]}" >/dev/null
          )
          return 0
          ;;
        *)
          (
            cd "${temp_dir}"
            "${mkisofs_bin}" \
              -output "${seed_image}" \
              -volid cidata \
              -joliet \
              -rock \
              "${seed_files[@]}" >/dev/null
          )
          return 0
          ;;
      esac
    fi
  done

  echo "Missing required command: xorriso, genisoimage, or mkisofs" >&2
  exit 1
}

if [[ $# -ne 1 ]]; then
  usage
fi

IMAGE_QCOW2="$(realpath "$1")"
SEED_DIR="$(realpath "${SEED_DIR}")"
if [[ "${SEED_IMAGE}" != /* ]]; then
  SEED_IMAGE="${PWD}/${SEED_IMAGE}"
fi

require_file "${IMAGE_QCOW2}"
require_cmd "${QEMU_BIN}"

build_seed_image "${SEED_DIR}" "${SEED_IMAGE}"

QEMU_ARGS=(
  -name "cloudimg-test"
  -m "${VM_MEMORY}"
  -smp "${VM_CPUS}"
  -drive "file=${IMAGE_QCOW2},if=virtio,format=qcow2"
  -drive "file=${SEED_IMAGE},if=virtio,format=raw,media=cdrom,readonly=on"
  -netdev "user,id=n1,hostfwd=tcp::${SSH_FWD_PORT}-:22"
  -device "${NET_MODEL},netdev=n1,mac=52:54:00:12:34:56"
  -nographic
  -serial mon:stdio
)

if [[ -r /dev/kvm && -w /dev/kvm ]]; then
  QEMU_ARGS+=(-enable-kvm -cpu host)
else
  QEMU_ARGS+=(-machine accel=tcg)
fi

if [[ -n "${EXTRA_QEMU_ARGS}" ]]; then
  # shellcheck disable=SC2206
  EXTRA_ARGS=( ${EXTRA_QEMU_ARGS} )
  QEMU_ARGS+=("${EXTRA_ARGS[@]}")
fi

echo "Seed image: ${SEED_IMAGE}"
echo "SSH forward: localhost:${SSH_FWD_PORT} -> guest:22"
echo "NIC model: ${NET_MODEL}"

exec "${QEMU_BIN}" "${QEMU_ARGS[@]}"
