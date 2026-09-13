# Troubleshooting

Every entry here is a symptom that actually occurred during development, with the
cause that was confirmed — not a guess.

---

### `fastboot devices` shows nothing, or it waits forever

**Cause:** the bootloader only listens for about **5 seconds** after entering
fastboot mode. If you trigger the device first and *then* run `fastboot`, you
miss the window.

**Fix:** arm the command first, so it is already blocked on
`< waiting for any device >`, and only then trigger the device.

```bash
fastboot boot work/rooted-boot.img &      # arm it
adb reboot fastboot                       # ~5 s later the device arrives
```

Also check you are not holding a stale client: `fastboot devices` should list the
device as `Android fastboot`. `adb kill-server` will not affect fastboot, but a
sandbox/container without `/dev/bus/usb` cannot reach fastboot at all
(`findings.md` §9).

---

### `adb reboot bootloader` does nothing

**Cause:** the vendor kernel maps only `"download"`, `"recovery"` and
`"fastboot"` reboot reasons. `bootloader` is silently ignored.

**Fix:** `adb reboot fastboot`. If Android is unreachable, use the physical route
(power fully off → USB connected → hold POWER ~30 s).

---

### `adb root` refuses, or no root shell appears

**Cause:** `ro.debuggable` alone is not the gate. The vendor `adbd` was compiled
without `ALLOW_ADBD_ROOT` and drops privileges unconditionally.

**Fix:** boot the patched image (`scripts/20-root.sh build && ... boot`). Do not
try to solve this by editing `default.prop` — that was the approach that failed
first (`findings.md` §1).

---

### `adb exec-out` fails with `error: closed`

**Cause:** the KitKat adbd on this firmware does not support the exec service.

**Fix:** use `adb shell` for text and `adb pull` for binary. In particular,
`adb pull` reads **block devices** fine, which is how backups are taken.

---

### `Sending 'system' (…) FAILED (remote: '')` — instantly, in ~0.05 s

**Cause:** the image is larger than the bootloader's download buffer
(**352 MiB**, `CONFIG_FASTBOOT_TRANSFER_BUF_SIZE 0x16000000`). It is rejected
before any transfer. It is *not* a missing partition — `fastboot flash boot` with
a small image succeeds on the same bootloader.

**Fix:** `scripts/50-make-flashable-image.sh <raw-system.img>`.

**Do not** try a sparse image: this U-Boot has no sparse support and would write
the container raw over your filesystem.

---

### `adb pull /dev/block/...` → `remote Permission denied`

**Cause:** you are not root. Shell (uid 2000) cannot read raw block devices.

**Fix:** boot the rooted image first. Backups are a rooted operation.

---

### `Not granting permission …MOUNT_UNMOUNT_FILESYSTEMS (protectionLevel=18)`

**Cause:** the framework patch is not applied, or it was applied but the mtime
changed so PMS re-verified the stale signature and discarded the APK's
modifications.

**Fix:** re-run `scripts/31-patch-framework.sh`, then reboot and confirm:

```bash
adb shell dumpsys package org.tolino.umshelper | grep -A3 grantedPermissions
```

---

### Cable plugged in, PC shows a 0-byte drive

**Cause:** nothing is calling `setUsbMassStorageEnabled(true)`. The gadget
advertises `mass_storage` regardless, so the drive appears but is never backed by
a volume.

**Fix:** install the helper (`scripts/40-install-ums-helper.sh`) and check logcat
for its connect flow:

```bash
adb logcat -d | grep UmsHelper
#   onReceive action=android.intent.action.UMS_CONNECTED
#   setUsbMassStorageEnabled(true) ok
```

If the receiver never fires, the framework is not broadcasting `UMS_CONNECTED`.

---

### `pm path` returns `/data/app/...` after installing to `/system`

**Cause:** the `/data/app` update trap (`findings.md` §5). A same-signature
install with a higher versionCode silently wins over the system copy, and a
factory reset silently reverts it.

**Fix:** delete the `/data` copy and reboot; re-check with `pm path`.

---

### The app reports the correct `versionCode` but behaves like the old build

**Cause:** the stale-odex trap (`findings.md` §6). KitKat judges a cached dex by
the APK's mtime and size, and `adb push` carries the build machine's mtime.

**Fix:** delete `/data/dalvik-cache/system@app@<Name>.apk@classes.dex` and reboot.

---

### KOReader crashes: `Unable to find native library: luajit-launcher`

**Cause:** you moved the APK to `/system/app` (or deleted
`/data/app-lib/org.koreader.launcher-*`). `NativeActivity` resolves its library
by absolute path from `nativeLibraryDir`, which is always under `/data` on this
build, and it does not fall back to `/system/lib`.

**Fix:** revert — the documented procedure is in `findings.md` §7:

```bash
# rooted session
mount -o remount,rw /system
rm -f /system/app/KOReader.apk
rm -f /system/lib/{libsdcv,libluajit,libluajit-launcher,libkoreader-monolibtic,libioctl}.so
mount -o remount,ro /system
adb reboot
adb install koreader.apk
```

Reading position survives, because it lives on the user partition.

---

### KOReader crashes: `SecurityException: Invalid mkdirs path: /mnt/media_rw/sdcard1/...`

**Cause:** USB mass storage is enabled, so the volume belongs to the PC and is
gone from Android. KOReader cannot create its files directory.

**Fix:** this is expected while storage is shared — the helper is supposed to stop
KOReader *before* sharing and only relaunch it once the volume is back. If it
happens constantly, the helper's ordering is broken or it was never started.

---

### On boot, a "Complete action using" chooser appears

**Cause:** two apps declare the HOME category and no default is set. This
happened when the helper was briefly given the HOME category.

**Fix:** the helper must **not** declare HOME. See `koreader-as-home.md`.

---

### After a reset the device boots to a blank screen with no way to start anything

**Cause:** `/data` was wiped, taking the only launcher with it (KOReader lives in
`/data`). Nothing was in `/system` to fall back to.

**Fix:** the device is not bricked — `adbd` lives in the ramdisk, so it survives.
`adb install koreader.apk` restores it. Note that a rescue launcher in `/system`
would only help someone with no PC and no cable, and it reintroduces the chooser
problem above, so it is deliberately not part of this project.

---

### `e2fsck -fn` says "Filesystem still has errors" after resizing

**Cause:** growing a filesystem back leaves the resize inode's `i_size` stale.

**Fix:** run `e2fsck -f -y` **again after** the resize, then re-check with
`e2fsck -fn`. The `50-make-flashable-image.sh` script does this, and refuses to
report success unless the read-only check is clean.

Typical message:
`Inode 7, i_size is 96518144, should be 100716544.  Fix? no`

---

### `which <tool>` says a tool is missing, but the tool clearly exists

**Cause:** `which` itself is not on this device. Its failure looks exactly like
"tool absent".

**Fix:** test the tool directly (`dd --help`, `busybox`, …). Confirmed present:
`md5`, `busybox`, `gzip`, `dd`, `cpio`. Confirmed **missing**: `which`, `uname`,
`sha256sum`, `head`, `wc`.

---

### The reader starts updating its firmware and undoes everything

**Cause:** an `update.zip` was placed in the **storage root**. The reader
self-updates from there on the next restart.

**Fix:** keep the recovery payload at `/share/orig_update.zip` (which stock
recovery looks for), never `…/sdcard1/update.zip`.
