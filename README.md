# SteamOS ARM64 on Samsung Galaxy Z Flip 5 (`SM-F7310` / `samsung-b5q`)

Run genuine **Valve SteamOS ARM64** (Zaviya v1.5.0 / Steam Frame 0.6.0 userspace: native Gamescope Game Mode, built-in KDE Plasma 6 Desktop Mode, FEX-Emu x86/x86_64 translation, ARM64 Proton, and Mesa Turnip for Adreno 740) on a slab-modded **Samsung Galaxy Z Flip 5 (`SM-F7310`)**, built on top of the frozen mainline Linux `7.3.5` hardware bring-up from [postmarketOS_on_zflip5](https://github.com/Jerry-zirui/postmarketOS_on_zflip5) and [Zaviya](https://github.com/hashtagbasit/Zaviya).

## Verified Status (`7.3.5-b5q-steamos`)

| Component | Status | Verified Details |
| :--- | :--- | :--- |
| **Mainline Kernel** | ✅ Verified | `7.3.5-b5q-steamos` aarch64 with `CONFIG_BINFMT_MISC=y`, `CONFIG_NTSYNC=y`, `CONFIG_FTRACE=y` (`tracefs`), `CONFIG_ZRAM=y` (`zstd`), `CONFIG_PSI=y`, `BTRFS`/`EROFS`/`SQUASHFS_ZSTD`/`OVERLAY_FS`/`BLK_DEV_LOOP` |
| **Game Mode & GPU** | ✅ Verified | Adreno 740 + GMU v4.1.9 (`msm` + Turnip), S6E3FAC AMOLED (`1080x2640@120Hz`) rotated landscape via `gamescope` (`--force-orientation right`, `1760x720` nested -> `2640x1080`), Steam Big Picture OOBE + CEF active |
| **Touchscreen** | ✅ Verified | `b5q-touchd` + `/dev/input/event3` (`Synaptics S3916A Touchscreen`, `ID_INPUT_TOUCHSCREEN=1`) bound to `gamescope` |
| **Audio** | ✅ Verified | Dual `TFA9878` speakers + dual DMICs via UCM2 (`SM8550-Samsung-B5Q`) and PipeWire/WirePlumber (`HiFi__Speaker__sink` + `HiFi__Mic__source`) |
| **Wi-Fi & USB SSH** | ✅ Verified | `ath11k_pci` WCN6855 (`wlan0` connected via NetworkManager) + USB CDC-NCM gadget (`usb0` `172.16.42.1/24` + IPv6 link-local); `sshd` active |
| **Bluetooth 5.3** | ✅ Verified | WCN6855 `hci0` `UP RUNNING`, public BD_ADDR `02:B5:73:10:00:02`, `Powered: yes`, `Pairable: yes` |
| **SteamOS Integration** | ✅ Verified | `dbus-broker`, `steamos-manager` (system + user), `hexagonrpcd`, `6.7G` `zstd` ZRAM + `8G` swapfile (`/var/mnt/host/steamos/swapfile`), `/dev/ntsync`, `binfmt_misc/box64`, `0 failed` system units, `s2idle` suspend/resume |

## Architecture Overview

- **Stock Bootloader + Safe Partition Layout**: Boots via the Samsung `recovery` partition (`/dev/sda23`) using [mkbootimg_v2.py](tools/mkbootimg_v2.py). No UFS GPT partition tables or stock Android 14 partitions are modified.
- **Dual-Boot Bring-Up (`initramfs_steamos.cpio.gz`)**:
  - **Tier 0**: `/dev/sda37/steamos/root.img` (`32 GiB` sparse ext4 loop image gated by `/steamos/boot-steamos`) -> SteamOS ARM64 (`systemd`)
  - **Tier 1**: Preserved Alpine/KDE Plasma 6 fallback on `/dev/sda37` (`/sbin/b5q-desktop-init`)
  - **Tier 2**: `/dev/sda29` (`/cache/pmos_root`) Alpine rescue rootfs
  - **Tier 3**: Initramfs BusyBox + Dropbear SSH over USB CDC-NCM (`172.16.42.1`)
- **Kernel (`7.3.5-b5q-steamos`)**: Starts from [kernel_7.3.5-b5q-p4.config](configs/kernel_7.3.5-b5q-p4.config) + mainline/B5Q patches, incrementally built via [build_steamos_kernel_on_phone.sh](scripts/build_steamos_kernel_on_phone.sh) -> [kernel_7.3.5-b5q-steamos.config](configs/kernel_7.3.5-b5q-steamos.config).
- **Userspace & `b5q-overlay/`**:
  - Static ARM64 hardware daemons (`b5q-cover-off`, `b5q-touchd`, `hexagonrpcd`)
  - Landscape Gamescope profile ([b5q.amoled.lua](b5q-overlay/etc/gamescope/scripts/b5q.amoled.lua) + [60-b5q-gamescope.conf](b5q-overlay/usr/lib/environment.d/60-b5q-gamescope.conf)) with `STEAM_GAMESCOPE_VRR_SUPPORTED=0`
  - Bluetooth 5.3 MGMT public BD_ADDR (`02:B5:73:10:00:02`) + `busctl` power-on for Bluetooth gamepads
  - ALSA UCM2 (`SM8550-Samsung-B5Q`) + WirePlumber rule (`60-b5q-audio.conf` disabling problematic capture loopback)

## Dual-Boot Switching & Fallback

- **Switch to Alpine KDE (`v1.0.0`) fallback** (from SteamOS shell/SSH):
  ```sh
  sudo rm -f /mnt/host/steamos/boot-steamos
  sudo /usr/local/bin/b5q-reboot recovery
  ```
  (Recreate with `touch /steamos/boot-steamos` from Alpine to boot back into SteamOS ARM64.)
- **Boot stock Android 14**: Power on normally without holding Volume Up, or run:
  ```sh
  sudo /usr/local/bin/b5q-reboot android
  ```

## Flydigi Wee Gamepad Pairing Guide

1. Switch your **Flydigi Wee** into **Classic Bluetooth HID / standard gamepad mode** (hold the Classic HID / `Mode + B` pairing combo until the indicator blinks for standard Bluetooth HID pairing—avoid Flydigi proprietary BLE mapping mode unless using custom mapping).
2. Either pair directly in **Steam Game Mode** under `Settings -> Bluetooth`, or via SSH:
   ```sh
   bluetoothctl
   power on
   agent on
   default-agent
   scan on
   # Wait for Flydigi Wee MAC (e.g. AA:BB:CC:DD:EE:FF) to appear
   pair AA:BB:CC:DD:EE:FF
   trust AA:BB:CC:DD:EE:FF
   connect AA:BB:CC:DD:EE:FF
   ```
3. Once connected, `uhid` / `hid-generic` exposes standard evdev/hidraw nodes to Steam Input (`60-b5q-gamepads.rules`), allowing immediate navigation through the SteamOS OOBE setup, Big Picture UI, and KDE Desktop Mode.

## Repository Layout

- `configs/` — Kernel `.config` baselines (`7.3.5-b5q-p4` and `7.3.5-b5q-steamos`)
- `dts/`, `drivers/`, `patches/` — Frozen `SM-F7310` Device Tree, S6E3FAC DSC panel driver, B5Q userspace daemon C sources, and kernel/`hexagonrpcd` patches
- `audio/` — AudioReach topology (`SM8550-Samsung-B5Q.m4`) & ALSA UCM2 configs
- `b5q-overlay/` — Device-specific `systemd` units, Gamescope script/env, WirePlumber audio rules, Bluetooth MGMT helpers, `udev` gamepad rules, and UCM2 files
- `scripts/` — Build, Zaviya SM8550 extraction, overlay application, dual-boot initramfs, and `/dev/sda23` flash scripts
- `tools/` — Android Boot Image v2 packer (`mkbootimg_v2.py`)

## Licensing & Attribution

See [LICENSE](LICENSE) and [NOTICE](NOTICE). Hardware bring-up assets are licensed under `GPL-3.0-only` / `GPL-2.0-only` with mandatory source attribution to `postmarketOS_on_zflip5` and `Zaviya`. Proprietary vendor firmware binaries are excluded.
