#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Jerry-zirui (https://github.com/Jerry-zirui/SteamOS_on_zflip5)
#
# Inject Samsung Galaxy Z Flip 5 (SM-F7310 / b5q) kernel modules, firmware,
# static hardware daemons, systemd services, UCM2 audio, Gamescope landscape
# config, SSH/Wi-Fi seeds, and Zaviya safety guards into an extracted SteamOS
# ARM64 rootfs (/steamos_work/rootfs).
set -euo pipefail

R="${STEAMOS_ROOTFS:-/steamos_work/rootfs}"
ROOT_UUID="${ROOT_UUID:?ROOT_UUID must be set to /steamos/root.img ext4 UUID}"
BIN_SRC="${BIN_SRC:-/root/work/steamos_out/bin}"
OVL="${B5Q_OVERLAY:-/root/work/b5q-overlay}"
KREL="${KREL:-7.3.5-b5q-steamos}"
KMOD_SRC="${KMOD_SRC:-/lib/modules/${KREL}}"
FW_SRC="${FW_SRC:-/lib/firmware}"
QCOM_SHARE_SRC="${QCOM_SHARE_SRC:-/usr/share/qcom}"

log() { printf '==> [b5q-overlay] %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -x "$R/usr/bin/bash" ] || die "Invalid SteamOS rootfs at $R"
[ -d "$KMOD_SRC" ] || die "Missing kernel modules $KMOD_SRC"
[ -x "$BIN_SRC/b5q-cover-off" ] || die "Missing $BIN_SRC/b5q-cover-off"
[ -x "$BIN_SRC/b5q-touchd" ] || die "Missing $BIN_SRC/b5q-touchd"
[ -x "$BIN_SRC/hexagonrpcd" ] || die "Missing $BIN_SRC/hexagonrpcd"
[ -d "$OVL/usr" ] || die "Missing b5q-overlay directory at $OVL"

ETC_UPPER=""
if [ -d "$R/var/lib/overlays/etc/upper" ]; then
    ETC_UPPER="$R/var/lib/overlays/etc/upper"
    log "Detected SteamOS /etc overlay upper at $ETC_UPPER (will mirror all /etc writes)"
fi

mirror_etc_file() {
    local rel="$1" mode="${2:-0644}" src="$R/etc/$1"
    chmod "$mode" "$src"
    chown root:root "$src" 2>/dev/null || true
    if [ -n "$ETC_UPPER" ]; then
        mkdir -p "$(dirname "$ETC_UPPER/$rel")"
        cp -a "$src" "$ETC_UPPER/$rel"
    fi
}

mask_unit() {
    local unit="$1"
    mkdir -p "$R/etc/systemd/system"
    ln -sfn /dev/null "$R/etc/systemd/system/$unit"
    rm -f "$R/etc/systemd/system/multi-user.target.wants/$unit" \
          "$R/etc/systemd/system/local-fs.target.wants/$unit" \
          "$R/etc/systemd/system/graphical.target.wants/$unit" 2>/dev/null || true
    if [ -n "$ETC_UPPER" ]; then
        mkdir -p "$ETC_UPPER/systemd/system"
        ln -sfn /dev/null "$ETC_UPPER/systemd/system/$unit"
        rm -f "$ETC_UPPER/systemd/system/multi-user.target.wants/$unit" \
              "$ETC_UPPER/systemd/system/local-fs.target.wants/$unit" \
              "$ETC_UPPER/systemd/system/graphical.target.wants/$unit" 2>/dev/null || true
    fi
}

enable_unit() {
    local unit="$1" target="${2:-multi-user.target}"
    mkdir -p "$R/usr/lib/systemd/system/${target}.wants" \
             "$R/etc/systemd/system/${target}.wants"
    if [ -f "$R/usr/lib/systemd/system/$unit" ]; then
        ln -sfn "/usr/lib/systemd/system/$unit" "$R/usr/lib/systemd/system/${target}.wants/$unit"
        ln -sfn "/usr/lib/systemd/system/$unit" "$R/etc/systemd/system/${target}.wants/$unit"
        if [ -n "$ETC_UPPER" ]; then
            mkdir -p "$ETC_UPPER/systemd/system/${target}.wants"
            ln -sfn "/usr/lib/systemd/system/$unit" "$ETC_UPPER/systemd/system/${target}.wants/$unit"
        fi
    fi
}

# 1. Detect SteamOS user home (steamos or deck)
HOME_USER="steamos"
if [ ! -d "$R/home/steamos" ] && [ -d "$R/home/deck" ]; then
    HOME_USER="deck"
fi
log "SteamOS primary user: $HOME_USER"

# 2. Restore setuid/setgid permissions
log "Restoring setuid/setgid root binaries"
for p in \
    usr/bin/pkexec usr/sbin/pkexec usr/bin/sudo usr/sbin/sudo \
    usr/lib/polkit-1/polkit-agent-helper-1 \
    usr/bin/su usr/bin/passwd usr/bin/newgrp usr/bin/chsh usr/bin/chfn \
    usr/bin/gpasswd usr/bin/unix_chkpwd usr/bin/mount usr/bin/umount; do
    [ -e "$R/$p" ] || continue
    chown root:root "$R/$p"
    chmod 4755 "$R/$p"
done
if [ -e "$R/usr/lib/dbus-1.0/dbus-daemon-launch-helper" ]; then
    dbus_gid="$(awk -F: '$1=="dbus"{print $3}' "$R/etc/group" 2>/dev/null || true)"
    chown "root:${dbus_gid:-root}" "$R/usr/lib/dbus-1.0/dbus-daemon-launch-helper"
    chmod 4750 "$R/usr/lib/dbus-1.0/dbus-daemon-launch-helper"
fi

# 3. Generate a fresh non-empty machine-id (dbus-broker requires a valid 32-hex-char ID)
tr -d '-' < /proc/sys/kernel/random/uuid > "$R/etc/machine-id"
mirror_etc_file "machine-id" 0444

# 4. Install kernel modules (replace Odin2 modules) & B5Q firmware
log "Installing kernel modules ($KREL)"
mkdir -p "$R/usr/lib/modules"
find "$R/usr/lib/modules" -mindepth 1 -maxdepth 1 ! -name "$KREL" -exec rm -rf {} +
rm -rf "$R/usr/lib/modules/$KREL"
cp -a "$KMOD_SRC" "$R/usr/lib/modules/$KREL"
if [ ! -L "$R/lib" ] && [ -d "$R/lib" ]; then
    mkdir -p "$R/lib/modules"
    rm -rf "$R/lib/modules/$KREL"
    ln -sfn "../../usr/lib/modules/$KREL" "$R/lib/modules/$KREL"
fi

log "Installing B5Q firmware & /usr/share/qcom"
mkdir -p "$R/usr/lib/firmware"
for sub in qcom/sm8550 ath11k/WCN6855 qca tsp_synaptics; do
    if [ -d "$FW_SRC/$sub" ]; then
        mkdir -p "$R/usr/lib/firmware/$sub"
        rsync -a --exclude='._*' "$FW_SRC/$sub/" "$R/usr/lib/firmware/$sub/"
    fi
done
for f in tfa98xx.cnt regulatory.db regulatory.db.p7s; do
    [ -f "$FW_SRC/$f" ] && cp -f "$FW_SRC/$f" "$R/usr/lib/firmware/$f"
done
if [ -d "$QCOM_SHARE_SRC" ]; then
    mkdir -p "$R/usr/share/qcom"
    rsync -a --exclude='._*' "$QCOM_SHARE_SRC/" "$R/usr/share/qcom/"
fi

# 5. Install static binaries + b5q-overlay tree
log "Installing static B5Q binaries and b5q-overlay"
mkdir -p "$R/usr/local/bin"
install -m 0755 "$BIN_SRC/b5q-cover-off" "$R/usr/local/bin/b5q-cover-off"
install -m 0755 "$BIN_SRC/b5q-touchd" "$R/usr/local/bin/b5q-touchd"
install -m 0755 "$BIN_SRC/hexagonrpcd" "$R/usr/local/bin/hexagonrpcd"

rsync -rl --no-perms --no-owner --no-group --exclude='._*' "$OVL/" "$R/"
chown -R root:root "$R/usr/local/bin/"b5q-* "$R/usr/lib/steamos-arm/"b5q-* \
                   "$R/usr/lib/systemd/system/"b5q-*.service \
                   "$R/usr/lib/systemd/user/"b5q-*.service \
                   "$R/usr/lib/systemd/system/sm8550-bluetooth-setup.service.d" \
                   "$R/usr/lib/environment.d/60-b5q-gamescope.conf" \
                   "$R/usr/lib/modules-load.d/b5q.conf" \
                   "$R/usr/lib/udev/rules.d/60-b5q-gamepads.rules" \
                   "$R/usr/lib/NetworkManager/conf.d/45-b5q-usb0-unmanaged.conf"
chmod 0755 "$R/usr/local/bin/"b5q-* "$R/usr/lib/steamos-arm/"b5q-*
chmod 0644 "$R/usr/lib/systemd/system/"b5q-*.service \
           "$R/usr/lib/systemd/user/"b5q-*.service \
           "$R/usr/lib/systemd/system/sm8550-bluetooth-setup.service.d/10-b5q.conf" \
           "$R/usr/lib/environment.d/60-b5q-gamescope.conf" \
           "$R/usr/lib/modules-load.d/b5q.conf" \
           "$R/usr/lib/udev/rules.d/60-b5q-gamepads.rules" \
           "$R/usr/lib/NetworkManager/conf.d/45-b5q-usb0-unmanaged.conf"

mkdir -p "$R/usr/lib/systemd/user/gamescope-session.target.wants"
ln -sfn ../b5q-gamescope-ultrawide.service \
    "$R/usr/lib/systemd/user/gamescope-session.target.wants/b5q-gamescope-ultrawide.service"

ln -sfn ../../Qualcomm/sm8550/SM8550-Samsung-B5Q.conf \
    "$R/usr/share/alsa/ucm2/conf.d/sm8550/SM8550-Samsung-B5Q.conf"
chown -R root:root "$R/usr/share/alsa/ucm2/Qualcomm/sm8550" "$R/usr/share/alsa/ucm2/conf.d/sm8550"
chmod 0755 "$R/usr/share/alsa/ucm2/Qualcomm/sm8550" "$R/usr/share/alsa/ucm2/conf.d/sm8550"
chmod 0644 "$R/usr/share/alsa/ucm2/Qualcomm/sm8550/"*.conf

mirror_etc_file "gamescope/scripts/b5q.amoled.lua" 0644
mirror_etc_file "systemd/system/home.mount" 0644
mirror_etc_file "ssh/sshd_config.d/05-b5q-root.conf" 0644
mirror_etc_file "wireplumber/wireplumber.conf.d/60-b5q-audio.conf" 0644

mkdir -p "$R/mnt/host" "$R/home"

# 6. Write clean ext4 fstab (NO x-systemd.growfs for loop root.img!)
cat <<EOF > "$R/etc/fstab"
# Z Flip 5 SteamOS ARM64 loop rootfs (/dev/sda37/steamos/root.img -> /dev/loop0)
UUID=${ROOT_UUID}  /  ext4  defaults,noatime,commit=30  0 0
EOF
mirror_etc_file "fstab" 0644

# 7. Patch shared Zaviya scripts cleanly & reliably via Python
log "Patching Zaviya shared scripts for B5Q safety & UCM2 audio"
python3 - "$R" "${ETC_UPPER:-}" <<'PY'
import os, sys
from pathlib import Path

R = Path(sys.argv[1])
ETC_UPPER = Path(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] else None

def patch_file(path: Path, tag: str, old: str, new: str, required: bool = False) -> None:
    if not path.is_file():
        print(f"  [skip] missing {path}")
        return
    txt = path.read_text(encoding="utf-8", errors="replace")
    if tag in txt:
        print(f"  [ok] {path.name} already patched")
        return
    if old not in txt:
        msg = f"  [WARN] pattern not found in {path}: {old!r}"
        if required:
            raise SystemExit(msg)
        print(msg)
        return
    path.write_text(txt.replace(old, new, 1), encoding="utf-8")
    print(f"  [+] patched {path}")

# sm8550-audio-setup: skip Odin2 mixers on B5Q
patch_file(
    R / "usr/lib/steamos/sm8550-audio-setup",
    "Samsung Galaxy Z Flip5",
    "wait_card() {",
    '# Z Flip 5 uses UCM2 HiFi Speaker + DMIC natively via PipeWire ACP.\n'
    'if grep -qa "Samsung Galaxy Z Flip5" /sys/firmware/devicetree/base/model 2>/dev/null; then\n'
    '  exit 0\n'
    'fi\n\n'
    'wait_card() {',
)

# sm8550-audio-pipewire: force UCM_ONLY=1 for B5Q
patch_file(
    R / "usr/lib/steamos/sm8550-audio-pipewire",
    "Samsung Galaxy Z Flip5",
    '"KONKR Pocket FIT|AYANEO Pocket S2"',
    '"KONKR Pocket FIT|AYANEO Pocket S2|Samsung Galaxy Z Flip5"',
)

# 55-konkr-speaker.conf (if present)
for base in [R / "etc", ETC_UPPER]:
    if base is None:
        continue
    patch_file(
        base / "wireplumber/wireplumber.conf.d/55-konkr-speaker.conf",
        "SM8650-APS2",
        'matches = [ { node.name = "alsa_output.platform-sound.HiFi__Speaker__sink" } ]',
        'matches = [ { node.name = "alsa_output.platform-sound.HiFi__Speaker__sink" alsa.card_name = "SM8650-APS2" } ]',
    )

# BlueZ gamepad compatibility (disable RPA privacy & strict classic bonding)
for base in [R / "etc", ETC_UPPER]:
    if base is None:
        continue
    patch_file(
        base / "bluetooth/main.conf",
        "Privacy = off",
        "Privacy = device",
        "Privacy = off",
    )
    patch_file(
        base / "bluetooth/main.conf",
        "JustWorksRepairing = always",
        "#JustWorksRepairing = never",
        "JustWorksRepairing = always",
    )
    patch_file(
        base / "bluetooth/main.conf",
        "\nAutoEnable=true",
        "#AutoEnable=true",
        "AutoEnable=true",
    )
    patch_file(
        base / "bluetooth/input.conf",
        "ClassicBondedOnly=false",
        "#ClassicBondedOnly=true",
        "ClassicBondedOnly=false",
    )
    patch_file(
        base / "bluetooth/input.conf",
        "\nUserspaceHID=true",
        "#UserspaceHID=true",
        "UserspaceHID=true",
    )

# gamescope-session: disable VRR probe on command-mode single-rate S6E3FAC panel
patch_file(
    R / "usr/lib/steamos/gamescope-session",
    "Samsung Galaxy Z Flip5",
    "export STEAM_GAMESCOPE_VRR_SUPPORTED=1",
    "export STEAM_GAMESCOPE_VRR_SUPPORTED=1\n"
    'if grep -qa "Samsung Galaxy Z Flip5" /sys/firmware/devicetree/base/model 2>/dev/null; then\n'
    "  export STEAM_GAMESCOPE_VRR_SUPPORTED=0\n"
    "fi",
)

# gamescope-session: allow environment.d GAMESCOPE_TOUCH_MODE override (4=passthrough direct touch, 1=left-click mouse)
patch_file(
    R / "usr/lib/steamos/gamescope-session",
    "GAMESCOPE_TOUCH_MODE",
    "--default-touch-mode 4",
    '--default-touch-mode "${GAMESCOPE_TOUCH_MODE:-4}"',
)

# steamwebhelper.sh: disable Gamescope WSI XWayland-bypass for CEF UI child windows
# so overlays (MainMenu, QuickAccess, modals, keyboard) composite via Xwayland DRI3
# instead of fighting over the single parent Wayland surface; 3D games still inherit ENABLE_GAMESCOPE_WSI=1.
for u in ("steamos", "deck"):
    patch_file(
        R / f"home/{u}/.local/share/Steam/steamrtarm64/steamwebhelper.sh",
        "DISABLE_GAMESCOPE_WSI",
        "export LIBGL_KOPPER_DISABLE=true",
        "export LIBGL_KOPPER_DISABLE=true\n"
        "# Prevent Gamescope WSI XWayland-bypass from overriding parent 0x2200035 across CEF child windows\n"
        "# (MainMenu, QuickAccess, modals, virtual keyboard); 3D games still inherit ENABLE_GAMESCOPE_WSI=1.\n"
        "export DISABLE_GAMESCOPE_WSI=1",
    )

# is-system-disk: never expose /dev/sda* UFS partitions to Steam Storage format UI
patch_file(
    R / "usr/lib/steamos-arm/is-system-disk",
    "Samsung Galaxy Z Flip5",
    "for mnt in / /home;",
    'if grep -qa "Samsung Galaxy Z Flip5" /sys/firmware/devicetree/base/model 2>/dev/null; then\n'
    '  case "$name" in sd*) exit 0 ;; esac\n'
    "fi\n"
    "for mnt in / /home /mnt/host;",
)

# steamos-sm8550-expand-home: never resize loop image partition
patch_file(
    R / "usr/lib/steamos/steamos-sm8550-expand-home",
    "Samsung Galaxy Z Flip5",
    'if [[ -f "$STAMP" ]]; then',
    'if grep -qa "Samsung Galaxy Z Flip5" /sys/firmware/devicetree/base/model 2>/dev/null; then\n'
    '  touch "$STAMP"; exit 0\n'
    'fi\n\nif [[ -f "$STAMP" ]]; then',
)

# update-agent: block Odin2 OTA .sau updates from touching B5Q kernel/overlay
ua = R / "usr/lib/steamos-arm/update-agent"
if ua.is_file():
    txt = ua.read_text(encoding="utf-8", errors="replace")
    if "Samsung Galaxy Z Flip5" not in txt and "def tablet():" in txt and "return any(" in txt:
        idx = txt.index("return any(")
        txt = (
            txt[:idx]
            + 'if "Samsung Galaxy Z Flip5" in Path("/sys/firmware/devicetree/base/model").read_text(errors="ignore"):\n'
            + "        return True\n    "
            + txt[idx:]
        )
        ua.write_text(txt, encoding="utf-8")
        print(f"  [+] patched {ua}")
PY

# 8. Mask conflicting handheld/OTA units & enable B5Q services + sshd
log "Masking conflicting services & enabling B5Q services + sshd"
for u in steamos-sm8550-expand-home.service konkrd.service \
         steamos-arm-power.service odin3-thor-autoinstall.service \
         dsp_service.service iris-driver-rebind.service \
         steamos-arm-update.service steamos-arm-update-cleanup.service \
         steamos-arm-efi-sync.service firewalld.service; do
    mask_unit "$u"
done

for u in sshd.service b5q-cover-off.service b5q-touchd.service \
         b5q-bt-addr.service b5q-hexagonrpcd.service b5q-power-sync.service \
         b5q-usb-ncm.service b5q-zram-swap.service; do
    enable_unit "$u" multi-user.target
done

# 9. Pre-seed SSH keys & NetworkManager Wi-Fi
log "Pre-seeding SSH keys & NetworkManager Wi-Fi"
mkdir -p "$R/root/.ssh" "$R/home/$HOME_USER/.ssh"
PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGbB4xNII5axJJChOkbS+JBosBVWldUlFbO8s/9RQttl jerryou_cn@outlook.com"
printf '%s\n' "$PUBKEY" > "$R/root/.ssh/authorized_keys"
printf '%s\n' "$PUBKEY" > "$R/home/$HOME_USER/.ssh/authorized_keys"
chmod 0700 "$R/root/.ssh" "$R/home/$HOME_USER/.ssh"
chmod 0600 "$R/root/.ssh/authorized_keys" "$R/home/$HOME_USER/.ssh/authorized_keys"
chown -R root:root "$R/root/.ssh"
chown -R 1000:1000 "$R/home/$HOME_USER/.ssh"

if ls /etc/NetworkManager/system-connections/*.nmconnection >/dev/null 2>&1; then
    mkdir -p "$R/etc/NetworkManager/system-connections"
    for f in /etc/NetworkManager/system-connections/*.nmconnection; do
        bn="$(basename "$f")"
        cp -f "$f" "$R/etc/NetworkManager/system-connections/$bn"
        sed -i '/^mac-address=/d' "$R/etc/NetworkManager/system-connections/$bn"
        mirror_etc_file "NetworkManager/system-connections/$bn" 0600
    done
fi

chown 1000:1000 "$R/home/$HOME_USER" 2>/dev/null || true

log "B5Q overlay successfully applied to $R"
