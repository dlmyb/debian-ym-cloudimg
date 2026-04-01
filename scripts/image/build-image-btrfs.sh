#!/usr/bin/env bash
set -euo pipefail

DEBIAN_VER=13
DEBIAN_SUITE=trixie
ARCH=amd64
DISK_SIZE="${DISK_SIZE:-5G}"
OUT_QCOW2="debian-${DEBIAN_VER}-btrfs-${ARCH}.qcow2"

SSH_DIR="$(realpath "${SSH_DIR:-stage/ssh}")"
BASE_IMAGE_CONFIG_SCRIPT="$(realpath "${BASE_IMAGE_CONFIG_SCRIPT:-scripts/install-base-image-config.sh}")"
WORKDIR="${WORKDIR:-$PWD/out}"
IMAGE_LOCALE="${IMAGE_LOCALE:-en_US.UTF-8}"
MOUNT_DIR=""
NBD_DEV=""

SOURCES_LIST_FILE="${SOURCES_LIST_FILE:-stage/files/sources.list}"
if [[ -f "${SOURCES_LIST_FILE}" ]]; then
  SOURCES_LIST_FILE="$(realpath "${SOURCES_LIST_FILE}")"
elif [[ "${SOURCES_LIST_FILE}" == "stage/files/sources.list" ]]; then
  SOURCES_LIST_FILE=""
else
  echo "Missing optional sources.list file: ${SOURCES_LIST_FILE}" >&2
  exit 1
fi

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    echo "Run this script with sudo." >&2
    exit 1
  fi
}

require_file() {
  local file=$1
  if [[ ! -f "$file" ]]; then
    echo "Missing required file: $file" >&2
    exit 1
  fi
}

require_cmd() {
  local cmd=$1
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 1
  fi
}

cleanup() {
  set +e

  if [[ -n "${MOUNT_DIR}" ]]; then
    for path in dev/pts dev proc sys run boot var/log .snapshots; do
      if mountpoint -q "${MOUNT_DIR}/${path}"; then
        umount "${MOUNT_DIR}/${path}"
      fi
    done

    if mountpoint -q "${MOUNT_DIR}"; then
      umount "${MOUNT_DIR}"
    fi
  fi

  if [[ -n "${NBD_DEV}" ]]; then
    qemu-nbd --disconnect "${NBD_DEV}" >/dev/null 2>&1 || true
  fi

  rm -rf "${MOUNT_DIR}"
}

release_image() {
  if [[ -n "${MOUNT_DIR}" ]]; then
    for path in dev/pts dev proc sys run boot var/log .snapshots; do
      if mountpoint -q "${MOUNT_DIR}/${path}"; then
        umount "${MOUNT_DIR}/${path}"
      fi
    done

    if mountpoint -q "${MOUNT_DIR}"; then
      umount "${MOUNT_DIR}"
    fi
  fi

  if [[ -n "${NBD_DEV}" ]]; then
    qemu-nbd --disconnect "${NBD_DEV}" >/dev/null 2>&1 || true
    NBD_DEV=""
  fi
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

mount_bind() {
  local source=$1
  local target=$2
  mount --bind "${source}" "${target}"
}

trap cleanup EXIT
require_root
require_file "${BASE_IMAGE_CONFIG_SCRIPT}"
if [[ ! -d "${SSH_DIR}" ]]; then
  echo "Missing required directory: ${SSH_DIR}" >&2
  exit 1
fi
require_file "${SSH_DIR}/authorized_keys"

for cmd in \
  btrfs \
  blkid \
  chroot \
  debootstrap \
  lsblk \
  mkfs.btrfs \
  mkfs.ext4 \
  mount \
  parted \
  partprobe \
  qemu-img \
  qemu-nbd \
  udevadm \
  umount \
  virt-sysprep; do
  require_cmd "${cmd}"
done

mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

rm -f "${OUT_QCOW2}"
qemu-img create -f qcow2 "${OUT_QCOW2}" "${DISK_SIZE}"
attach_nbd "${OUT_QCOW2}"
udevadm settle

parted -s "${NBD_DEV}" -- \
  mklabel msdos \
  mkpart primary ext4 1MiB 1025MiB \
  mkpart primary btrfs 1025MiB 100% \
  set 1 boot on

partprobe "${NBD_DEV}"
udevadm settle

BOOT_PART="${NBD_DEV}p1"
ROOT_PART="${NBD_DEV}p2"

mkfs.ext4 -F -L boot "${BOOT_PART}"
mkfs.btrfs -f -L rootfs "${ROOT_PART}"

MOUNT_DIR="$(mktemp -d)"
mount "${ROOT_PART}" "${MOUNT_DIR}"
btrfs subvolume create "${MOUNT_DIR}/@"
btrfs subvolume create "${MOUNT_DIR}/@var_log"
btrfs subvolume create "${MOUNT_DIR}/@snapshots"
btrfs subvolume set-default "$(btrfs subvolume list "${MOUNT_DIR}" | awk '/ path @$/ {print $2}')" "${MOUNT_DIR}"
umount "${MOUNT_DIR}"

mount -o subvol=@,compress=zstd,noatime "${ROOT_PART}" "${MOUNT_DIR}"
mkdir -p "${MOUNT_DIR}/boot" "${MOUNT_DIR}/var/log" "${MOUNT_DIR}/.snapshots"
mount "${BOOT_PART}" "${MOUNT_DIR}/boot"
mount -o subvol=@var_log,compress=zstd,noatime "${ROOT_PART}" "${MOUNT_DIR}/var/log"
mount -o subvol=@snapshots,compress=zstd,noatime "${ROOT_PART}" "${MOUNT_DIR}/.snapshots"

debootstrap --arch="${ARCH}" --components=main,contrib,non-free-firmware "${DEBIAN_SUITE}" "${MOUNT_DIR}" "https://deb.debian.org/debian"

ROOT_UUID="$(blkid -s UUID -o value "${ROOT_PART}")"
BOOT_UUID="$(blkid -s UUID -o value "${BOOT_PART}")"

if [[ -z "${SOURCES_LIST_FILE}" ]]; then
cat > "${MOUNT_DIR}/etc/apt/sources.list" <<EOF
deb https://deb.debian.org/debian ${DEBIAN_SUITE} main contrib non-free-firmware
deb https://deb.debian.org/debian ${DEBIAN_SUITE}-updates main contrib non-free-firmware
deb https://deb.debian.org/debian-security ${DEBIAN_SUITE}-security main contrib non-free-firmware
EOF
fi

cat > "${MOUNT_DIR}/etc/fstab" <<EOF
UUID=${BOOT_UUID}  /boot       ext4   defaults                           0 2
UUID=${ROOT_UUID}  /           btrfs  subvol=@,compress=zstd,noatime     0 0
UUID=${ROOT_UUID}  /var/log    btrfs  subvol=@var_log,compress=zstd,noatime 0 0
UUID=${ROOT_UUID}  /.snapshots btrfs  subvol=@snapshots,compress=zstd,noatime 0 0
EOF

cat > "${MOUNT_DIR}/etc/hosts" <<EOF
127.0.0.1 localhost

::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

cat > "${MOUNT_DIR}/etc/default/grub" <<'EOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=1
GRUB_DISTRIBUTOR=`dpkg-query -W -f='${binary:Package}\n' 'grub*' | head -n1 | cut -d- -f1`
GRUB_CMDLINE_LINUX_DEFAULT="console=ttyS0,115200n8 net.ifnames=0 biosdevname=0"
GRUB_CMDLINE_LINUX="console=tty0 console=ttyS0,115200n8 net.ifnames=0 biosdevname=0"
EOF

bash "${BASE_IMAGE_CONFIG_SCRIPT}" \
  "${MOUNT_DIR}" \
  "${SSH_DIR}" \
  "${SOURCES_LIST_FILE}"

mount_bind /dev "${MOUNT_DIR}/dev"
mount_bind /dev/pts "${MOUNT_DIR}/dev/pts"
mount_bind /proc "${MOUNT_DIR}/proc"
mount_bind /sys "${MOUNT_DIR}/sys"
mount_bind /run "${MOUNT_DIR}/run"

env -i \
  HOME=/root \
  PATH=/usr/sbin:/usr/bin:/sbin:/bin \
  TERM="${TERM:-xterm}" \
  DEBIAN_FRONTEND=noninteractive \
  LANG=C.UTF-8 \
  LC_ALL=C.UTF-8 \
  ROOT_UUID="${ROOT_UUID}" \
  BOOT_UUID="${BOOT_UUID}" \
  NBD_DEV="${NBD_DEV}" \
  IMAGE_LOCALE="${IMAGE_LOCALE}" \
  chroot "${MOUNT_DIR}" /bin/bash <<'CHROOT'
set -euo pipefail

unit_path() {
  local unit=$1
  local path

  for path in "/usr/lib/systemd/system/${unit}" "/lib/systemd/system/${unit}"; do
    if [[ -e "${path}" ]]; then
      printf '%s\n' "${path}"
      return 0
    fi
  done

  echo "Missing systemd unit: ${unit}" >&2
  exit 1
}

enable_unit() {
  local unit=$1
  local target=$2
  local path

  path="$(unit_path "${unit}")"
  mkdir -p "/etc/systemd/system/${target}.wants"
  ln -sf "${path}" "/etc/systemd/system/${target}.wants/${unit}"
}

apt-get update
apt-get install -y \
  btrfs-progs \
  btrbk \
  ca-certificates \
  cloud-init \
  cloud-guest-utils \
  cron \
  gdisk \
  grub-pc \
  ifupdown \
  wget \
  curl \
  initramfs-tools \
  linux-image-cloud-amd64 \
  locales \
  openssh-server \
  isc-dhcp-client \
  qemu-guest-agent \
  sudo

printf '%s UTF-8\n' "${IMAGE_LOCALE}" > /etc/locale.gen
locale-gen
update-locale LANG="${IMAGE_LOCALE}"
unset LC_ALL
export LANG="${IMAGE_LOCALE}"

enable_unit networking.service multi-user.target
enable_unit cron.service multi-user.target
enable_unit ssh.service multi-user.target
enable_unit qemu-guest-agent.service multi-user.target
mkdir -p /etc/systemd/system/getty.target.wants
ln -sf "$(unit_path serial-getty@.service)" /etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service

install -d -m 0755 /.snapshots/btrbk /etc/btrbk
cat > /etc/btrbk/btrbk.conf <<'EOF'
timestamp_format        long
snapshot_preserve_min   no
snapshot_preserve       24h 7d 0w 0m 0y
snapshot_dir            /.snapshots/btrbk

subvolume /
  snapshot_name root
EOF

cat > /etc/cron.hourly/btrbk <<'EOF'
#!/bin/sh
exec /usr/bin/btrbk -q -c /etc/btrbk/btrbk.conf run
EOF
chmod 0755 /etc/cron.hourly/btrbk

echo "grub-pc grub-pc/install_devices ${NBD_DEV}" | debconf-set-selections
echo "grub-pc grub-pc/install_devices_empty boolean false" | debconf-set-selections

grub-install --target=i386-pc "${NBD_DEV}"
update-initramfs -u
update-grub
CHROOT

release_image

virt-sysprep -a "${OUT_QCOW2}" \
  --operations machine-id,ssh-hostkeys,tmp-files,logfiles,package-manager-cache

echo "Built artifact:"
ls -lh "${OUT_QCOW2}"
