# Restoring the device to stock

Useful both for going back, and for testing this repo from a clean slate.

## A "factory reset" is not enough

The stock launcher, the shop and the DRM stack all live in **`/system`**, and
the recovery's wipe only formats `/data` and `/cache` (`findings.md` §11). So a
factory reset leaves the device **debloated** — it only removes apps that
happened to be installed in `/data` (KOReader). The store app cannot come back
that way, because a wipe never touches the partition it lives on.

The only route back to stock is **re-applying the official firmware payload**.

## Getting the payload

```
https://download.pageplace.de/ereader/16.2.0/OS44/update.zip
```

210,781,332 bytes, sha256 `4ab3d0edc89b8287ebcd528df6fbe62fcf223916a26b99acb5148c18e85ead23`,
signed by Deutsche Telekom. Verify the signature before trusting it.

Put it on the reader at `/share/orig_update.zip` — that is `mmcblk0p10`, which
recovery mounts as `/emergency`. Stock recovery looks for exactly that path.

> Do **not** put it at the storage root as `update.zip`. The reader self-updates
> from there on the next restart, which will undo your work at a moment you did
> not choose.

## What the payload actually writes — audited

It is a **file-based OTA** (1159 files), not a block-image OTA. From
`META-INF/com/google/android/updater-script`:

| Step | Line | Risk |
|---|---|---|
| device + version assertions (`ntx_6sl`, 4.4.2) | 42–43 | none — refuses on a mismatch |
| `format("ext4", "EMMC", "/dev/block/mmcblk0p5", ...)` then `package_extract_dir("system", "/system")` | 54–57 | this is the restore |
| `package_extract_file("boot.img", "/dev/block/mmcblk0p1")` | 130 | partition write, safe |
| `package_extract_file("recovery.img", "/dev/block/mmcblk0p2")` | 133 | partition write, safe |
| `run_program("/system/bin/upgrade.sh")` | 142 | see below |

`upgrade.sh` is the vendor's own script, and it is the part that *could* touch
raw eMMC. It contains `dump_uboot()`, `dump_hw_config()`, `dump_logo()` and
`dump_waveform()` — all of which `dd` straight to `/dev/block/mmcblk0`, i.e.
outside any partition. **On a Tolino Shine 3 (`E60K00`) none of them run:**

```sh
# upgrade.sh, dump_uboot() - the one unrecoverable operation
if   [ $PCB_NAME = "E60Q30" ] ; then ... u-boot_E60Q32.bin ...
elif [ $PCB_NAME = "E60Q50" ] ; then ... u-boot_E60Q52.bin ...
elif [ $PCB_NAME = "E60QF0" ] ; then ... u-boot_E60QF2.bin ...
elif [ $PCB_NAME = "E60QJ0" ] ; then ... u-boot_E60QJ2-*.bin ...
elif [ $PCB_NAME = "E70Q20" ] ; then ... u-boot_E70Q22.bin ...
elif [ $PCB_NAME = "E60QV0" ] ; then ... u-boot_E60QV0.bin ...
else
    echo "---> ERROR ! Unknown PCB name"     # <- E60K00 lands here: no write
fi
```

The other raw writes are gated on files that **do not exist in this payload**,
so their `dd` cannot run either:

| Function | Needs | In payload? |
|---|---|---|
| `dump_uboot` | `u-boot_E60Q32.bin` etc. | present, but unreachable on `E60K00` |
| `dump_hw_config` | `hw_config.bin` | **absent** |
| `dump_logo` | `xhdpi_logo.jpg.*` | present, but see the gate below |
| `dump_waveform` | `wbf.bin`, `wbf.header` | **absent** |
| `dump_gsensor` | `gsensor.fw` | **absent** |
| `make_partition` | `make_partition.sh` | **absent** |

`dump_logo`'s files *are* in the payload, but `upgrade.sh` only unzips them out
of `$UPDATE_ZIP_PATH`, and with no arguments that variable is resolved **only**
from `/cache/update.zip`, `/extsd/update.zip`, `/sdcard/update.zip`,
`/data/media/0/update.zip` or `/sdcard/0/update.zip` — *not* from
`/emergency/orig_update.zip`:

```sh
if [ "$1" = "emergency" ] ; then
    UPDATE_ZIP_PATH="/emergency/orig_update.zip"
else
    ... /cache/update.zip, /extsd/update.zip, /sdcard/update.zip ...
fi
busybox unzip -o "$UPDATE_ZIP_PATH" ... -d /cache/upgrade
```

Since the updater-script invokes it with **no** arguments, and none of those
paths exist when the payload sits at `/emergency/orig_update.zip`, the unzip
produces nothing, `/cache/upgrade` stays empty, and every `dd` fails harmlessly.

**Net result on a Shine 3: only `/system` (p5), boot (p1) and recovery (p2) are
written.** Every one of those is recoverable over fastboot. `/share` (p10) is
not formatted, so on-device backups and the payload itself survive.

Also confirmed by reading the script: `dump_upgrade_mode`'s `/sdcard` wipes are
gated behind `$1 = "wipe"` / `"wipe-hotel"`, which the OTA never passes — so a
normal restore does **not** run them. (The `wipe-hotel` branch is the one that
preserves `/sdcard/Books`.)

## Doing it

1. **Back up first** (`scripts/10-backup.sh`) and keep a **flashable** system
   image on a PC (`scripts/50-make-flashable-image.sh`). That image is your way
   back to the debloated state if anything goes wrong.
2. Copy the payload to `/share/orig_update.zip` and verify its md5 against the
   download.
3. Charge the device. The updater aborts below **30 %** battery
   (`upgrade.sh check_battery`).
4. `adb reboot recovery`
5. In the recovery menu choose the **recover system** entry. Formatting `/system`
   and extracting ~340 MB takes several minutes on this eMMC. **Do not unplug or
   power off.**
6. The device reboots into stock: store app and launcher back, `framework-res.apk`
   back to `bfe142ca…`, `/system` back to ~121.7 MiB free.

If it fails partway, `/system` is left formatted and Android will not boot — but
fastboot still works, so flash the debloated image and you are exactly where you
started:

```bash
adb reboot fastboot   # or: power off -> USB -> hold POWER ~30 s, with flash armed
fastboot flash system system-partition-p5-FLASHABLE.img
fastboot reboot
```

## ⚠️ After a factory restore, adb is gone

The restore rewrites `/data`, and `persist.sys.usb.config` — the property that
carries the `adb` flag — lives in **`/data/property`**. So the USB gadget comes
back *without* adb, and you can see it change:

| Gadget composition | USB ID |
|---|---|
| `mass_storage,adb` | `1f85:6052` |
| mass storage, no adb | `1f85:6053` |

`adb devices` will be empty no matter what you do on the host side. **You must
open the hidden Debug menu in the stock launcher first**, and only then will the
device appear.

The code is typed into the reader's **search field**, then submit the search:

| Firmware | Debug code |
|---|---|
| **16.x** | **`112358132fb`** |
| 15.x | `1123581321` |
| 14.x | `124816` |

(These change between major versions — that is why guides for 15.x do not work on
16.x. Source: [clickomania.ch](https://blog.clickomania.ch/2025/06/20/apk-installation-auf-dem-tolino/),
confirmed against a Shine 3 on 16.2.0.)

The menu pages with the on-screen buttons; **page 3 installs APKs** from the
reader's storage root. Turning the debug menu on is what restores the `adb` flag
in `persist.sys.usb.config`, and you can watch it happen on the host side — the
gadget product ID changes back:

```
1f85:6053   (mass storage only, adb absent)   ->  adb devices: empty
1f85:6052   (mass_storage,adb)                ->  adb devices: lists the reader
```

That PID check is a fast way to tell "the device is not offering adb" apart from
"my host-side adb is broken". If you see `6053`, the problem is on the device,
not on the PC.

This same debug menu is also a fallback for installing KOReader without adb at
all: copy the APK to the storage root and use page 3. Note that it reports
`Well, that did not work! Wrong apk?` even when the install **succeeded** — the
error message is wrong.

