#!/usr/bin/env bash
set -euo pipefail

DEBIAN_VER=13
DEBIAN_SUITE=trixie
ARCH=amd64
DISK_SIZE="${DISK_SIZE:-5G}"
OUT_QCOW2="debian-${DEBIAN_VER}-btrfs-${ARCH}.qcow2"
OUT_RAW="debian-${DEBIAN_VER}-btrfs-${ARCH}.raw"
DOCKER_GPG_URL="https://download.docker.com/linux/debian/gpg"
DOCKER_REPO='deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian trixie stable'
NODE_VER="$(curl -fsSL https://nodejs.org/dist/index.json | jq -r '[.[] | select(.lts)][0].version')"
NODE_URL="https://nodejs.org/dist/${NODE_VER}/node-${NODE_VER}-linux-x64.tar.xz"

ROOT_PUBKEY_FILE="$(realpath "${ROOT_PUBKEY_FILE:-root.pub}")"
ROOT_CFG_FILE="$(realpath "${ROOT_CFG_FILE:-files/99-root-login.cfg}")"
WORKDIR="${WORKDIR:-$PWD/out}"
HOSTNAME="${HOSTNAME:-build}"
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
    for path in dev/pts dev proc sys run boot var/log home .snapshots; do
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
    for path in dev/pts dev proc sys run boot var/log home .snapshots; do
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
require_file "${ROOT_PUBKEY_FILE}"
require_file "${ROOT_CFG_FILE}"

for cmd in \
  btrfs \
  blkid \
  chroot \
  curl \
  debootstrap \
  jq \
  lsblk \
  mkfs.btrfs \
  mkfs.ext4 \
  mount \
  parted \
  partprobe \
  qemu-img \
  qemu-nbd \
  sha256sum \
  udevadm \
  umount \
  virt-sysprep \
  xz; do
  require_cmd "${cmd}"
done

mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

rm -f "${OUT_QCOW2}" "${OUT_RAW}" "${OUT_RAW}.xz" "${OUT_RAW}.xz.sha256"
qemu-img create -f qcow2 "${OUT_QCOW2}" "${DISK_SIZE}"
attach_nbd "${OUT_QCOW2}"

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
btrfs subvolume create "${MOUNT_DIR}/@home"
btrfs subvolume create "${MOUNT_DIR}/@var_log"
btrfs subvolume create "${MOUNT_DIR}/@snapshots"
btrfs subvolume set-default "$(btrfs subvolume list "${MOUNT_DIR}" | awk '/ path @$/ {print $2}')" "${MOUNT_DIR}"
umount "${MOUNT_DIR}"

mount -o subvol=@,compress=zstd,noatime "${ROOT_PART}" "${MOUNT_DIR}"
mkdir -p "${MOUNT_DIR}/boot" "${MOUNT_DIR}/home" "${MOUNT_DIR}/var/log" "${MOUNT_DIR}/.snapshots"
mount "${BOOT_PART}" "${MOUNT_DIR}/boot"
mount -o subvol=@home,compress=zstd,noatime "${ROOT_PART}" "${MOUNT_DIR}/home"
mount -o subvol=@var_log,compress=zstd,noatime "${ROOT_PART}" "${MOUNT_DIR}/var/log"
mount -o subvol=@snapshots,compress=zstd,noatime "${ROOT_PART}" "${MOUNT_DIR}/.snapshots"

debootstrap --arch="${ARCH}" --components=main,contrib,non-free-firmware "${DEBIAN_SUITE}" "${MOUNT_DIR}" "https://deb.debian.org/debian"

ROOT_UUID="$(blkid -s UUID -o value "${ROOT_PART}")"
BOOT_UUID="$(blkid -s UUID -o value "${BOOT_PART}")"
ROOT_PUBKEY="$(cat "${ROOT_PUBKEY_FILE}")"
ROOT_CFG_CONTENT="$(cat "${ROOT_CFG_FILE}")"

cat > "${MOUNT_DIR}/etc/apt/sources.list" <<EOF
deb https://deb.debian.org/debian ${DEBIAN_SUITE} main contrib non-free-firmware
deb https://deb.debian.org/debian ${DEBIAN_SUITE}-updates main contrib non-free-firmware
deb https://deb.debian.org/debian-security ${DEBIAN_SUITE}-security main contrib non-free-firmware
EOF

cat > "${MOUNT_DIR}/etc/fstab" <<EOF
UUID=${BOOT_UUID}  /boot       ext4   defaults                           0 2
UUID=${ROOT_UUID}  /           btrfs  subvol=@,compress=zstd,noatime     0 0
UUID=${ROOT_UUID}  /home       btrfs  subvol=@home,compress=zstd,noatime 0 0
UUID=${ROOT_UUID}  /var/log    btrfs  subvol=@var_log,compress=zstd,noatime 0 0
UUID=${ROOT_UUID}  /.snapshots btrfs  subvol=@snapshots,compress=zstd,noatime 0 0
EOF

echo "${HOSTNAME}" > "${MOUNT_DIR}/etc/hostname"

cat > "${MOUNT_DIR}/etc/hosts" <<EOF
127.0.0.1 localhost
127.0.1.1 ${HOSTNAME}

::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

mkdir -p "${MOUNT_DIR}/etc/systemd/network" "${MOUNT_DIR}/etc/cloud/cloud.cfg.d" "${MOUNT_DIR}/root/.ssh"

cat > "${MOUNT_DIR}/etc/systemd/network/20-wired.network" <<'EOF'
[Match]
Name=en* eth*

[Network]
DHCP=yes
EOF

cat > "${MOUNT_DIR}/etc/default/grub" <<'EOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=1
GRUB_DISTRIBUTOR=`dpkg-query -W -f='${binary:Package}\n' 'grub*' | head -n1 | cut -d- -f1`
GRUB_CMDLINE_LINUX_DEFAULT="console=ttyS0,115200n8 net.ifnames=0 biosdevname=0"
GRUB_CMDLINE_LINUX="console=tty0 console=ttyS0,115200n8 net.ifnames=0 biosdevname=0"
EOF

cat > "${MOUNT_DIR}/etc/cloud/cloud.cfg.d/99-root-login.cfg" <<EOF
${ROOT_CFG_CONTENT}
EOF

chmod 0700 "${MOUNT_DIR}/root/.ssh"
cat > "${MOUNT_DIR}/root/.ssh/authorized_keys" <<EOF
${ROOT_PUBKEY}
EOF
chmod 0600 "${MOUNT_DIR}/root/.ssh/authorized_keys"

mount_bind /dev "${MOUNT_DIR}/dev"
mount_bind /dev/pts "${MOUNT_DIR}/dev/pts"
mount_bind /proc "${MOUNT_DIR}/proc"
mount_bind /sys "${MOUNT_DIR}/sys"
mount_bind /run "${MOUNT_DIR}/run"

ROOT_UUID="${ROOT_UUID}" \
BOOT_UUID="${BOOT_UUID}" \
NBD_DEV="${NBD_DEV}" \
DOCKER_GPG_URL="${DOCKER_GPG_URL}" \
DOCKER_REPO="${DOCKER_REPO}" \
NODE_URL="${NODE_URL}" \
chroot "${MOUNT_DIR}" /bin/bash <<'CHROOT'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update
echo "iperf3 iperf3/start_daemon boolean false" | debconf-set-selections
apt-get install -y \
  bind9-dnsutils \
  btrfs-progs \
  ca-certificates \
  cloud-init \
  cloud-guest-utils \
  curl \
  gdisk \
  git \
  gnupg \
  grub-pc \
  iperf3 \
  initramfs-tools \
  jq \
  linux-image-cloud-amd64 \
  openssh-server \
  python3-pip \
  python3-venv \
  qemu-guest-agent \
  rsync \
  sudo \
  systemd-resolved \
  vim \
  wireguard

systemctl enable systemd-networkd
systemctl enable systemd-resolved
systemctl enable ssh
systemctl enable qemu-guest-agent
systemctl enable serial-getty@ttyS0.service

ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

install -m 0755 -d /etc/apt/keyrings
curl -fsSL "${DOCKER_GPG_URL}" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
printf '%s\n' "${DOCKER_REPO}" > /etc/apt/sources.list.d/docker.list

apt-get update
apt-get install -y \
  containerd.io \
  docker-buildx-plugin \
  docker-ce \
  docker-ce-cli \
  docker-compose-plugin

systemctl enable docker

git clone --depth=1 https://github.com/ohmybash/oh-my-bash.git /usr/local/share/oh-my-bash
cp /usr/local/share/oh-my-bash/templates/bashrc.osh-template /root/.bashrc
sed -i 's|^OSH=.*|OSH=/usr/local/share/oh-my-bash|' /root/.bashrc
sed -i 's|^OSH_THEME=.*|OSH_THEME="vscode"|' /root/.bashrc
printf '\n%s\n' 'PROMPT_COMMAND='\''echo -en "\033]0;$(whoami)@$(hostname)\a"'\''' >> /root/.bashrc

curl -fsSL "${NODE_URL}" | tar -xJ --strip-components=1 -C /usr/local
npm install -g @openai/codex
npm install -g @anthropic-ai/claude-code

echo "grub-pc grub-pc/install_devices ${NBD_DEV}" | debconf-set-selections
echo "grub-pc grub-pc/install_devices_empty boolean false" | debconf-set-selections

grub-install --target=i386-pc "${NBD_DEV}"
update-initramfs -u
update-grub
CHROOT

release_image

virt-sysprep -a "${OUT_QCOW2}" \
  --operations machine-id,ssh-hostkeys,tmp-files,logfiles,package-manager-cache

qemu-img convert -f qcow2 -O raw "${OUT_QCOW2}" "${OUT_RAW}"
xz -T0 -9 -z "${OUT_RAW}"
sha256sum "${OUT_RAW}.xz" > "${OUT_RAW}.xz.sha256"

echo "Built artifacts:"
ls -lh "${OUT_RAW}.xz" "${OUT_RAW}.xz.sha256"
