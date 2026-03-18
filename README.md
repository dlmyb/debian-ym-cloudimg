# Debian 13 amd64 Cloud Image Builder

This repo builds customized Debian 13 amd64 cloud images from a fresh `debootstrap` install, then provisions them offline through a chroot stage.

## Base image contents

- `root` is the intended default login user through cloud-init
- your SSH public key is installed into `/root/.ssh/authorized_keys`
- packages installed:
  - `cloud-init`
  - `openssh-server`
  - `qemu-guest-agent`
- `virt-sysprep` cleans machine identity before publishing

## Files

- `build-image-ext4.sh` builds the ext4 image locally or on CI
- `build-image-btrfs.sh` builds the btrfs image locally
- `files/99-root-login.cfg` is the cloud-init override
- `files/resolv.conf` is copied into `/etc/resolv.conf` and locked immutable in each image
- `scripts/` is copied into `/root/scripts` inside each image

## Local build

Install dependencies on your Linux builder:

```bash
sudo apt-get update
sudo apt-get install -y libguestfs-tools qemu-utils xz-utils debootstrap parted btrfs-progs
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

Both builders assume a BIOS/QEMU boot path with `grub-pc`.

Both builders also copy the repository `scripts/` directory into `/root/scripts` inside the image.
If `/root/scripts/install-bundle.sh` exists, both builders register it in root's crontab with `@reboot`; it waits 5 minutes, runs once, and removes its own crontab entry when finished.
Both builders also copy `files/resolv.conf` into `/etc/resolv.conf` and mark it immutable.

## Notes

- The output image is `raw`, compressed with `xz`, in order to works with [reinstall script](https://github.com/bin456789/reinstall/tree/main)
- `root` login is key-only by default; no root password is set
