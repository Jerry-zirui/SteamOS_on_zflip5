#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Jerry-zirui (https://github.com/Jerry-zirui/SteamOS_on_zflip5)
#
# Builds dual-boot initramfs_steamos.cpio.gz on the phone:
#   Tier 0 (SteamOS ARM64): /dev/sda37/steamos/boot-steamos + root.img (/dev/loop0) -> /sbin/init
#   Tier 1 (Alpine KDE):    /dev/sda37/sbin/b5q-desktop-init (preserved untouched fallback)
#   Tier 2 (Alpine Rescue): /dev/sda29 (/cache/pmos_root/sbin/b5q-init)
#   Tier 3 (USB Rescue):    BusyBox + Dropbear SSH over USB CDC-NCM (172.16.42.1)
set -e
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

WORK=/root/work/initramfs_steamos_root
OUT=/root/work/steamos_out/initramfs_steamos.cpio.gz

rm -rf "$WORK"
mkdir -p "$WORK/bin" "$WORK/sbin" "$WORK/lib" "$WORK/usr/bin" "$WORK/usr/sbin" "$WORK/usr/lib" \
         "$WORK/etc/dropbear" "$WORK/root/.ssh" "$WORK/proc" "$WORK/sys" "$WORK/dev" "$WORK/tmp" \
         "$WORK/run" "$WORK/mnt/sda37" "$WORK/mnt/cache" "$WORK/newroot" "$WORK/var/lib/misc"

copy_with_libs() {
    local bin="$1"
    local dst="$2"
    cp -L "$bin" "$WORK$dst"
    chmod 755 "$WORK$dst"
    for lib in $(ldd "$bin" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^\//) print $i}'); do
        if [ -f "$lib" ]; then
            mkdir -p "$WORK$(dirname "$lib")"
            cp -Ln "$lib" "$WORK$lib" 2>/dev/null || true
        fi
    done
}

copy_with_libs /bin/busybox /bin/busybox
copy_with_libs /usr/sbin/dropbear /usr/sbin/dropbear
[ -x /usr/bin/dropbearkey ] && copy_with_libs /usr/bin/dropbearkey /usr/bin/dropbearkey || true
[ -x /sbin/blkid ] && copy_with_libs /sbin/blkid /sbin/blkid || true

for app in $("$WORK/bin/busybox" --list 2>/dev/null || /bin/busybox --list); do
    if [ ! -e "$WORK/bin/$app" ] && [ ! -e "$WORK/sbin/$app" ] && [ ! -e "$WORK/usr/bin/$app" ] && [ ! -e "$WORK/usr/sbin/$app" ]; then
        ln -sf /bin/busybox "$WORK/bin/$app"
    fi
done

if [ -x /usr/bin/dropbearkey ]; then
    /usr/bin/dropbearkey -t ed25519 -f "$WORK/etc/dropbear/dropbear_ed25519_host_key" >/dev/null
    chmod 600 "$WORK/etc/dropbear/dropbear_ed25519_host_key"
fi

cat <<'EOF' > "$WORK/root/.ssh/authorized_keys"
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGbB4xNII5axJJChOkbS+JBosBVWldUlFbO8s/9RQttl jerryou_cn@outlook.com
EOF
chmod 700 "$WORK/root/.ssh"
chmod 600 "$WORK/root/.ssh/authorized_keys"

cat <<'EOF' > "$WORK/etc/passwd"
root::0:0:root:/root:/bin/sh
EOF
cat <<'EOF' > "$WORK/etc/group"
root:x:0:
EOF
cat <<'EOF' > "$WORK/etc/shells"
/bin/sh
/bin/ash
EOF

cat <<'EOF' > "$WORK/etc/udhcpd.conf"
start 172.16.42.2
end 172.16.42.10
interface usb0
lease_file /var/lib/misc/udhcpd.leases
opt subnet 255.255.255.0
opt router 172.16.42.1
EOF
touch "$WORK/var/lib/misc/udhcpd.leases"

cat <<'EOF' > "$WORK/init"
#!/bin/sh
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
export HOME=/root

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mkdir -p /dev/pts /dev/shm /sys/kernel/config /mnt/sda37 /mnt/cache /newroot
mount -t devpts devpts /dev/pts 2>/dev/null || true
mount -t configfs configfs /sys/kernel/config 2>/dev/null || true
[ -b /dev/loop0 ] || mknod -m 660 /dev/loop0 b 7 0 2>/dev/null || true

exec </dev/tty0 >/dev/tty0 2>&1

clear
echo "=================================================="
echo "  Mainline Linux 7.3.5 on Z Flip 5 (SM-F7310 b5q) "
echo "  SteamOS ARM64 / Alpine KDE Dual-Boot Initramfs  "
echo "=================================================="
echo "[Initramfs] $(uname -r) | $(grep MemTotal /proc/meminfo)"

# Wait up to 5s for UFS 4.0 (/dev/sda37 / /dev/sda29) and USB UDC
for i in 1 2 3 4 5; do
    [ -b /dev/sda37 ] && [ -n "$(ls /sys/class/udc 2>/dev/null)" ] && break
    sleep 1
done

# Auto-clear boot-recovery flag in misc (/dev/sda10)
if [ -b /dev/sda10 ]; then
    MISC_HDR=$(dd if=/dev/sda10 bs=13 count=1 2>/dev/null || true)
    if [ "$MISC_HDR" = "boot-recovery" ]; then
        dd if=/dev/zero of=/dev/sda10 bs=4096 count=1 2>/dev/null && sync
        echo "[MISC] Cleared boot-recovery flag on /dev/sda10"
    fi
fi

# Bring up macOS-native USB CDC-NCM Ethernet gadget EARLY so it persists across switch_root
G=/sys/kernel/config/usb_gadget/g1
if [ -d /sys/kernel/config/usb_gadget ]; then
    mkdir -p "$G"
    echo 0x18d1 > "$G/idVendor"
    echo 0xd001 > "$G/idProduct"
    echo 0x0200 > "$G/bcdUSB"
    mkdir -p "$G/strings/0x409"
    echo "b5q-steamos" > "$G/strings/0x409/serialnumber"
    echo "Samsung-Mainline" > "$G/strings/0x409/manufacturer"
    echo "Z Flip 5 SteamOS ARM64 (b5q)" > "$G/strings/0x409/product"
    mkdir -p "$G/configs/c.1/strings/0x409"
    echo "NCM" > "$G/configs/c.1/strings/0x409"
    echo 500 > "$G/configs/c.1/MaxPower"

    mkdir -p "$G/functions/ncm.usb0"
    ln -sf "$G/functions/ncm.usb0" "$G/configs/c.1/"

    UDC=$(ls /sys/class/udc 2>/dev/null | head -n 1)
    if [ -n "$UDC" ]; then
        echo "$UDC" > "$G/UDC"
        echo "[USB] Bound CDC-NCM gadget to $UDC"
    fi
fi

do_switch_root() {
    local target_init="$1"
    umount /sys/kernel/config 2>/dev/null || true
    umount /dev/pts 2>/dev/null || true
    mount --move /dev /newroot/dev
    mount --move /proc /newroot/proc
    mount --move /sys /newroot/sys
    exec switch_root /newroot "$target_init"
}

if [ -b /dev/sda37 ]; then
    echo "[ROOT] Mounting /dev/sda37..."
    if mount -t ext4 -o rw,noatime /dev/sda37 /mnt/sda37; then
        # Tier 0: SteamOS ARM64 loop rootfs (/steamos/root.img gated by /steamos/boot-steamos)
        if [ -f /mnt/sda37/steamos/boot-steamos ] && [ -f /mnt/sda37/steamos/root.img ]; then
            echo "[ROOT] Found /steamos/boot-steamos + root.img -> attaching /dev/loop0..."
            if losetup /dev/loop0 /mnt/sda37/steamos/root.img && mount -t ext4 -o rw,noatime /dev/loop0 /newroot; then
                INIT_BIN=""
                if [ -x /newroot/sbin/init ] || [ -L /newroot/sbin/init ]; then
                    INIT_BIN=/sbin/init
                elif [ -x /newroot/usr/lib/systemd/systemd ]; then
                    INIT_BIN=/usr/lib/systemd/systemd
                fi
                if [ -n "$INIT_BIN" ]; then
                    mkdir -p /newroot/mnt/host
                    mount --move /mnt/sda37 /newroot/mnt/host
                    echo "[ROOT] Booting SteamOS ARM64 -> $INIT_BIN!"
                    do_switch_root "$INIT_BIN"
                else
                    echo "[ROOT] ERROR: SteamOS init missing in root.img, falling back to Alpine!"
                    umount /newroot 2>/dev/null || true
                fi
            else
                echo "[ROOT] ERROR: Failed to loop-mount /steamos/root.img, falling back to Alpine!"
            fi
            losetup -d /dev/loop0 2>/dev/null || true
        fi

        # Tier 1: Untouched Alpine KDE Plasma 6 on /dev/sda37
        if [ -x /mnt/sda37/sbin/b5q-desktop-init ] && sh -n /mnt/sda37/sbin/b5q-desktop-init 2>/dev/null; then
            mount --move /mnt/sda37 /newroot
            echo "[ROOT] Booting Alpine fallback -> /sbin/b5q-desktop-init!"
            do_switch_root /sbin/b5q-desktop-init
        elif [ -x /mnt/sda37/sbin/b5q-init ] && sh -n /mnt/sda37/sbin/b5q-init 2>/dev/null; then
            mount --move /mnt/sda37 /newroot
            echo "[ROOT] Booting Alpine fallback -> /sbin/b5q-init!"
            do_switch_root /sbin/b5q-init
        fi
        umount /mnt/sda37 2>/dev/null || true
    fi
fi

# Tier 2: Persistent Alpine bootstrap/rescue rootfs on /dev/sda29 (/cache/pmos_root)
if [ -b /dev/sda29 ]; then
    echo "[ROOT] Mounting /dev/sda29 (cache bootstrap/rescue)..."
    if mount -t ext4 -o rw,noatime /dev/sda29 /mnt/cache; then
        if [ -x /mnt/cache/pmos_root/sbin/b5q-init ]; then
            echo "[ROOT] Found /cache/pmos_root/sbin/b5q-init -> switching root!"
            mount --bind /mnt/cache/pmos_root /newroot
            umount /mnt/cache 2>/dev/null || true
            do_switch_root /sbin/b5q-init
        fi
        umount /mnt/cache 2>/dev/null || true
    fi
fi

# Tier 3: Rescue fallback in initramfs
ifconfig lo 127.0.0.1 up
ifconfig usb0 172.16.42.1 netmask 255.255.255.0 up 2>/dev/null || true
udhcpd /etc/udhcpd.conf &
dropbear -R -B -p 22 &
echo "[RESCUE] USB CDC-NCM SSH ready on 172.16.42.1"
while true; do
    /bin/sh
    sleep 1
done
EOF
chmod 755 "$WORK/init"

cd "$WORK"
find . | cpio -H newc -o 2>/dev/null | gzip -9 > "$OUT"
ls -lh "$OUT"
