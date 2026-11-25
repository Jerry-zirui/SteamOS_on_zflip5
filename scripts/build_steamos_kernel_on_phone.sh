#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Jerry-zirui (https://github.com/Jerry-zirui/SteamOS_on_zflip5)
#
# Build incremental SteamOS ARM64 kernel (7.3.5-b5q-steamos) on SM-F7310.
# Starts from frozen v1.0.0 baseline kernel_7.3.5-b5q-p4.config using an isolated
# O=/root/work/linux/.output_steamos directory so .output_p4 & /lib/modules/7.3.5-b5q-p4
# remain completely untouched.
set -eu

L=/root/work/linux
O=/root/work/linux/.output_steamos
OUT=/root/work/steamos_out
BASE_CFG=/root/work/kernel_7.3.5-b5q-p4.config

mkdir -p "$O" "$OUT"

if [ ! -f "$BASE_CFG" ]; then
    echo "ERROR: missing baseline config $BASE_CFG" >&2
    exit 1
fi

echo "=== [1/4] Syncing baseline DTS & panel driver (idempotent) ==="
if [ -f /root/work/sm8550-samsung-b5q.dts ]; then
    cp -f /root/work/sm8550-samsung-b5q.dts "$L/arch/arm64/boot/dts/qcom/sm8550-samsung-b5q.dts"
fi
if [ -f /root/work/panel-samsung-s6e3fac-b5q.c ]; then
    cp -f /root/work/panel-samsung-s6e3fac-b5q.c "$L/drivers/gpu/drm/panel/panel-samsung-s6e3fac-b5q.c"
fi

echo "=== [2/4] Configuring 7.3.5-b5q-steamos (SteamOS / FEX / Proton / Gamepad / ZRAM / FS) ==="
cp "$BASE_CFG" "$O/.config"
cd "$L"
SC="$L/scripts/config --file $O/.config"

$SC --set-str LOCALVERSION "-b5q-steamos"

# FEX-Emu & Proton performance
$SC --enable BINFMT_MISC
$SC --enable NTSYNC

# Gamepads (Flydigi Wee Bluetooth HID + Xbox / PlayStation / Switch / Steam)
$SC --enable HIDRAW
$SC --enable INPUT_JOYDEV
$SC --enable INPUT_JOYSTICK
$SC --enable HID_GENERIC
$SC --enable UHID
$SC --module HID_PLAYSTATION
$SC --module HID_NINTENDO
$SC --module HID_MICROSOFT
$SC --module HID_STEAM
$SC --module JOYSTICK_XPAD

# Memory pressure protection for 8 GiB RAM (ZRAM zstd + PSI for systemd-oomd)
$SC --enable ZRAM
$SC --enable ZRAM_BACKEND_ZSTD
$SC --enable PSI

# SteamOS / container / loop filesystems
$SC --enable BTRFS_FS
$SC --enable EROFS_FS
$SC --enable SQUASHFS_ZSTD
$SC --module DM_VERITY
$SC --enable OVERLAY_FS
$SC --enable BLK_DEV_LOOP

# SteamOS Manager ftrace/tracefs (/sys/kernel/tracing/instances/steamos-log-submitter)
$SC --enable FTRACE
$SC --enable ENABLE_DEFAULT_TRACERS

$SC --disable WERROR

make O="$O" olddefconfig

echo "=== [2b] Verifying critical SteamOS kernel options ==="
for sym in \
    CONFIG_ARM64_4K_PAGES \
    CONFIG_BINFMT_MISC \
    CONFIG_NTSYNC \
    CONFIG_HIDRAW \
    CONFIG_INPUT_JOYDEV \
    CONFIG_UHID \
    CONFIG_ZRAM \
    CONFIG_ZRAM_BACKEND_ZSTD \
    CONFIG_PSI \
    CONFIG_BTRFS_FS \
    CONFIG_EROFS_FS \
    CONFIG_SQUASHFS_ZSTD \
    CONFIG_OVERLAY_FS \
    CONFIG_BLK_DEV_LOOP \
    CONFIG_FTRACE \
    CONFIG_TRACING
do
    if ! grep -q "^${sym}=y$" "$O/.config"; then
        echo "ERROR: ${sym} is NOT =y after olddefconfig!" >&2
        grep -E "^(# )?${sym}[= ]" "$O/.config" || true
        exit 1
    fi
done
grep -E "^CONFIG_(LOCALVERSION|BINFMT_MISC|NTSYNC|HIDRAW|INPUT_JOYDEV|HID_PLAYSTATION|HID_NINTENDO|HID_MICROSOFT|HID_STEAM|JOYSTICK_XPAD|ZRAM|ZRAM_BACKEND_ZSTD|PSI|BTRFS_FS|EROFS_FS|SQUASHFS_ZSTD|DM_VERITY|OVERLAY_FS|BLK_DEV_LOOP|FTRACE|TRACING)=" "$O/.config"

echo "=== [3/4] Building Image, Modules & DTB on 8 cores ==="
make -j8 O="$O" Image modules
make -j8 O="$O" DTC_FLAGS="-@" qcom/sm8550-samsung-b5q.dtb

echo "=== [4/4] Installing modules to /lib/modules/7.3.5-b5q-steamos & exporting artifacts ==="
make O="$O" INSTALL_MOD_STRIP=1 modules_install
cp -f "$O/arch/arm64/boot/Image" "$OUT/Image_steamos"
cp -f "$O/arch/arm64/boot/dts/qcom/sm8550-samsung-b5q.dtb" "$OUT/sm8550-samsung-b5q_steamos.dtb"
cp -f "$O/.config" "$OUT/kernel_7.3.5-b5q-steamos.config"
ls -lh "$OUT/Image_steamos" "$OUT/sm8550-samsung-b5q_steamos.dtb" "$OUT/kernel_7.3.5-b5q-steamos.config"
ls -d /lib/modules/7.3.5-b5q-steamos
echo "=== STEAMOS KERNEL BUILD COMPLETE ==="
