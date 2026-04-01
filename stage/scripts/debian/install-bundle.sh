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

if [[ -d /root/ssh-host-keys ]]; then
  for host_key in /root/ssh-host-keys/ssh_host_*_key; do
    [[ -f "${host_key}" ]] || continue
    host_key_name="$(basename "${host_key}")"
    install -m 0600 "${host_key}" "/etc/ssh/${host_key_name}"
    pub_key="${host_key}.pub"
    if [[ -f "${pub_key}" ]]; then
      install -m 0644 "${pub_key}" "/etc/ssh/${host_key_name}.pub"
    fi
  done
  chown root:root /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub 2>/dev/null || true
fi

for service in sshd.service ssh.service sshd.socket ssh.socket; do
  if systemctl is-enabled "${service}" >/dev/null 2>&1 || systemctl is-active "${service}" >/dev/null 2>&1; then
    systemctl restart "${service}" || true
    break
  fi
done

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
sed -i \
  -e '/^export OSH=/c\export OSH=/usr/local/share/oh-my-bash' \
  -e '/^OSH=/c\export OSH=/usr/local/share/oh-my-bash' \
  /root/.bashrc
sed -i 's|^OSH_THEME=.*|OSH_THEME="vscode"|' /root/.bashrc
printf '\nexport PATH=$PATH:/usr/local/bin\n' >> /root/.bashrc
printf '%s\n' 'PROMPT_COMMAND='\''echo -en "\033]0;$(whoami)@$(hostname)\a"'\''' >> /root/.bashrc

NODE_VER="$(curl -fsSL https://nodejs.org/dist/index.json | jq -r '[.[] | select(.lts)][0].version')"
NODE_URL="https://nodejs.org/dist/${NODE_VER}/node-${NODE_VER}-linux-x64.tar.xz"

curl -fsSL "${NODE_URL}" | tar -xJ --strip-components=1 -C /usr/local
npm install -g @openai/codex
npm install -g @anthropic-ai/claude-code

if command -v crontab >/dev/null 2>&1; then
  tmp_crontab="$(mktemp)"
  if EDITOR=true VISUAL=true crontab -l >| "${tmp_crontab}" 2>/dev/null; then
    if grep -Fq "${CRON_MARKER}" "${tmp_crontab}"; then
      filtered_crontab="$(mktemp)"
      grep -Fv "${CRON_MARKER}" "${tmp_crontab}" >| "${filtered_crontab}" || true
      EDITOR=true VISUAL=true crontab "${filtered_crontab}" || true
      rm -f "${filtered_crontab}"
    fi
  fi
  rm -f "${tmp_crontab}"
fi
