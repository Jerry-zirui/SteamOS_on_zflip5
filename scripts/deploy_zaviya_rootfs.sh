#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Jerry-zirui (https://github.com/Jerry-zirui/SteamOS_on_zflip5)
#
# Decompress Zaviya SM8550 v1.5.0 image, verify checksum, extract p2 (root) + p3 (home)
# into a 32 GiB sparse ext4 loop image at /steamos/root.img, and run apply_b5q_overlay.sh.
# Usage: deploy_zaviya_rootfs.sh [--inspect-only]
set -euo pipefail

WORK="/steamos_work"
ZST="${WORK}/zaviya-sm8550-1.5.0.img.zst"
RAW="${WORK}/zaviya-sm8550-1.5.0.img"
EXPECTED_SHA256="4a57feb6ebf76f83b4943549f3073765315812719ba4803f01ee0cf64b9515fc"
MNT_P2="${WORK}/mnt_p2"
MNT_P3="${WORK}/mnt_p3"
MNT_ROOTFS="${WORK}/rootfs"
ROOT_IMG="/steamos/root.img"
IMG_SIZE="32G"

INSPECT_ONLY=0
[ "${1:-}" = "--inspect-only" ] && INSPECT_ONLY=1

LOOP_P2=""
LOOP_P3=""
LOOP_ROOT=""

log() { printf '==> [deploy-steamos] %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

cleanup() {
    sync || true
    umount "$MNT_ROOTFS" 2>/dev/null || true
    umount "$MNT_P3" 2>/dev/null || true
    umount "$MNT_P2" 2>/dev/null || true
    [ -n "$LOOP_ROOT" ] && losetup -d "$LOOP_ROOT" 2>/dev/null || true
    [ -n "$LOOP_P3" ] && losetup -d "$LOOP_P3" 2>/dev/null || true
    [ -n "$LOOP_P2" ] && losetup -d "$LOOP_P2" 2>/dev/null || true
}
trap cleanup EXIT

[ -f "$ZST" ] || die "Missing $ZST"

if [ ! -f "$RAW" ]; then
    log "Verifying SHA256 of $(basename "$ZST")..."
    GOT_SHA="$(sha256sum "$ZST" | awk '{print $1}')"
    [ "$GOT_SHA" = "$EXPECTED_SHA256" ] || die "SHA256 mismatch: got $GOT_SHA expected $EXPECTED_SHA256"
    log "SHA256 verified OK. Decompressing with zstd -d -T0..."
    zstd -d -T0 "$ZST" -o "$RAW"
fi

log "Parsing partition table (MBR/GPT) of $RAW..."
read -r P2_OFF P3_OFF <<EOF
$(python3 - "$RAW" <<'PY'
import struct, sys
with open(sys.argv[1], "rb") as f:
    f.seek(512)
    hdr = f.read(92)
    if hdr[:8] == b"EFI PART":
        part_lba = struct.unpack_from("<Q", hdr, 72)[0]
        num_parts = struct.unpack_from("<I", hdr, 80)[0]
        ent_sz = struct.unpack_from("<I", hdr, 84)[0]
        f.seek(part_lba * 512)
        offs = {}
        for i in range(num_parts):
            ent = f.read(ent_sz)
            if ent[:16] == b"\x00" * 16:
                continue
            first_lba, _ = struct.unpack_from("<QQ", ent, 32)
            offs[i + 1] = first_lba * 512
        print(f"{offs[2]} {offs[3]}")
    else:
        f.seek(0)
        mbr = f.read(512)
        if mbr[510:512] != b"\x55\xaa":
            raise SystemExit("Neither GPT nor MBR image")
        offs = {}
        for i in range(4):
            e = mbr[446 + i * 16 : 446 + (i + 1) * 16]
            _, ptype, start, count = struct.unpack("<B3xB3xII", e)
            if ptype and count:
                offs[i + 1] = start * 512
                print(f"# MBR p{i+1}: type={ptype:#04x} off={start*512} size={count*512}", file=sys.stderr)
        print(f"{offs[2]} {offs[3]}")
PY
)
EOF

mkdir -p "$MNT_P2" "$MNT_P3" "$MNT_ROOTFS" /steamos

LOOP_P2="$(losetup -f)"
losetup -r -o "$P2_OFF" "$LOOP_P2" "$RAW"
LOOP_P3="$(losetup -f)"
losetup -r -o "$P3_OFF" "$LOOP_P3" "$RAW"

log "Mounting p2 ($LOOP_P2 offset=$P2_OFF) & p3 ($LOOP_P3 offset=$P3_OFF) read-only..."
mount -t ext4 -o ro "$LOOP_P2" "$MNT_P2"
mount -t ext4 -o ro "$LOOP_P3" "$MNT_P3"

log "=== v1.5 ROOTFS INSPECTION ==="
df -h "$MNT_P2" "$MNT_P3"
cat "$MNT_P2/opt/steamos-sm8650/IMAGE.txt" 2>/dev/null || head -n 20 "$MNT_P2/etc/os-release"
echo "--- fstab ---"
cat "$MNT_P2/etc/fstab" 2>/dev/null || true
echo "--- overlay upper ---"
ls -la "$MNT_P2/var/lib/overlays/etc/upper" 2>/dev/null || echo "NO_ETC_OVERLAY"
echo "--- homes in p3 ---"
ls -la "$MNT_P3"
echo "--- passwd/shadow steamos/deck ---"
grep -E "^(root|steamos|deck):" "$MNT_P2/etc/passwd" || true
echo "--- usr/lib/steamos* ---"
ls "$MNT_P2/usr/lib/steamos" 2>/dev/null || true
ls "$MNT_P2/usr/lib/steamos-arm" 2>/dev/null | head -n 45 || true
echo "--- systemd wants & bluetooth/sshd ---"
ls -la "$MNT_P2/etc/systemd/system/multi-user.target.wants/" 2>/dev/null | head -n 40 || true
ls -la "$MNT_P2/usr/lib/systemd/system/sshd.service" "$MNT_P2/usr/lib/systemd/system/bluetooth.service" 2>/dev/null || true
echo "--- wireplumber conf ---"
ls "$MNT_P2/etc/wireplumber/wireplumber.conf.d" "$MNT_P2/usr/share/wireplumber/wireplumber.conf.d" 2>/dev/null || true
echo "--- gamescope scripts & environment.d ---"
ls "$MNT_P2/etc/gamescope/scripts" "$MNT_P2/usr/lib/environment.d" 2>/dev/null || true
echo "--- usr/share/qcom & hexagonrpcd in p2 ---"
ls -la "$MNT_P2/usr/share/qcom" 2>/dev/null || echo "NO_SHARE_QCOM"
which_hxp=$(ls "$MNT_P2/usr/bin/hexagonrpcd" "$MNT_P2/usr/bin/pd-mapper" "$MNT_P2/usr/bin/qrtr-ns" "$MNT_P2/usr/bin/rmtfs" 2>/dev/null || true)
echo "qcom daemons in p2: $which_hxp"

if [ "$INSPECT_ONLY" -eq 1 ]; then
    log "Inspection complete (--inspect-only)."
    exit 0
fi

ROOT_UUID="$(cat /proc/sys/kernel/random/uuid)"
log "Creating ${IMG_SIZE} sparse ext4 loop image at $ROOT_IMG (UUID=$ROOT_UUID)..."
rm -f "$ROOT_IMG"
truncate -s "$IMG_SIZE" "$ROOT_IMG"
mkfs.ext4 -F -L steamos-b5q -U "$ROOT_UUID" -m 1 "$ROOT_IMG" >/dev/null
LOOP_ROOT="$(losetup -f)"
losetup "$LOOP_ROOT" "$ROOT_IMG"
mount -t ext4 -o rw,noatime "$LOOP_ROOT" "$MNT_ROOTFS"

log "Copying p2 (root) -> $MNT_ROOTFS..."
rsync -aHAX --numeric-ids --exclude='/lost+found' "$MNT_P2/" "$MNT_ROOTFS/"

log "Copying p3 (home) -> $MNT_ROOTFS/home..."
mkdir -p "$MNT_ROOTFS/home"
if [ -d "$MNT_P3/steamos" ] || [ -d "$MNT_P3/deck" ]; then
    rsync -aHAX --numeric-ids --exclude='/lost+found' "$MNT_P3/" "$MNT_ROOTFS/home/"
else
    rsync -aHAX --numeric-ids --exclude='/lost+found' "$MNT_P3/" "$MNT_ROOTFS/home/steamos/"
fi

for d in boot dev proc sys tmp run mnt/host; do
    mkdir -p "$MNT_ROOTFS/$d"
done
chmod 1777 "$MNT_ROOTFS/tmp"

log "Applying B5Q overlay..."
env STEAMOS_ROOTFS="$MNT_ROOTFS" ROOT_UUID="$ROOT_UUID" /root/work/apply_b5q_overlay.sh

log "Syncing and checking ext4 filesystem..."
umount "$MNT_ROOTFS"
umount "$MNT_P3"
umount "$MNT_P2"
losetup -d "$LOOP_ROOT"
losetup -d "$LOOP_P3"
losetup -d "$LOOP_P2"
LOOP_ROOT=""
LOOP_P3=""
LOOP_P2=""
trap - EXIT
sync
e2fsck -fy "$ROOT_IMG"
ls -lh "$ROOT_IMG"
log "=== SteamOS root.img assembly COMPLETE (UUID=$ROOT_UUID) ==="
