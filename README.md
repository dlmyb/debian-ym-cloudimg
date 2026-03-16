# Debian 13 amd64 Cloud Image Builder

This repo builds a customized Debian 13 amd64 cloud image from the official `debian-13-genericcloud-amd64.qcow2` base image.

## Included customizations

- `root` is the intended default login user through cloud-init
- your SSH public key is installed into `/root/.ssh/authorized_keys`
- packages installed:
  - Docker CE + CLI + Buildx + Compose plugin
  - `vim`
  - `wireguard`
  - `rsync`
  - `git`
  - `oh-my-bash`
- the stock `debian` user is removed if present
- `virt-sysprep` cleans machine identity before publishing

## Files

- `build-image.sh` builds the image locally or on CI
- `run-local.sh` is a thin local helper
- `files/99-root-login.cfg` is the cloud-init override
- `.github/workflows/build-image.yml` builds on a self-hosted GitHub Actions runner

## Local build

Install dependencies on your Linux builder:

```bash
sudo apt-get update
sudo apt-get install -y libguestfs-tools qemu-utils curl jq xz-utils
```

Add your SSH public key:

```bash
cat > root.pub <<'EOF'
ssh-ed25519 AAAA... your-key-comment
EOF
```

Run the build:

```bash
chmod +x run-local.sh
./run-local.sh
```

Artifacts are written to `out/`.

## GitHub Actions

Set this repository secret:

- `ROOT_PUBKEY` � your SSH public key contents

The workflow writes `root.pub`, creates `files/99-root-login.cfg`, runs `build-image.sh`, and uploads the compressed image artifacts.

## Notes

- The output image is `qcow2`, compressed with `xz`
- The workflow is configured for a `self-hosted` runner
- `root` login is key-only by default; no root password is set