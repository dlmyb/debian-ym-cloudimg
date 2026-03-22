#!/usr/bin/env bash
set -euo pipefail

ALPINE_VERSION="${ALPINE_VERSION:-3.23.3}"
ALPINE_SERIES="${ALPINE_SERIES:-${ALPINE_VERSION%.*}}"
ALPINE_ARCH="${ALPINE_ARCH:-x86_64}"
OUT_ARCH="${OUT_ARCH:-amd64}"
DISK_SIZE="${DISK_SIZE:-5G}"
OUT_QCOW2="alpine-${ALPINE_VERSION}-ext4-${OUT_ARCH}.qcow2"
OUT_RAW="alpine-${ALPINE_VERSION}-ext4-${OUT_ARCH}.raw"
ALPINE_MIRROR="${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}"
MINIROOTFS="alpine-minirootfs-${ALPINE_VERSION}-${ALPINE_ARCH}.tar.gz"
MINIROOTFS_URL="${ALPINE_MIRROR}/v${ALPINE_SERIES}/releases/${ALPINE_ARCH}/${MINIROOTFS}"
MINIROOTFS_SHA256_URL="${MINIROOTFS_URL}.sha256"

SSH_DIR="$(realpath "${SSH_DIR:-ssh}")"
RESOLV_CONF_FILE="$(realpath "${RESOLV_CONF_FILE:-files/resolv.conf}")"
SCRIPTS_DIR="$(realpath "${SCRIPTS_DIR:-scripts/alpine}")"
WORKDIR="${WORKDIR:-$PWD/out}"
MOUNT_DIR=""
NBD_DEV=""

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
    for path in dev/pts dev proc sys run boot; do
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
    for path in dev/pts dev proc sys run boot; do
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
require_file "${RESOLV_CONF_FILE}"
if [[ ! -d "${SSH_DIR}" ]]; then
  echo "Missing required directory: ${SSH_DIR}" >&2
  exit 1
fi
require_file "${SSH_DIR}/authorized_keys"
if [[ ! -d "${SCRIPTS_DIR}" ]]; then
  echo "Missing required directory: ${SCRIPTS_DIR}" >&2
  exit 1
fi

if [[ "${ALPINE_ARCH}" != "x86_64" ]]; then
  echo "This builder currently supports ALPINE_ARCH=x86_64 only." >&2
  exit 1
fi

for cmd in \
  blkid \
  chroot \
  curl \
  mkfs.ext4 \
  mount \
  mountpoint \
  parted \
  partprobe \
  qemu-img \
  qemu-nbd \
  sha256sum \
  tar \
  udevadm \
  umount \
  virt-sysprep \
  xz; do
  require_cmd "${cmd}"
done

mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

rm -f "${OUT_QCOW2}" "${OUT_RAW}" "${OUT_RAW}.xz" "${OUT_RAW}.xz.sha256"
rm -f "${MINIROOTFS}" "${MINIROOTFS}.sha256"

curl -fL --retry 3 -o "${MINIROOTFS}" "${MINIROOTFS_URL}"
curl -fL --retry 3 -o "${MINIROOTFS}.sha256" "${MINIROOTFS_SHA256_URL}"
sha256sum -c "${MINIROOTFS}.sha256"

qemu-img create -f qcow2 "${OUT_QCOW2}" "${DISK_SIZE}"
attach_nbd "${OUT_QCOW2}"

parted -s "${NBD_DEV}" -- \
  mklabel msdos \
  mkpart primary ext4 1MiB 1025MiB \
  mkpart primary ext4 1025MiB 100% \
  set 1 boot on

partprobe "${NBD_DEV}"
udevadm settle

BOOT_PART="${NBD_DEV}p1"
ROOT_PART="${NBD_DEV}p2"

mkfs.ext4 -F -L boot "${BOOT_PART}"
mkfs.ext4 -F -L rootfs "${ROOT_PART}"

MOUNT_DIR="$(mktemp -d)"
mount "${ROOT_PART}" "${MOUNT_DIR}"
mkdir -p "${MOUNT_DIR}/boot"
mount "${BOOT_PART}" "${MOUNT_DIR}/boot"

tar -xzf "${MINIROOTFS}" -C "${MOUNT_DIR}"

ROOT_UUID="$(blkid -s UUID -o value "${ROOT_PART}")"
BOOT_UUID="$(blkid -s UUID -o value "${BOOT_PART}")"

cat > "${MOUNT_DIR}/etc/apk/repositories" <<EOF
${ALPINE_MIRROR}/v${ALPINE_SERIES}/main
${ALPINE_MIRROR}/v${ALPINE_SERIES}/community
EOF

cat > "${MOUNT_DIR}/etc/fstab" <<EOF
UUID=${ROOT_UUID}  /      ext4  defaults,noatime  0 1
UUID=${BOOT_UUID}  /boot  ext4  defaults          0 2
EOF

cat > "${MOUNT_DIR}/etc/hosts" <<EOF
127.0.0.1 localhost

::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

mkdir -p \
  "${MOUNT_DIR}/etc/default" \
  "${MOUNT_DIR}/etc/network" \
  "${MOUNT_DIR}/root"

cat > "${MOUNT_DIR}/etc/network/interfaces" <<'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF

cat > "${MOUNT_DIR}/etc/default/grub" <<'EOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=1
GRUB_CMDLINE_LINUX_DEFAULT="console=ttyS0,115200n8 net.ifnames=0 biosdevname=0 rootfstype=ext4 rootwait modules=virtio_pci,virtio_blk,ext4"
GRUB_CMDLINE_LINUX="console=tty0 console=ttyS0,115200n8 net.ifnames=0 biosdevname=0 rootfstype=ext4 rootwait modules=virtio_pci,virtio_blk,ext4"
EOF

install -m 0644 "${RESOLV_CONF_FILE}" "${MOUNT_DIR}/etc/resolv.conf"
cp -a "${SSH_DIR}" "${MOUNT_DIR}/root/ssh"
chown -R root:root "${MOUNT_DIR}/root/ssh"
mkdir -p "${MOUNT_DIR}/root/scripts"
cp -a "${SCRIPTS_DIR}/." "${MOUNT_DIR}/root/scripts/"
chown -R root:root "${MOUNT_DIR}/root/scripts"

mount_bind /dev "${MOUNT_DIR}/dev"
mount_bind /dev/pts "${MOUNT_DIR}/dev/pts"
mount_bind /proc "${MOUNT_DIR}/proc"
mount_bind /sys "${MOUNT_DIR}/sys"
mount_bind /run "${MOUNT_DIR}/run"

env -i \
  HOME=/root \
  PATH=/usr/sbin:/usr/bin:/sbin:/bin \
  TERM="${TERM:-xterm}" \
  NBD_DEV="${NBD_DEV}" \
  chroot "${MOUNT_DIR}" /bin/sh <<'CHROOT'
set -euo pipefail

apk update
apk add \
  alpine-base \
  bash \
  cronie \
  cronie-openrc \
  e2fsprogs \
  e2fsprogs-extra \
  dhcpcd \
  grub \
  grub-bios \
  linux-virt \
  mkinitfs \
  openssh-server \
  qemu-guest-agent \
  qemu-guest-agent-openrc \
  shadow \
  sudo

sed -i '/^slaac private/s/^/#/' /etc/dhcpcd.conf
sed -i '/^#slaac hwaddr/s/^#//' /etc/dhcpcd.conf
grep -q '^adm:' /etc/group || addgroup -S adm
grep -q '^sudo:' /etc/group || addgroup -S sudo
addgroup root adm || true
addgroup root sudo || true
usermod -s /bin/bash root

cat > /etc/mkinitfs/mkinitfs.conf <<'EOF'
features="ata base ide scsi usb virtio ext4"
EOF

if grep -q '^#ttyS0::respawn:' /etc/inittab; then
  sed -i 's/^#ttyS0::respawn:/ttyS0::respawn:/' /etc/inittab
elif ! grep -q '^ttyS0::respawn:' /etc/inittab; then
  printf '%s\n' 'ttyS0::respawn:/sbin/getty -L ttyS0 115200 vt100' >> /etc/inittab
fi

mkdir -p /etc/ssh
sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config

rc-update add networking boot
rc-update add seedrng boot
rc-update add crond default
rc-update add sshd default
rc-update add qemu-guest-agent default

chown root:root /etc/resolv.conf
chmod 0644 /etc/resolv.conf

if [[ -f /root/scripts/install-bundle.sh ]]; then
  cat > /tmp/root-crontab <<'EOF'
@reboot /bin/bash /root/scripts/install-bundle.sh # codex-install-bundle
EOF
  crontab /tmp/root-crontab
  rm -f /tmp/root-crontab
fi

KERNEL_VERSION="$(basename "$(find /lib/modules -mindepth 1 -maxdepth 1 -type d | head -n1)")"
mkinitfs "${KERNEL_VERSION}"

grub-install --target=i386-pc "${NBD_DEV}"
grub-mkconfig -o /boot/grub/grub.cfg
CHROOT

release_image

virt-sysprep -a "${OUT_QCOW2}" \
  --operations machine-id,ssh-hostkeys,tmp-files,logfiles,package-manager-cache

qemu-img convert -f qcow2 -O raw "${OUT_QCOW2}" "${OUT_RAW}"
xz -T0 -9 -z "${OUT_RAW}"
sha256sum "${OUT_RAW}.xz" > "${OUT_RAW}.xz.sha256"

echo "Built artifacts:"
ls -lh "${OUT_RAW}.xz" "${OUT_RAW}.xz.sha256"
