# Backing up and restoring

The rule: back up before you change anything, and verify the backup is real
rather than assuming it is. A backup you have never validated is a hypothesis.

## What to back up

| Partition | Image | Why |
|---|---|---|
| `mmcblk0p5` (`/system`) | `system-partition-p5.img` | everything this project modifies lives here |
| `mmcblk0p1` (`/boot`) | `boot-partition-p1.img` | to prove/restore a stock boot partition |

You do **not** need to back up `/data` (p7): it holds the KOReader APK
(reinstallable from your patched APK, see koreader-as-home.md) and app state.
KOReader's real settings live on the user partition p4, which a factory reset
does not touch (see `findings.md` §11).

## Taking the backup

This requires root, so the order is: **root in RAM → back up → modify**.

```bash
scripts/20-root.sh build && scripts/20-root.sh boot   # RAM-only, writes nothing
scripts/10-backup.sh
```

Manually, the whole thing is:

```bash
adb pull /dev/block/mmcblk0p5 system-partition-p5.img
adb pull /dev/block/mmcblk0p1 boot-partition-p1.img
sha256sum ./*.img > SHA256SUMS
```

`adb pull` handles block devices correctly. `adb exec-out` does **not** work
against this adbd (`error: closed`). Do not "improve" this by switching to it.

## Verifying the backup is real

The checks are independent, and neither is enough on its own:

```bash
# 1. is it a filesystem at all?
dumpe2fs -h system-partition-p5.img
#    expect: Filesystem state: clean, last mounted on /system,
#            Block count 98302, Free blocks 31159

# 2. is the CONTENT intact? (metadata can be consistent while data is not)
debugfs -R "dump /app/UmsHelper.apk /tmp/check.apk" system-partition-p5.img
md5sum /tmp/check.apk
```

A worked example from the reference device: the extracted `UmsHelper.apk` hashes
to `208509c92601262bdb58cb0ab5f2ed87`, matching both the device and the build
machine.

## Restore path 1 (preferred): flash through fastboot

This needs only the bootloader, so it works even when Android will not boot.

```bash
scripts/50-make-flashable-image.sh work/backups/system-partition-p5.img
adb reboot fastboot
fastboot flash system work/backups/system-partition-p5-FLASHABLE.img
fastboot reboot
```

The bootloader caps a single download at **352 MiB**, and a full `/system`
image is 384 MiB. It is rejected instantly with `FAILED (remote: '')`. The
script shrinks the filesystem to fit while keeping ~80 MB free. See
`findings.md` §3a.

If Android is already dead, `adb reboot fastboot` is unavailable. Arm the flash
first, then enter fastboot physically. The ~5 s window means the command must
already be waiting:

```bash
fastboot flash system work/backups/system-partition-p5-FLASHABLE.img   # blocks
# now: power fully off -> connect USB -> hold POWER ~30 s
fastboot reboot
```

## Restore path 2: `dd` the raw image

For the byte-exact original image, which cannot be flashed because it is over
the cap. From a rooted session:

```bash
adb push system-partition-p5.img /cache/system.img     # if it fits
adb shell "dd if=/cache/system.img of=/dev/block/mmcblk0p5 bs=1M"
adb reboot
```

Staging space is the catch. The image is 384 MiB and neither `/data`
(~383 MiB free) nor `/cache` (~372 MiB free) is quite big enough. Options:

- Compress and stream: `gzip -1` shrinks it a lot, then
  `gunzip -c /cache/system.img.gz > /dev/block/mmcblk0p5`, but `/system` must
  not be mounted while you do this.
- Chunk it: push a slice, `dd` it with `seek=` and `conv=notrunc`, delete, repeat:

  ```bash
  # slice N covers bytes [N*96M, (N+1)*96M)
  adb push slice.bin /data/slice.bin
  adb shell "dd if=/data/slice.bin of=/dev/block/mmcblk0p5 bs=1M seek=$((N*96)) conv=notrunc"
  adb shell "rm -f /data/slice.bin"
  ```

Path 1 avoids all of this.

## Restore path 3: back to stock

The official firmware at `/share/orig_update.zip` on the device restores
everything: debloat, framework patch and helper included. Apply it through stock
recovery, **not** by putting it in the storage root (`update.zip` there would
make the reader self-update on the next restart and silently undo every change).

Official 16.2.0 firmware:
`https://download.pageplace.de/ereader/16.2.0/OS44/update.zip`
(210,781,332 bytes; genuine Telekom signature).

## Undoing single changes

| Change | Revert |
|---|---|
| Framework permission patch | `scripts/31-patch-framework.sh --revert` |
| USB helper | `adb shell "rm /system/app/UmsHelper.apk"` from a rooted session |
| Store app / telemetry | restore `/system` from the image (files live only in `/system`) |
| Boot partition | `fastboot flash boot <stock-boot.img>` |

## Notes that will save you time

- `/share` has very little free space (the recovery payload fills it). Do not
  stage images there.
- The boot partition is 6,258,688 bytes but the `boot.img` inside it is smaller.
  The image hash covers the whole partition. The first 4,538,368 bytes are what
  an official `boot.img` contains.
- `fastboot flash` writes exactly the image length and does not erase, so
  flashing a byte-identical image is a true no-op (`findings.md` §3b).
