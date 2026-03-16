#!/usr/bin/env bash
set -euo pipefail

DEBIAN_VER=13
ARCH=amd64
BASE_IMG="debian-${DEBIAN_VER}-genericcloud-${ARCH}.qcow2"
BASE_URL="https://cloud.debian.org/images/cloud/trixie/latest/${BASE_IMG}"
OUT_IMG="debian-${DEBIAN_VER}-custom-${ARCH}.qcow2"
DOCKER_GPG_URL="https://download.docker.com/linux/debian/gpg"
DOCKER_REPO='deb [arch=arm64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian trixie stable'

ROOT_PUBKEY_FILE="${ROOT_PUBKEY_FILE:-root.pub}"
ROOT_CFG_FILE="${ROOT_CFG_FILE:-files/99-root-login.cfg}"
WORKDIR="${WORKDIR:-$PWD/out}"

require_file() {
  local file=$1
  if [[ ! -f "$file" ]]; then
    echo "Missing required file: $file" >&2
    exit 1
  fi
}

require_file "$ROOT_PUBKEY_FILE"
require_file "$ROOT_CFG_FILE"

mkdir -p "$WORKDIR"
cd "$WORKDIR"

rm -f "$BASE_IMG" "$OUT_IMG" "$OUT_IMG.xz" "$OUT_IMG.xz.sha256"

curl -fL "$BASE_URL" -o "$BASE_IMG"
cp "$BASE_IMG" "$OUT_IMG"

virt-customize -a "$OUT_IMG" \
  --mkdir /root/.ssh \
  --upload "$ROOT_PUBKEY_FILE":/root/.ssh/authorized_keys \
  --chmod 0700:/root/.ssh \
  --chmod 0600:/root/.ssh/authorized_keys \
  --upload "$ROOT_CFG_FILE":/etc/cloud/cloud.cfg.d/99-root-login.cfg \
  --run-command 'chown -R root:root /root/.ssh' \
  --run-command 'userdel -r debian || true' \
  --run-command 'apt-get update' \
  --install 'ca-certificates,curl,gnupg,git,vim,wireguard,rsync' \
  --run-command 'install -m 0755 -d /etc/apt/keyrings' \
  --run-command "curl -fsSL ${DOCKER_GPG_URL} | gpg --dearmor -o /etc/apt/keyrings/docker.gpg" \
  --run-command 'chmod a+r /etc/apt/keyrings/docker.gpg' \
  --run-command "printf '%s\n' \"${DOCKER_REPO}\" > /etc/apt/sources.list.d/docker.list" \
  --run-command 'apt-get update' \
  --run-command 'apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin' \
  --run-command 'systemctl enable docker || true' \
  --run-command 'git clone --depth=1 https://github.com/ohmybash/oh-my-bash.git /root/.oh-my-bash' \
  --run-command 'cp /root/.oh-my-bash/templates/bashrc.osh-template /root/.bashrc' \
  --run-command 'grep -q "^export OSH=" /root/.bashrc || echo "export OSH=/root/.oh-my-bash" >> /root/.bashrc' \
  --run-command 'sed -i "s|^OSH_THEME=.*|OSH_THEME=\"font\"|" /root/.bashrc' \
  --run-command 'printf "\nexport PATH=$PATH:/usr/local/bin\n" >> /root/.bashrc'

virt-sysprep -a "$OUT_IMG" \
  --operations machine-id,ssh-hostkeys,tmp-files,logfiles,package-manager-cache

xz -T0 -z -9 "$OUT_IMG"
sha256sum "$OUT_IMG.xz" > "$OUT_IMG.xz.sha256"

echo "Built artifacts:"
ls -lh "$OUT_IMG.xz" "$OUT_IMG.xz.sha256"