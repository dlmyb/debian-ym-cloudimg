#!/usr/bin/env bash
set -euo pipefail

if [[ ! -f root.pub ]]; then
  echo 'Create root.pub first with your SSH public key.' >&2
  exit 1
fi

if [[ ! -f files/99-root-login.cfg ]]; then
  echo 'Missing files/99-root-login.cfg' >&2
  exit 1
fi

chmod +x build-image.sh
./build-image.sh
