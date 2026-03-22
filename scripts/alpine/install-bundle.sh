#!/usr/bin/env bash
set -euo pipefail

CRON_MARKER="# codex-install-bundle"

sleep 30

if [[ -d /root/ssh ]]; then
  rm -rf /root/.ssh
  mv /root/ssh /root/.ssh
  chmod 0700 /root/.ssh
  if [[ -f /root/.ssh/authorized_keys ]]; then
    chmod 0600 /root/.ssh/authorized_keys
  fi
fi

apk update
apk add \
  bash \
  bind-tools \
  curl \
  docker \
  docker-cli-compose \
  git \
  iperf3 \
  jq \
  nodejs \
  npm \
  py3-pip \
  python3 \
  rsync \
  vim \
  wireguard-tools

rc-update add docker default

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
