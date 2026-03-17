#!/usr/bin/env bash
set -euo pipefail

DEBIAN_VER=13
ARCH=amd64
BASE_IMG="debian-${DEBIAN_VER}-genericcloud-${ARCH}.qcow2"
BASE_URL="https://cloud.debian.org/images/cloud/trixie/latest/${BASE_IMG}"
OUT_QCOW2="debian-${DEBIAN_VER}-custom-${ARCH}.qcow2"
OUT_RAW="debian-${DEBIAN_VER}-custom-${ARCH}.raw"
DOCKER_GPG_URL="https://download.docker.com/linux/debian/gpg"
DOCKER_REPO='deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian trixie stable'
NODE_VER="$(curl -fsSL https://nodejs.org/dist/index.json | jq -r '[.[] | select(.lts)][0].version')"
NODE_URL="https://nodejs.org/dist/${NODE_VER}/node-${NODE_VER}-linux-x64.tar.xz"

ROOT_PUBKEY_FILE="$(realpath "${ROOT_PUBKEY_FILE:-root.pub}")"
ROOT_CFG_FILE="$(realpath "${ROOT_CFG_FILE:-files/99-root-login.cfg}")"
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

rm -f "$BASE_IMG" "$OUT_QCOW2" "$OUT_RAW" "$OUT_RAW.xz" "$OUT_RAW.xz.sha256"
curl -fL "$BASE_URL" -o "$BASE_IMG"

cp "$BASE_IMG" "$OUT_QCOW2"

# --- Build cloud-init NoCloud ISO ---
CIDIR="$(mktemp -d)"
trap 'rm -rf "$CIDIR"' EXIT

ROOT_PUBKEY="$(cat "$ROOT_PUBKEY_FILE")"
ROOT_CFG_CONTENT="$(cat "$ROOT_CFG_FILE")"

cat > "$CIDIR/meta-data" <<EOF
instance-id: build-$(date +%s)
local-hostname: build
EOF

cat > "$CIDIR/user-data" <<USERDATA
#cloud-config
disable_root: false
ssh_pwauth: false

write_files:
  - path: /root/.ssh/authorized_keys
    owner: root:root
    permissions: '0600'
    content: |
      ${ROOT_PUBKEY}
  - path: /etc/cloud/cloud.cfg.d/99-root-login.cfg
    owner: root:root
    permissions: '0644'
    content: |
$(echo "$ROOT_CFG_CONTENT" | sed 's/^/      /')

runcmd:
  - mkdir -p /root/.ssh && chmod 0700 /root/.ssh
  - chown -R root:root /root/.ssh
  - userdel -r debian || true
  - apt-get update
  - echo "iperf3 iperf3/start_daemon boolean false" | debconf-set-selections
  - apt-get install -y ca-certificates curl gnupg jq git vim wireguard rsync python3-venv python3-pip iperf3 bind9-dnsutils qemu-guest-agent
  - install -m 0755 -d /etc/apt/keyrings
  - curl -fsSL ${DOCKER_GPG_URL} | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  - chmod a+r /etc/apt/keyrings/docker.gpg
  - printf '%s\n' '${DOCKER_REPO}' > /etc/apt/sources.list.d/docker.list
  - apt-get update
  - apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  - systemctl enable docker || true
  - git clone --depth=1 https://github.com/ohmybash/oh-my-bash.git /usr/local/share/oh-my-bash
  - cp /usr/local/share/oh-my-bash/templates/bashrc.osh-template /root/.bashrc
  - sed -i 's|^OSH=.*|OSH=/usr/local/share/oh-my-bash|' /root/.bashrc
  - sed -i 's|^OSH_THEME=.*|OSH_THEME="vscode"|' /root/.bashrc
  - printf '\nexport PATH=\$PATH:/usr/local/bin\n' >> /root/.bashrc
  - echo 'PROMPT_COMMAND='"'"'echo -en "\033]0;\$(whoami)@\$(hostname)\a"'"'"'' >> /root/.bashrc
  # Use classic eth0 naming instead of ens*
  - sed -i 's|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT="net.ifnames=0 biosdevname=0"|' /etc/default/grub
  - sed -i 's|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX="net.ifnames=0 biosdevname=0"|' /etc/default/grub
  - update-grub
  # Node.js LTS (system-wide via official binary tarball)
  - curl -fsSL ${NODE_URL} | tar -xJ --strip-components=1 -C /usr/local
  # Codex and Claude
  - npm install -g @openai/codex
  - npm install -g @anthropic-ai/claude-code
  - systemctl enable qemu-guest-agent || true

power_state:
  mode: poweroff
  message: "Cloud-init customization complete, shutting down."
  timeout: 30
  condition: true
USERDATA

SEED_ISO="$WORKDIR/seed.iso"
genisoimage -output "$SEED_ISO" -volid cidata -joliet -rock \
  "$CIDIR/user-data" "$CIDIR/meta-data"

# --- Boot QEMU and let cloud-init customize the image ---
echo "Booting QEMU to run cloud-init customization..."
qemu-system-x86_64 \
  -enable-kvm \
  -m 2048 \
  -cpu host \
  -nographic \
  -drive file="$OUT_QCOW2",format=qcow2,if=virtio \
  -drive file="$SEED_ISO",format=raw,if=virtio \
  -netdev user,id=net0 \
  -device virtio-net-pci,netdev=net0

echo "QEMU exited."
rm -f "$SEED_ISO"

# --- Sysprep the image (offline, no network needed) ---
virt-sysprep -a "$OUT_QCOW2" \
  --operations machine-id,ssh-hostkeys,tmp-files,logfiles,package-manager-cache

# --- Convert qcow2 to raw ---
qemu-img convert -f qcow2 -O raw "$OUT_QCOW2" "$OUT_RAW"
rm -f "$OUT_QCOW2"

xz -T0 -z "$OUT_RAW"
sha256sum "$OUT_RAW.xz" > "$OUT_RAW.xz.sha256"

echo "Built artifacts:"
ls -lh "$OUT_RAW.xz" "$OUT_RAW.xz.sha256"
