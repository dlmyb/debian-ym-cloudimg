# Debian and Alpine Cloud Image Builder

This repo builds customized Debian 13 amd64 and Alpine images from a fresh bootstrap install, then provisions them offline through a chroot stage.

## Base image contents

- Debian builders stage `ssh/authorized_keys` as `/root/ssh/authorized_keys`, then the first-boot bundle script restores it to `/root/.ssh/authorized_keys`
- Alpine builder stages `ssh/authorized_keys` as `/root/ssh/authorized_keys`, then the first-boot bundle script restores it to `/root/.ssh/authorized_keys`
- packages installed:
  - `openssh-server`
  - `qemu-guest-agent`
- `virt-sysprep` cleans machine identity before publishing

## Files

- `build-image-ext4.sh` builds the ext4 image locally or on CI
- `build-image-btrfs.sh` builds the btrfs image locally
- `build-image-alpine.sh` builds an Alpine cloud image locally
- `files/resolv.conf` is copied into `/etc/resolv.conf` for each image
- `scripts/debian/` is copied into `/root/scripts` for Debian images
- `scripts/alpine/` is copied into `/root/scripts` for Alpine images
- `reinstall/` is a git submodule for the upstream reinstall project used with the generated raw images

## Local build

Install dependencies on your Linux builder:

```bash
sudo apt-get update
sudo apt-get install -y curl e2fsprogs libguestfs-tools qemu-utils xz-utils debootstrap parted btrfs-progs
```

Add your Debian SSH authorized key:

```bash
mkdir -p ssh
cat > ssh/authorized_keys <<'EOF'
ssh-ed25519 AAAA... your-key-comment
EOF
```

Run the build:

```bash
chmod +x build-image-ext4.sh
./build-image-ext4.sh
```

Artifacts are written to `out/`.

## Ext4 build

The `build-image-ext4.sh` script creates a fresh disk image, provisions Debian with `debootstrap`, customizes it in a chroot, and writes `debian-13-ext4-amd64.raw.xz` into `out/`.

Current layout:

- `/boot` on `ext4`
- `/` on `ext4`

Run it with:

```bash
sudo chmod +x build-image-ext4.sh
sudo ./build-image-ext4.sh
```

## Btrfs build

The `build-image-btrfs.sh` script creates a fresh disk image, formats the root filesystem as `btrfs`, creates subvolumes, bootstraps Debian with `debootstrap`, customizes it in a chroot, and writes `debian-13-btrfs-amd64.raw.xz` into `out/`.

Current layout:

- `/boot` on `ext4`
- `/` on `btrfs` subvolume `@`
- `/home` on `btrfs` subvolume `@home`
- `/var/log` on `btrfs` subvolume `@var_log`
- `/.snapshots` on `btrfs` subvolume `@snapshots`

Run it with:

```bash
sudo chmod +x build-image-btrfs.sh
sudo ./build-image-btrfs.sh
```

## Alpine build

The `build-image-alpine.sh` script creates a fresh disk image, downloads the official Alpine minirootfs, customizes it in a chroot, and writes `alpine-3.23.3-ext4-amd64.raw.xz` into `out/`.

Current layout:

- `/boot` on `ext4`
- `/` on `ext4`

Run it with:

```bash
sudo chmod +x build-image-alpine.sh
sudo ./build-image-alpine.sh
```

The Alpine builder uses OpenRC instead of systemd, installs `openssh-server` and `qemu-guest-agent`, does not write a static hostname, copies `scripts/alpine/` into `/root/scripts`, and registers Alpine's `/root/scripts/install-bundle.sh` with `@reboot`.

All builders assume a BIOS/QEMU boot path.
The Debian builders use `grub-pc`, and the Alpine builder uses `grub-bios`.

The Debian builders copy `scripts/debian/` into `/root/scripts` inside the image, and copy `ssh/` into `/root/ssh`.
The Alpine builder copies `scripts/alpine/` into `/root/scripts` inside the image, and also copies `ssh/` into `/root/ssh`.
If `/root/scripts/install-bundle.sh` exists, each builder registers it in root's crontab with `@reboot`; it waits 60 seconds on Debian and 5 minutes on Alpine, runs once, and removes its own crontab entry when finished.
All builders copy `files/resolv.conf` into `/etc/resolv.conf`.
The Debian builders mark it immutable; the Alpine builder does not.
The btrfs Debian image also installs `btrbk`, writes `/etc/btrbk/btrbk.conf`, and runs it from `/etc/cron.hourly/btrbk` to snapshot `/` and `/home` into `/.snapshots/btrbk` with retention `24h 7d 0w 0m 0y`.
The repository also vendors the upstream `reinstall` project as a submodule in `reinstall/` for reference and integration with the produced raw images.

## Notes

- The output image is `raw`, compressed with `xz`, in order to works with [reinstall script](https://github.com/bin456789/reinstall.git), which is a submodule of this repo 
- `root` login is key-only by default; no root password is set
