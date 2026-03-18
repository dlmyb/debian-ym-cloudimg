#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_MARK_BEGIN='### BEGIN simple.sh ###'
SCRIPT_MARK_END='### END simple.sh ###'
BOOT_ENTRY_TITLE='simple-alpine-dd'

usage() {
    cat <<'EOF'
Usage:
  sudo bash simple.sh --img HTTP_URL [--alpine-version 3.23] [--flavour virt|lts] [--no-reboot] [--yes]

What it does:
  1. Detects the current system disk
  2. Downloads Alpine netboot kernel/initramfs
  3. Injects a small second-stage installer into the Alpine initramfs
  4. Adds a one-time GRUB boot entry
  5. Reboots into Alpine-in-RAM
  6. Alpine re-detects the same disk by disk ID and dd's the image automatically

Notes:
  - Linux only
  - GRUB only
  - The image must be reachable by HTTP or HTTPS after reboot
  - Supported image formats: .img, .raw, .gz, .xz, .zst
EOF
}

info() {
    echo "[simple.sh] $*" >&2
}

die() {
    echo "[simple.sh] Error: $*" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

map_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo x86_64 ;;
        aarch64|arm64) echo aarch64 ;;
        *) die "unsupported architecture: $(uname -m)" ;;
    esac
}

default_console_args() {
    case "${1:-$(map_arch)}" in
        x86_64) echo 'console=ttyS0,115200n8 console=tty0' ;;
        aarch64) echo 'console=ttyS0,115200n8 console=ttyAMA0,115200n8 console=tty0' ;;
    esac
}

download_file() {
    local url=$1
    local dest=$2

    if command -v curl >/dev/null 2>&1; then
        curl -fL "$url" -o "$dest"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$dest" "$url"
    else
        die "missing required command: curl or wget"
    fi
}

detect_root_disk() {
    local root_source disks

    root_source=$(findmnt -n -o SOURCE / 2>/dev/null || true)
    [ -n "$root_source" ] || die "failed to detect root source"

    disks=$(lsblk -rn --inverse -o NAME,TYPE "$root_source" 2>/dev/null | awk '$2=="disk"{print $1}' | sort -u)
    [ -n "$disks" ] || die "failed to detect root disk from $root_source"

    if [ "$(printf '%s\n' "$disks" | wc -l | tr -d ' ')" -ne 1 ]; then
        printf '%s\n' "$disks" >&2
        die "root spans multiple disks; this simplified script only supports one system disk"
    fi

    printf '/dev/%s\n' "$disks"
}

get_disk_id() {
    local disk=$1
    local disk_id=""

    if command -v sfdisk >/dev/null 2>&1; then
        disk_id=$(sfdisk --disk-id "$disk" 2>/dev/null | sed 's/^0x//' | tr '[:upper:]' '[:lower:]' || true)
    fi

    if [ -z "$disk_id" ] && command -v blkid >/dev/null 2>&1; then
        disk_id=$(blkid -s PTUUID -o value "$disk" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)
    fi

    if [ -z "$disk_id" ] && command -v fdisk >/dev/null 2>&1; then
        disk_id=$(fdisk -l "$disk" 2>/dev/null | awk '/Disk identifier/{print tolower($NF)}' | sed 's/^0x//' | head -n1 || true)
    fi

    if ! printf '%s\n' "$disk_id" | grep -Eix '[0-9a-f]{8}|[0-9a-f-]{36}' >/dev/null; then
        die "failed to read a valid disk identifier for $disk"
    fi

    printf '%s\n' "$disk_id"
}

detect_grub_cfg() {
    local cfg

    for cfg in /boot/grub/grub.cfg /boot/grub2/grub.cfg; do
        if [ -f "$cfg" ]; then
            printf '%s\n' "$cfg"
            return
        fi
    done

    die "could not find GRUB config"
}

detect_grub_tools() {
    if command -v grub-reboot >/dev/null 2>&1; then
        GRUB_REBOOT_CMD=grub-reboot
    elif command -v grub2-reboot >/dev/null 2>&1; then
        GRUB_REBOOT_CMD=grub2-reboot
    else
        die "missing required command: grub-reboot or grub2-reboot"
    fi

    if command -v grub-editenv >/dev/null 2>&1; then
        GRUB_EDITENV_CMD=grub-editenv
    elif command -v grub2-editenv >/dev/null 2>&1; then
        GRUB_EDITENV_CMD=grub2-editenv
    else
        die "missing required command: grub-editenv or grub2-editenv"
    fi
}

grub_path_for_file() {
    local file=$1
    local mountpoint path

    mountpoint=$(findmnt -n -o TARGET -T "$file" 2>/dev/null || true)
    [ -n "$mountpoint" ] || die "failed to determine mountpoint for $file"

    path=${file#"$mountpoint"}
    if [ -z "$path" ]; then
        path="/$(basename "$file")"
    fi
    case "$path" in
        /*) ;;
        *) path="/$path" ;;
    esac

    printf '%s\n' "$path"
}

write_stage2_script() {
    local dest=$1

    cat >"$dest" <<'EOF'
#!/bin/ash

set -eu

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

log() {
    echo "[simple.sh stage2] $*" >&2
}

die() {
    echo "[simple.sh stage2] ERROR: $*" >&2
    echo "[simple.sh stage2] Dropping to shell." >&2
    exec /bin/ash
}

retry() {
    tries=$1
    shift

    n=1
    while ! "$@"; do
        rc=$?
        if [ "$n" -ge "$tries" ]; then
            return "$rc"
        fi
        n=$((n + 1))
        sleep 2
    done
}

apk_add() {
    retry 5 apk add --no-cache "$@" >/dev/null
}

read_config() {
    cat "/configs/$1"
}

get_all_disks() {
    ls /sys/block | grep -Ev '^(loop|sr|nbd|ram)'
}

find_target_disk() {
    main_disk=$(read_config main_disk | tr '[:upper:]' '[:lower:]')

    apk_add util-linux

    for disk in $(get_all_disks); do
        disk_id=$(sfdisk --disk-id "/dev/$disk" 2>/dev/null | sed 's/^0x//' | tr '[:upper:]' '[:lower:]' || true)
        if [ -n "$disk_id" ] && [ "$disk_id" = "$main_disk" ]; then
            echo "/dev/$disk"
            return
        fi

        part_uuid=$(lsblk --nodeps -rno PTUUID "/dev/$disk" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)
        if [ -n "$part_uuid" ] && [ "$part_uuid" = "$main_disk" ]; then
            echo "/dev/$disk"
            return
        fi
    done

    die "could not locate target disk with id $main_disk"
}

sync_time() {
    ntpd -d -q -n -p pool.ntp.org >/dev/null 2>&1 || true
}

stream_image() {
    img_url=$1

    case "$img_url" in
        *.img|*.raw) wget -O- "$img_url" ;;
        *.gz) apk_add gzip; wget -O- "$img_url" | gzip -dc ;;
        *.xz) apk_add xz; wget -O- "$img_url" | xz -dc ;;
        *.zst) apk_add zstd; wget -O- "$img_url" | zstd -dc ;;
        *) die "unsupported image format: $img_url" ;;
    esac
}

main() {
    img_url=$(read_config img_url)
    target_disk=$(find_target_disk)

    mount / -o remount,size=100% >/dev/null 2>&1 || true
    sync_time

    apk_add ca-certificates wget
    update-ca-certificates >/dev/null 2>&1 || true

    log "image: $img_url"
    log "target disk: $target_disk"
    log "writing image"

    stream_image "$img_url" >"$target_disk"
    sync

    log "write complete, rebooting"
    reboot -f
}

main "$@"
EOF

    chmod +x "$dest"
}

patch_init_for_local_stage2() {
    local init_file=$1
    local tmp_file

    tmp_file=$(mktemp)
    awk '
        /^exec switch_root/ && !done {
            print "mkdir -p \"$sysroot/etc/local.d\" \"$sysroot/etc/runlevels/default\""
            print "cp /simple-trans.sh \"$sysroot/etc/local.d/simple.start\""
            print "chmod a+x \"$sysroot/etc/local.d/simple.start\""
            print "ln -sf /etc/init.d/local \"$sysroot/etc/runlevels/default/local\""
            print "if [ -d /configs ]; then cp -r /configs \"$sysroot/\"; fi"
            done=1
        }
        { print }
        END {
            if (!done) {
                exit 1
            }
        }
    ' "$init_file" >"$tmp_file" || {
        rm -f "$tmp_file"
        die "failed to patch Alpine initrd init script"
    }

    mv "$tmp_file" "$init_file"
}

prepare_initrd() {
    local src_initrd=$1
    local dest_initrd=$2
    local workdir=$3
    local initrd_root=$workdir/initrd

    mkdir -p "$initrd_root" "$initrd_root/configs"

    gzip -dc "$src_initrd" | (cd "$initrd_root" && cpio -idmu --quiet)

    write_stage2_script "$initrd_root/simple-trans.sh"
    printf '%s\n' "$MAIN_DISK_ID" >"$initrd_root/configs/main_disk"
    printf '%s\n' "$IMG_URL" >"$initrd_root/configs/img_url"

    patch_init_for_local_stage2 "$initrd_root/init"

    (
        cd "$initrd_root"
        find . -print | cpio -o -H newc --quiet | gzip -1 >"$dest_initrd"
    )
}

write_boot_entry() {
    local grub_cfg=$1
    local vmlinuz_grub_path=$2
    local initrd_grub_path=$3
    local cmdline=$4
    local target_cfg grub_dir grubenv

    if grep -q 'custom.cfg' "$grub_cfg"; then
        target_cfg="$(dirname "$grub_cfg")/custom.cfg"
        touch "$target_cfg"
    else
        target_cfg="$grub_cfg"
    fi

    if [ -f "$target_cfg" ]; then
        sed -i "\|^${SCRIPT_MARK_BEGIN}$|,\|^${SCRIPT_MARK_END}$|d" "$target_cfg"
    fi

    cat >>"$target_cfg" <<EOF
${SCRIPT_MARK_BEGIN}
menuentry "${BOOT_ENTRY_TITLE}" --unrestricted {
    insmod all_video
    search --no-floppy --file --set=root ${vmlinuz_grub_path}
    linux ${vmlinuz_grub_path} ${cmdline}
    initrd ${initrd_grub_path}
}
${SCRIPT_MARK_END}
EOF

    grub_dir=$(dirname "$grub_cfg")
    grubenv="$grub_dir/grubenv"
    if [ ! -f "$grubenv" ]; then
        "$GRUB_EDITENV_CMD" "$grubenv" create
    fi

    "$GRUB_REBOOT_CMD" "$BOOT_ENTRY_TITLE"
}

confirm() {
    echo >&2
    echo "Image URL:   $IMG_URL" >&2
    echo "Target disk: $TARGET_DISK" >&2
    echo "Disk ID:     $MAIN_DISK_ID" >&2
    echo >&2
    echo "WARNING: the whole disk will be overwritten after reboot." >&2
    read -r -p "Type YES to continue: " reply
    [ "$reply" = "YES" ] || die "aborted"
}

main() {
    local alpine_version=3.23
    local flavour=virt
    local do_reboot=1
    local assume_yes=0
    local arch grub_cfg workdir mirror kernel_url initrd_url modloop_url repo_url
    local downloaded_vmlinuz downloaded_initrd patched_initrd boot_vmlinuz boot_initrd
    local vmlinuz_grub_path initrd_grub_path cmdline

    while [ $# -gt 0 ]; do
        case "$1" in
            --img)
                IMG_URL=${2:-}
                shift 2
                ;;
            --alpine-version)
                alpine_version=${2:-}
                shift 2
                ;;
            --flavour)
                flavour=${2:-}
                shift 2
                ;;
            --no-reboot)
                do_reboot=0
                shift
                ;;
            --yes)
                assume_yes=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "unexpected argument: $1"
                ;;
        esac
    done

    [ "$(uname -s)" = "Linux" ] || die "this script only supports Linux"
    [ "$(id -u)" -eq 0 ] || die "run as root"
    [ -n "${IMG_URL:-}" ] || die "--img is required"
    printf '%s\n' "$IMG_URL" | grep -Eq '^https?://' || die "--img must be an HTTP(S) URL"

    case "$IMG_URL" in
        *.img|*.raw|*.gz|*.xz|*.zst) ;;
        *) die "unsupported image format in --img" ;;
    esac

    case "$flavour" in
        virt|lts) ;;
        *) die "--flavour must be virt or lts" ;;
    esac

    need_cmd findmnt
    need_cmd lsblk
    need_cmd gzip
    need_cmd cpio
    detect_grub_tools

    TARGET_DISK=$(detect_root_disk)
    MAIN_DISK_ID=$(get_disk_id "$TARGET_DISK")
    grub_cfg=$(detect_grub_cfg)
    arch=$(map_arch)

    mirror="http://dl-cdn.alpinelinux.org/alpine/v${alpine_version}"
    kernel_url="${mirror}/releases/${arch}/netboot/vmlinuz-${flavour}"
    initrd_url="${mirror}/releases/${arch}/netboot/initramfs-${flavour}"
    modloop_url="${mirror}/releases/${arch}/netboot/modloop-${flavour}"
    repo_url="${mirror}/main"

    if [ "$assume_yes" -ne 1 ]; then
        confirm
    fi

    workdir=$(mktemp -d)
    trap 'rm -rf "$workdir"' EXIT

    downloaded_vmlinuz="$workdir/vmlinuz"
    downloaded_initrd="$workdir/initrd.gz"
    patched_initrd="$workdir/initrd.patched.gz"

    info "detected target disk: $TARGET_DISK"
    info "disk identifier: $MAIN_DISK_ID"
    info "downloading Alpine netboot assets"

    download_file "$kernel_url" "$downloaded_vmlinuz"
    download_file "$initrd_url" "$downloaded_initrd"

    info "injecting second-stage installer into initrd"
    prepare_initrd "$downloaded_initrd" "$patched_initrd" "$workdir"

    boot_vmlinuz=/boot/simple-alpine-vmlinuz
    boot_initrd=/boot/simple-alpine-initrd
    cp -f "$downloaded_vmlinuz" "$boot_vmlinuz"
    cp -f "$patched_initrd" "$boot_initrd"

    vmlinuz_grub_path=$(grub_path_for_file "$boot_vmlinuz")
    initrd_grub_path=$(grub_path_for_file "$boot_initrd")
    cmdline="ip=dhcp alpine_repo=${repo_url} modloop=${modloop_url} $(default_console_args "$arch")"

    info "writing GRUB entry"
    write_boot_entry "$grub_cfg" "$vmlinuz_grub_path" "$initrd_grub_path" "$cmdline"

    info "prepared one-time Alpine RAM boot"
    if [ "$do_reboot" -eq 1 ]; then
        info "rebooting now"
        sync
        reboot
    else
        info "setup complete; reboot when ready"
    fi
}

main "$@"
