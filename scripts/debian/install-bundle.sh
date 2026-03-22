#!/usr/bin/env bash
set -euo pipefail

DOCKER_GPG_URL="${DOCKER_GPG_URL:-https://download.docker.com/linux/debian/gpg}"
DOCKER_REPO="${DOCKER_REPO:-deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian trixie stable}"
CRON_MARKER="# codex-install-bundle"

sleep 60

if [[ -d /root/ssh ]]; then
  rm -rf /root/.ssh
  mv /root/ssh /root/.ssh
  chmod 0700 /root/.ssh
  if [[ -f /root/.ssh/authorized_keys ]]; then
    chmod 0600 /root/.ssh/authorized_keys
  fi
fi

echo "iperf3 iperf3/start_daemon boolean false" | debconf-set-selections

apt-get update
apt-get install -y \
  bind9-dnsutils \
  curl \
  git \
  gnupg \
  iperf3 \
  jq \
  python3-pip \
  python3-venv \
  rsync \
  vim \
  wireguard

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

if [[ -f /root/.bashrc && ! -f /root/.bashrc.hypervisor ]]; then
  cp /root/.bashrc /root/.bashrc.hypervisor
fi

if [[ ! -d /usr/local/share/oh-my-bash/.git ]]; then
  git clone --depth=1 https://github.com/ohmybash/oh-my-bash.git /usr/local/share/oh-my-bash
fi

cp /usr/local/share/oh-my-bash/templates/bashrc.osh-template /root/.bashrc
sed -i '/^OSH=/c\OSH="/usr/local/share/oh-my-bash"' /root/.bashrc
sed -i 's|^OSH_THEME=.*|OSH_THEME="vscode"|' /root/.bashrc
printf '\nexport PATH=$PATH:/usr/local/bin\n' >> /root/.bashrc
printf '%s\n' 'PROMPT_COMMAND='\''echo -en "\033]0;$(whoami)@$(hostname)\a"'\''' >> /root/.bashrc

NODE_VER="$(curl -fsSL https://nodejs.org/dist/index.json | jq -r '[.[] | select(.lts)][0].version')"
NODE_URL="https://nodejs.org/dist/${NODE_VER}/node-${NODE_VER}-linux-x64.tar.xz"

curl -fsSL "${NODE_URL}" | tar -xJ --strip-components=1 -C /usr/local
npm install -g @openai/codex
npm install -g @anthropic-ai/claude-code

tmp_crontab="$(mktemp)"
if crontab -l >| "${tmp_crontab}" 2>/dev/null; then
  filtered_crontab="$(mktemp)"
  grep -Fv "${CRON_MARKER}" "${tmp_crontab}" >| "${filtered_crontab}"
  crontab "${filtered_crontab}"
  rm -f "${filtered_crontab}"
fi
rm -f "${tmp_crontab}"
