#!/usr/bin/env bash
# make-win-usb.sh - build a UEFI-bootable Windows installation USB on Linux with wimlib.
#
# Layout produced: GPT (or MBR with --mbr), one FAT32 partition holding the ISO contents,
# with sources/install.wim split into <4 GB install.swm parts (FAT32 file-size limit).
# Windows Setup reads split .swm images natively, so nothing else is needed.
#
# Usage:
#   make-win-usb.sh --list                       show removable USB disks
#   make-win-usb.sh /dev/sdX path/to/win.iso     dry run: show what would happen
#   make-win-usb.sh /dev/sdX path/to/win.iso --yes   really wipe the disk and build
# Options:
#   --mbr          use an MBR partition table instead of GPT (for picky old firmware)
#   --label NAME   FAT32 volume label (default WINUSB, max 11 chars)
#   --split MB     size of each .swm part in MB (default 3800)
#   --keep-tmp     keep the temporary install.wim made from an install.esd
set -euo pipefail

DEV=""; ISO=""; YES=0; TABLE=gpt; LABEL=WINUSB; SPLIT=3800; KEEP_TMP=0; LIST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) YES=1 ;;
    --mbr) TABLE=dos ;;
    --list) LIST=1 ;;
    --label) LABEL="$2"; shift ;;
    --split) SPLIT="$2"; shift ;;
    --keep-tmp) KEEP_TMP=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    /dev/*) DEV="$1" ;;
    *) ISO="$1" ;;
  esac; shift
done

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

if [ "$LIST" = 1 ]; then
  found=0
  while IFS= read -r line; do
    eval "$line"   # lsblk -P emits KEY="value" pairs
    [ "$TRAN" = usb ] || continue
    printf '%-12s %8s  %s %s\n' "$PATH_" "$SIZE" "$VENDOR" "$MODEL"; found=1
  done < <(lsblk -dPo PATH,SIZE,TRAN,VENDOR,MODEL | sed 's/^PATH=/PATH_=/')
  [ "$found" = 1 ] || echo "no USB disks attached"
  exit 0
fi

# --- sanity checks ------------------------------------------------------------
for t in wimlib-imagex sfdisk mkfs.fat rsync partprobe udevadm wipefs lsblk blockdev; do
  command -v "$t" >/dev/null || die "missing tool: $t (install wimlib-utils/wimtools, dosfstools, rsync, util-linux)"
done
[ "$(id -u)" = 0 ] || die "run as root: sudo $0 ..."
[ -n "$DEV" ] || die "no target disk given (try --list)"
[ -b "$DEV" ] || die "$DEV is not a block device"
case "$DEV" in *[0-9]) die "give the whole disk (e.g. /dev/sdc), not a partition";; esac
[ "$(lsblk -dno TRAN "$DEV")" = usb ] || die "$DEV is not attached via USB, refusing"
[ -n "$ISO" ] && [ -f "$ISO" ] || die "ISO not found: '$ISO'"
[ ${#LABEL} -le 11 ] || die "label must be 11 characters or fewer"
ISO="$(readlink -f "$ISO")"

DISK_BYTES=$(blockdev --getsize64 "$DEV"); ISO_BYTES=$(stat -c %s "$ISO")
[ "$DISK_BYTES" -gt $((ISO_BYTES + ISO_BYTES / 10 + 268435456)) ] \
  || die "disk too small: $((DISK_BYTES/1048576)) MB for a $((ISO_BYTES/1048576)) MB ISO"

# partition device name: /dev/sdc -> /dev/sdc1, /dev/nvme0n1 or /dev/mmcblk0 -> ...p1
case "$DEV" in *[0-9]) PART="${DEV}p1";; *) PART="${DEV}1";; esac

echo "Target disk (ALL DATA WILL BE ERASED):"
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT,VENDOR,MODEL "$DEV"
echo "ISO:        $ISO ($((ISO_BYTES/1048576)) MB)"
echo "Table:      $TABLE, one FAT32 partition, label $LABEL, .swm parts of $SPLIT MB"
if [ "$YES" != 1 ]; then echo; echo "Dry run. Add --yes to proceed."; exit 0; fi

# --- mounts and cleanup --------------------------------------------------------
USB=$(mktemp -d /mnt/winusb.XXXX); SRC=$(mktemp -d /mnt/winiso.XXXX); TMPWIM=""
cleanup() {
  umount "$USB" 2>/dev/null || true; umount "$SRC" 2>/dev/null || true
  rmdir "$USB" "$SRC" 2>/dev/null || true
  [ -n "$TMPWIM" ] && [ "$KEEP_TMP" = 0 ] && rm -f "$TMPWIM" || true
}
trap cleanup EXIT

log "unmounting anything on $DEV"
for p in $(lsblk -lno PATH "$DEV" | tail -n +2); do umount -l "$p" 2>/dev/null || true; done
mount -o loop,ro "$ISO" "$SRC" || die "cannot mount ISO (is it really a Windows ISO?)"
[ -f "$SRC/sources/boot.wim" ] || die "sources/boot.wim not found: not a Windows install ISO"
[ -f "$SRC/efi/boot/bootx64.efi" ] || [ -f "$SRC/efi/boot/bootaa64.efi" ] \
  || echo "warning: no efi/boot/boot*.efi in ISO, UEFI boot may not work"

INSTALL=""
for f in install.wim install.esd; do [ -f "$SRC/sources/$f" ] && INSTALL="$SRC/sources/$f" && break; done
[ -n "$INSTALL" ] || die "sources/install.wim or install.esd not found in ISO"

# --- partition and format ------------------------------------------------------
log "wiping and partitioning $DEV ($TABLE)"
wipefs -a "$DEV" >/dev/null
if [ "$TABLE" = gpt ]; then
  printf 'label: gpt\n,,EBD0A0A2-B9E5-4433-87C0-68B6B72699C7,\n' | sfdisk -q "$DEV"
else
  printf 'label: dos\n,,0c,*\n' | sfdisk -q "$DEV"
fi
partprobe "$DEV"; udevadm settle; sleep 2
[ -b "$PART" ] || die "partition $PART did not appear"
log "formatting $PART as FAT32"
mkfs.fat -F32 -n "$LABEL" "$PART" >/dev/null
mount "$PART" "$USB"

# --- copy -----------------------------------------------------------------------
log "copying ISO contents (except $(basename "$INSTALL"))"
rsync -rt --no-perms --no-owner --no-group --info=progress2 \
      --exclude=sources/install.wim --exclude=sources/install.esd "$SRC"/ "$USB"/

INSTALL_BYTES=$(stat -c %s "$INSTALL")
if [ "$INSTALL_BYTES" -lt 4294967295 ]; then
  log "$(basename "$INSTALL") is under 4 GB, copying as-is"
  cp "$INSTALL" "$USB/sources/"
else
  if [[ "$INSTALL" == *.esd ]]; then
    # ESD (solid LZMS) images cannot be split directly; export to a normal WIM first.
    TMPWIM=$(mktemp "${TMPDIR:-/var/tmp}/install.XXXX.wim")
    log "converting install.esd to a temporary install.wim (slow, needs $((INSTALL_BYTES/1048576)) MB free in ${TMPDIR:-/var/tmp})"
    wimlib-imagex export "$INSTALL" all "$TMPWIM" --compress=LZX
    INSTALL="$TMPWIM"
  fi
  log "splitting $(basename "$INSTALL") into $SPLIT MB parts"
  wimlib-imagex split "$INSTALL" "$USB/sources/install.swm" "$SPLIT"
fi

log "flushing writes to the stick (this can take several minutes)"
sync; umount "$USB"
log "verifying"
mount -o ro "$PART" "$USB"
[ -f "$USB/sources/boot.wim" ] && ls "$USB"/sources/install.* >/dev/null || die "verification failed"
umount "$USB"
eject "$DEV" 2>/dev/null || true
log "done. $DEV is a UEFI-bootable Windows installer and can be unplugged."
