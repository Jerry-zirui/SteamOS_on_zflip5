#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Jerry-zirui (https://github.com/Jerry-zirui/SteamOS_on_zflip5)
#
# Pack recovery_b5q_steamos.img and optionally flash ONLY /dev/sda23 (recovery)
# with strict size check + exact byte-count SHA256 readback verification.
# Usage: pack_and_flash_recovery.sh [--pack-only | --flash]
set -euo pipefail

OUT=/root/work/steamos_out
KERNEL="$OUT/Image_steamos"
RAMDISK="$OUT/initramfs_steamos.cpio.gz"
DTB="$OUT/sm8550-samsung-b5q_steamos.dtb"
IMG="$OUT/recovery_b5q_steamos.img"
MKBOOT=/root/work/mkbootimg_v2.py
PART=/dev/sda23

CMDLINE="console=tty0 fbcon=font:TER16x32 clk_ignore_unused pd_ignore_unused pcie_aspm=off initcall_blacklist=msg_init,of_platform_sync_state_init,icc_sync_state,regulator_init_complete"

DO_FLASH=0
[ "${1:-}" = "--flash" ] && DO_FLASH=1

[ -f "$KERNEL" ] || { echo "Missing $KERNEL" >&2; exit 1; }
[ -f "$RAMDISK" ] || { echo "Missing $RAMDISK" >&2; exit 1; }
[ -f "$DTB" ] || { echo "Missing $DTB" >&2; exit 1; }

python3 "$MKBOOT" \
    --kernel "$KERNEL" \
    --ramdisk "$RAMDISK" \
    --dtb "$DTB" \
    --cmdline "$CMDLINE" \
    --output "$IMG"

IMG_SZ=$(stat -c %s "$IMG")
PART_SZ=$(blockdev --getsize64 "$PART")
IMG_SHA=$(sha256sum "$IMG" | awk '{print $1}')

echo "Packed: $IMG ($IMG_SZ bytes, SHA256=$IMG_SHA)"
echo "Partition $PART capacity: $PART_SZ bytes"
[ "$IMG_SZ" -le "$PART_SZ" ] || { echo "ERROR: image exceeds $PART size!" >&2; exit 1; }

if [ "$DO_FLASH" -eq 1 ]; then
    [ -f /steamos/root.img ] || { echo "ERROR: refusing to flash without /steamos/root.img!" >&2; exit 1; }
    echo "Flashing $IMG -> $PART..."
    dd if="$IMG" of="$PART" bs=4M conv=fsync
    sync
    READ_SHA=$(dd if="$PART" bs=4096 count=$((IMG_SZ / 4096)) iflag=fullblock status=none | sha256sum | awk '{print $1}')
    # Handle any trailing bytes if not exact 4K multiple (mkbootimg_v2 pads to 4096 bytes)
    if [ $((IMG_SZ % 4096)) -ne 0 ]; then
        READ_SHA=$(head -c "$IMG_SZ" "$PART" | sha256sum | awk '{print $1}')
    fi
    echo "Readback SHA256: $READ_SHA"
    [ "$READ_SHA" = "$IMG_SHA" ] || { echo "ERROR: SHA256 verification FAILED!" >&2; exit 1; }
    echo "=== Verified /dev/sda23 flash OK ==="
fi
