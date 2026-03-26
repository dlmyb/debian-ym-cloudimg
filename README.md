# Debian Cloud Image Builder

This repo builds customized Debian 13 amd64 cloud images from a fresh bootstrap install, then provisions them offline through a chroot stage.

## Base image contents

- Debian builders stage `stage/ssh/authorized_keys` as `/root/ssh/authorized_keys`, then the first-boot bundle script restores it to `/root/.ssh/authorized_keys`
- packages installed:
  - `cloud-init`
  - `openssh-server`
  - `qemu-guest-agent`
- all builders use `virt-sysprep` to clean machine-specific state before publishing

## Repository layout

- `stage/` contains the payload copied into the qcow2 image before first boot:
  - `stage/ssh/authorized_keys` becomes `/root/ssh/authorized_keys`
  - `stage/files/resolv.conf` becomes `/etc/resolv.conf`
  - `stage/files/interfaces` becomes `/etc/network/interfaces`
  - `stage/files/sources.list` becomes `/etc/apt/sources.list` when present
  - `stage/scripts/debian/` becomes `/root/scripts/`
- `scripts/image/build-image-ext4.sh` builds the ext4 qcow2 image
- `scripts/image/build-image-btrfs.sh` builds the btrfs qcow2 image
- `scripts/image/copy-config-to-qcow2.sh` restages `stage/` content into an existing qcow2 image
- `scripts/image/export-qcow2-to-raw-xz.sh` converts an existing qcow2 image to `raw.xz`
- `scripts/image/stage-qcow2-image.sh` combines restaging and export in one command
- `reinstall/` is a git submodule for the upstream reinstall project used with the generated raw images

## Local build

Install dependencies on your Linux builder:

```bash
sudo apt-get update
sudo apt-get install -y curl e2fsprogs libguestfs-tools qemu-utils xz-utils debootstrap parted btrfs-progs
```

Add your Debian SSH authorized key:

```bash
mkdir -p stage/ssh
cat > stage/ssh/authorized_keys <<'EOF'
ssh-ed25519 AAAA... your-key-comment
EOF
```

Run the build:

```bash
make ext4
```

The builder writes a qcow2 image into `out/`. Use `make xz TARGET_IMG=...` if you also want a `raw.xz` export.

## Ext4 build

The `scripts/image/build-image-ext4.sh` script creates a fresh disk image, provisions Debian with `debootstrap`, customizes it in a chroot, and writes `debian-13-ext4-amd64.qcow2` into `out/`.

Current layout:

- `/boot` on `ext4`
- `/` on `ext4`

Run it with:

```bash
make ext4
```

## Btrfs build

The `scripts/image/build-image-btrfs.sh` script creates a fresh disk image, formats the root filesystem as `btrfs`, creates subvolumes, bootstraps Debian with `debootstrap`, customizes it in a chroot, and writes `debian-13-btrfs-amd64.qcow2` into `out/`.

Current layout:

- `/boot` on `ext4`
- `/` on `btrfs` subvolume `@`
- `/var/log` on `btrfs` subvolume `@var_log`
- `/.snapshots` on `btrfs` subvolume `@snapshots`

Run it with:

```bash
make btrfs
```

## Make targets

Use the Makefile as the uniform entry point:

```bash
make ext4
make btrfs
make copy TARGET_IMG=out/debian-13-ext4-amd64.qcow2
make xz TARGET_IMG=out/debian-13-ext4-amd64.qcow2
```

`make copy` updates an existing qcow2 in place with the staged config files.
`make xz` converts an existing qcow2 into `raw.xz` in `out/` by default.
You can also use `target_img=...` instead of `TARGET_IMG=...`, and `OUTPUT_IMG=...` or `output_img=...` to override the `make xz` output path.

## Stage workflow

Update the files under `stage/` when you want to change what gets copied into the image:

```bash
stage/ssh/authorized_keys
stage/files/resolv.conf
stage/files/interfaces
stage/files/sources.list
stage/scripts/debian/
```

If you already have a qcow2 image and only want to refresh the staged files without rebuilding it from scratch:

```bash
make copy TARGET_IMG=out/debian-13-ext4-amd64.qcow2
```

If you then need a `raw.xz` artifact:

```bash
make xz TARGET_IMG=out/debian-13-ext4-amd64.qcow2
```

All builders assume a BIOS/QEMU boot path.
The Debian builders use `grub-pc`.
The Debian builders use `ifupdown` with `stage/files/interfaces` as the active network config.

The Debian builders copy `stage/scripts/debian/` into `/root/scripts` inside the image, and copy `stage/ssh/` into `/root/ssh`.
If `/root/scripts/install-bundle.sh` exists, each builder registers it in root's crontab with `@reboot`; it waits 60 seconds on Debian, runs once, and removes its own crontab entry when finished.
All builders copy `stage/files/resolv.conf` into `/etc/resolv.conf`.
The Debian builders mark it immutable.
The btrfs Debian image also installs `btrbk`, writes `/etc/btrbk/btrbk.conf`, and runs it from `/etc/cron.hourly/btrbk` to snapshot `/` into `/.snapshots/btrbk` with retention `24h 7d 0w 0m 0y`.
The repository also vendors the upstream `reinstall` project as a submodule in `reinstall/` for reference and integration with the produced raw images.

## Notes

- The builders now output `qcow2`; use `make xz TARGET_IMG=...` when you need a `raw.xz` image for the [reinstall script](https://github.com/bin456789/reinstall.git) submodule workflow
- `root` login is key-only by default; no root password is set
