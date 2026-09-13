# Tolino Shine 3 — debloat, no store, no telemetry, KOReader as home

Turn a Tolino Shine 3 (`ntx_6sl`, Android 4.4.2, firmware 16.2.0) into a plain
local-EPUB reader: remove the shop/login/DRM/telemetry app, keep the hardware
working, and keep USB file transfer working without it.

Everything here was developed and verified on a real device. Every non-obvious
claim in these docs was tested rather than assumed, and several tests
contradicted the obvious reading. The traps are written down in
[`docs/findings.md`](docs/findings.md); **read that before you improvise.**

```
stock                                    after
─────────────────────────────────────    ──────────────────────────────────────
de.telekom.epub (shop, login, DRM,  ->   gone
  usage metrics) — also the launcher
SystemCrashReporter.apk              ->   gone
~41 MB retail demo content           ->   gone
sample wallpapers / screensaver      ->   gone
nerz.clone.sda.t-online.de           ->   blackholed in /etc/hosts
USB mass storage on cable plug       ->   provided by a 16 KB helper we wrote
launcher                             ->   KOReader
root                                 ->   still none (nothing is flashed)
```

![KOReader as the home app](docs/images/koreader-home.png)

*After the debloat: KOReader is the only launcher, reading position intact.*

---

## ⚠️ Read this first

**This modifies `/system` on a device you own.** It is reversible: you take a
full partition image first, and that image restores the device completely. But
you can absolutely end up with a device that does not boot if you skip steps or
run these scripts against the wrong firmware.

- **Nothing here flashes the bootloader.** The one genuinely unrecoverable
  action on this hardware is writing to `u-boot`; no script in this repo does
  that, and you should not either.
- Root is obtained by `fastboot boot` of a patched boot image. That is
  **RAM-only** and discarded on reboot, so no permanent root is required.
- The permission patch is a real security trade-off: afterwards *any* app can
  request `MOUNT_UNMOUNT_FILESYSTEMS`. On a single-purpose, sideload-only
  e-reader that is a reasonable trade. On a general-purpose device it is not.
- This is written against **one specific firmware (16.2.0 / build 157800)**. The
  scripts assert known checksums and refuse to run on anything else.

---

## What is deliberately *not* in this repo

No vendor binaries, because they are proprietary and large. You supply them:

| You need | Where from |
|---|---|
| **A reader with its Debug menu enabled** (otherwise there is no adb; see below) | the reader itself: search page → `112358132fb` |
| Official 16.2.0 firmware `update.zip` | `https://download.pageplace.de/ereader/16.2.0/OS44/update.zip` |
| `adb`, `fastboot` | Android SDK platform-tools |
| Android SDK build-tools + JDK 8+ | to build the helper |
| `e2fsprogs` (`e2fsck`, `resize2fs`, `dumpe2fs`, `debugfs`) | your distro |
| `cpio`, `python3`, `unzip` | your distro |
| KOReader APK | <https://github.com/koreader/koreader/releases> — **must be patched to declare HOME**, see [`docs/koreader-as-home.md`](docs/koreader-as-home.md) |
| `apktool` + `uber-apk-signer` jars | <https://github.com/iBotPeaches/Apktool/releases>, <https://github.com/patrickfav/uber-apk-signer/releases> — needed for that patch |

The repo contains only original scripts and documentation (MIT).

---

## Before anything: the reader must offer adb

**There is no adb until you enable the hidden Debug menu on the reader itself.**
It is off by default, and a factory restore removes it again. The `adb` flag
lives in `persist.sys.usb.config`, which is stored in `/data/property`, and a
restore rewrites `/data`.

On the reader's **search page**, type the code for your firmware and submit the
search:

| Firmware | Debug code |
|---|---|
| **16.x** | **`112358132fb`** |
| 15.x | `1123581321` |
| 14.x | `124816` |

You page through the menu with the on-screen buttons. Page 3 installs APKs from
the reader's storage root, which is itself a fallback for installing KOReader
with no adb.

You can tell which side a problem is on without guessing. The USB product ID
changes with the gadget composition:

```
1f85:6053   mass storage only, no adb   ->  `adb devices` is empty
1f85:6052   mass_storage,adb            ->  the reader is listed
```

If you see `6053`, the device is not offering adb and nothing host-side will fix
it. More detail: [`docs/factory-restore.md`](docs/factory-restore.md).

---

## Quick start

```bash
# 0. ON THE READER FIRST: search page -> 112358132fb -> submit the search.
#    Then confirm the host can see it (expect 1f85:6052, not 6053):
adb devices

# 1. confirm you are talking to the right device
scripts/00-check-device.sh

# 2. get a stock boot image out of the official firmware
scripts/20-root.sh extract ~/Downloads/update.zip

# 3. build the RAM-only rooted image, boot it, wait for a root shell
scripts/20-root.sh build
scripts/20-root.sh boot

# 4. back everything up WHILE ROOTED (this is the important step)
scripts/10-backup.sh

# 5. PREPARE AND INSTALL A LAUNCHER-CAPABLE KOReader: before step 6 deletes
#    EPubProd.apk, the stock launcher. The OFFICIAL KOReader APK does NOT declare
#    HOME, so installing it as-is leaves the device with no home app at all.
#    25 downloads it, adds HOME + DEFAULT, rebuilds, signs and verifies:
scripts/25-prepare-koreader.sh --install
#    (30-debloat.sh re-checks this and refuses to run if no launcher would remain)

# 6. remove the store / telemetry / retail content
scripts/30-debloat.sh

# 7. make the permission grantable, and install the USB helper
scripts/31-patch-framework.sh
scripts/40-install-ums-helper.sh

# 8. reboot, then verify
adb reboot && sleep 45
scripts/00-check-device.sh
```

Then, optionally, build a system image you can restore through fastboot alone.

**Mind which image you feed it.** The backup from step 4 was taken *before* the
changes, so it is the **pre-change (stock)** system. That is useful: it restores
stock over fastboot without the recovery dance. But it is not your debloated
result. To capture *that*, root again and take a second backup:

```bash
scripts/20-root.sh boot                            # root again
scripts/10-backup.sh work/backups-after            # the debloated state
scripts/50-make-flashable-image.sh work/backups-after/system-partition-p5.img
```

Free space in the result depends entirely on the source image. The script shrinks
to the largest filesystem that fits the 352 MiB fastboot cap, so a **stock**
system uses ~318 MB and ends up with only ~19 MiB free, while a **debloated** one
finishes with ~81 MiB. Read the number it prints before trusting the image.

---

## How it works, in four points

**1. Root without writing anything.** `fastboot boot` loads a patched boot image
into RAM and discards it on reboot, so the boot partition is never touched. The
vendor `adbd` has to be NOP-patched in the binary itself. Setting `ro.debuggable`
alone does nothing, because it was built without `ALLOW_ADBD_ROOT`.

**2. The system-level changes all live in `/system`:** remove the store stack,
flip one `protectionLevel` in `framework-res.apk` so the helper may hold
`MOUNT_UNMOUNT_FILESYSTEMS`, install the helper. KOReader stays an ordinary
`/data` app; see point 3.

**3. KOReader must be patched to be a launcher**, because the official APK
declares no HOME category and point 2 deletes the stock launcher. That is what
`scripts/25-prepare-koreader.sh` is for.

**4. Recovery is a fastboot flash, not a ritual.** The system image is shrunk to
fit the bootloader's 352 MiB download cap, so it restores the device even when
Android will not boot.

**The reasoning behind every non-obvious decision, and the traps that cost real
debugging time, is in [`docs/findings.md`](docs/findings.md). Read it before
improvising.** The other docs go deeper on one subject each:
[`koreader-as-home.md`](docs/koreader-as-home.md),
[`backup-restore.md`](docs/backup-restore.md),
[`factory-restore.md`](docs/factory-restore.md),
[`troubleshooting.md`](docs/troubleshooting.md).

---

## Going back

| You want | Do this |
|---|---|
| Undo the permission patch | `scripts/31-patch-framework.sh --revert` |
| Restore the whole debloated `/system` | `fastboot flash system <flashable>.img` |
| Restore the exact original `/system` | `dd` the raw image over `mmcblk0p5` from a rooted session |
| Go back to stock completely | the official `update.zip` via stock recovery |
| Root again, later | `scripts/20-root.sh boot` |
| Reinstall KOReader after a wipe | `adb install <your patched>.apk` — the official APK cannot be a launcher, see [`docs/koreader-as-home.md`](docs/koreader-as-home.md) |

Details and the exact commands: [`docs/backup-restore.md`](docs/backup-restore.md).
For a full return to stock, including an audit of which partitions the official
OTA writes on this hardware and the adb-after-restore gotcha, see
[`docs/factory-restore.md`](docs/factory-restore.md).

---

## Known limitations — honestly

- **One unreproduced display crash.** A single `surfaceflinger` SIGSEGV was seen
  during a boot that also ran a dexopt and enabled USB storage early. Two cold
  boots, including one with those exact conditions, did not reproduce it. It
  self-heals via a runtime restart in ~20 s. Treat it as a rare vendor flake. If
  it recurs reliably, delay the helper's UMS enable at boot.
- **KOReader is not wipe-durable, and cannot cheaply be.** It is a `/data` app,
  so a factory reset removes it. Restoring it means reinstalling your **patched**
  APK, not the official one, which cannot be a launcher. Moving it to
  `/system/app` **breaks it**: its `MainActivity` is a `NativeActivity`. It
  resolves its native library through `nativeLibraryDir` (on this build always
  `/data/app-lib/<name>`) and never falls back to `/system/lib`. See
  `docs/findings.md` §5.
- **A factory reset does not touch your books.** The stock recovery's wipe path
  formats `/data` and `/cache` only. The user partition (p4) is not a wipe
  target. You will still need to reinstall KOReader into the emptied `/data`.
- **A *flashed* shrunken image leaves 81 MiB free on `/system`**, against 121.7 MiB
  for the real thing. It only matters if you restore that way, and 81 MiB is ample
  (`scripts/50-make-flashable-image.sh` prints the number it achieves).

---

## Repo layout

```
scripts/           the pipeline, in order
  00-check-device  identity check (safe, read-only)
  10-backup        partition images (needs root)
  20-root          build + RAM-boot the rooted image; extract from firmware
  25-prepare-koreader  patch + re-sign KOReader so it can be a launcher
  30-debloat       remove the store/telemetry/retail stack
  31-patch-framework  protectionLevel patch, mtime-preserving
  40-install-ums-helper  build + install into /system/app
  50-make-flashable-image  shrink a system image under the fastboot cap
root/              build-rooted-boot.sh, verify-rooted-boot.sh
framework-patch/   patch-axml.py (binary AXML), repack-apk.py
ums-helper/        the USB mass-storage helper: source, manifest, build.sh
docs/              findings.md (READ THIS), backup-restore.md,
                   troubleshooting.md, koreader-as-home.md,
                   factory-restore.md
```

## Prior art and credit

The root method follows the ALLESebook community guide for this device family
(temporary `fastboot boot` root, no security bypass, no exploit). The patched
`adbd` this repo reproduces is byte-identical to the one shipped in that
community image, which is a useful cross-check rather than a dependency.

## License

MIT — see [`LICENSE`](LICENSE). No vendor binaries are licensed or distributed
here.
