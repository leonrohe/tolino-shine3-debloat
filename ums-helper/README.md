# ums-helper — USB mass storage for a Tolino with no store app

A ~16 KB pure-Java Android app that restores **one** behaviour of the removed
`de.telekom.epub`: making the reader's storage appear as a drive on the PC when
the cable is plugged in.

## Why it is needed

The stock app called `StorageManager`/`IMountService.setUsbMassStorageEnabled(true)`
on cable plug. With the store app gone, the USB gadget still advertises
`mass_storage`, so the PC shows a drive — but no volume is ever shared and the
drive is 0 bytes.

MTP is not an alternative on this ROM: the framework knows only `audio_source`,
`mass_storage` and `rndis`, and ships no `MtpService` at all. Mass storage is the
only transfer mode that exists here.

## What it does

```
cable in   -> stop KOReader, show a static screen, share the volume
cable out  -> unshare + wait for the volume to really come back, relaunch KOReader
```

The ordering is the whole point. Sharing the volume takes
`/storage/sdcard1` away from Android, and KOReader immediately dies with
`SecurityException: Invalid mkdirs path: /mnt/media_rw/sdcard1/...`. So:

- KOReader is stopped **before** the volume is shared.
- While shared, only a static, storage-free screen is shown. It must not touch
  storage — the volume belongs to the PC at that moment.
- Before relaunching KOReader the helper waits for the volume to be genuinely
  usable, checking both `!isVolumeShared()` and the mount state — not a fixed
  sleep. An earlier blind 8 s wait produced `Invalid mkdirs path` crashes.

## Files

| File | Role |
|---|---|
| `AndroidManifest.xml` | two permissions; one activity; one receiver. **No HOME category** |
| `src/…/UsbModeActivity.java` | the USB screen + the connect/disconnect orchestration |
| `src/…/UmsReceiver.java` | listens for `UMS_CONNECTED` / `UMS_DISCONNECTED` |
| `src/…/MountService.java` | binder call to the mount service |
| `src/…/BadgeView.java` | canvas-drawn badge (no image assets) |
| `build.sh` | aapt2 + javac + d8 + zipalign + apksigner (v1 — required for API 19) |

## Two traps it exists to avoid

**Never broadcast a sticky `USB_STATE`.** It replays at boot, which shares
storage before KOReader can start and produces a crash loop. Only the explicit
`UMS_CONNECTED` / `UMS_DISCONNECTED` actions are handled.

**`StorageManager.setUsbMassStorageEnabled` does not exist on this build** —
calling it throws `NoSuchMethodException`. Use the binder call:

```java
IMountService svc = IMountService.Stub.asInterface(
        ServiceManager.getService("mount"));
svc.setUsbMassStorageEnabled(true);
```

This was found only after adding logging instead of swallowing the exception —
worth remembering.

## The USB screen

![The USB storage screen](../docs/images/usb-storage-connected.png)

*Plugging or unplugging the cable swaps the glyph and the text but moves nothing.*

Fixed geometry, no `WRAP_CONTENT`: a `FrameLayout` with fixed dp sizes for the
badge, heading, rule and body, so the connected and disconnected variants render
at **identical** positions. Verified as byte-identical screenshots across three
boots.

## Permissions

- `MOUNT_UNMOUNT_FILESYSTEMS` — required, and unobtainable until
  `framework-res.apk` is patched so its `protectionLevel` is `normal`
  (`../scripts/31-patch-framework.sh`).
- `KILL_BACKGROUND_PROCESSES` — to stop KOReader before its volume is taken away.

## Build

```bash
SDK=$HOME/Android/Sdk ./build.sh
```

Requires Android SDK build-tools (aapt2, d8, zipalign, apksigner) and a JDK.

`build.sh` generates a debug keystore on first run. Note the consequence:
**rebuilding on another machine produces a differently-signed APK.** That does
not matter for installing into `/system/app` (root replaces the file directly),
but it does mean `adb install -r` across machines will hit a signature mismatch —
uninstall first, or use the `/system/app` path.

## Install

Use `../scripts/40-install-ums-helper.sh`. It installs into `/system/app`, then:

- deletes any `/data/app` copy (the durability trap — see `../docs/findings.md` §5)
- deletes the stale `/data/dalvik-cache` entry (the odex trap — §6)
- tells you to reboot and what to verify

After rebooting, all three must hold:

```bash
adb shell pm path org.tolino.umshelper
#   package:/system/app/UmsHelper.apk        <- /system, not /data

adb shell dumpsys package org.tolino.umshelper | grep -A3 grantedPermissions
#   MOUNT_UNMOUNT_FILESYSTEMS
#   KILL_BACKGROUND_PROCESSES

# and physically: plug in the cable -> USB screen appears, drive appears on the PC
```
