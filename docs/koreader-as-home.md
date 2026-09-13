# KOReader as the home app

KOReader is the only launcher on the device. That is deliberate, and it has one
important consequence you should understand before touching anything.

## Install

```bash
adb install koreader.apk
```

**KOReader declares the HOME category itself**, in the official signed APK, in
`MainActivity`'s `MAIN` intent-filter:

```
E: activity  org.koreader.launcher.MainActivity
    E: action    android.intent.action.MAIN
    E: category  android.intent.category.LAUNCHER
    E: category  android.intent.category.LEANBACK_LAUNCHER
    E: category  android.intent.category.HOME
    E: category  android.intent.category.DEFAULT
```

**Nothing has to set it.** With `EPubProd.apk` gone, KOReader is the *only* HOME
app, so Android resolves HOME to it directly — no preference, no chooser.
Verify:

```bash
adb shell pm path org.koreader.launcher
#   package:/data/app/org.koreader.launcher-1.apk

adb shell dumpsys activity activities | grep mFocusedActivity
#   ActivityRecord{… org.koreader.launcher/.MainActivity}
```

## Do not patch the manifest — the old recipe is a trap

A widely-copied recipe for earlier versions says to decode KOReader with apktool,
*add* `HOME` and `DEFAULT` to `MainActivity`'s intent-filter, rebuild, sign with
a debug key, and `adb uninstall` before installing. **On v2026.07.1 the premise
is simply false** — the categories are already there (see the dump above).
Verify it yourself rather than trusting any guide, including this one:

```bash
aapt2 dump xmltree --file AndroidManifest.xml koreader.apk | grep -A6 'E: activity'
```

Adding them again is harmless to the running app, which is exactly why the recipe
appears to work and stays in circulation — the patch is a no-op and the *real*
cause is simply that KOReader declares HOME and the other launcher is gone.

The cost of following it anyway is real:

- You must re-sign with a **debug key**, so the app can never again be updated
  with `adb install -r` from the official APK — the signatures differ. Every
  update then needs an uninstall first, which takes KOReader's app data with it.
- You drag `apktool` and `uber-apk-signer` into the process for nothing.

Installing the official, signed APK is both simpler and strictly better.

## ⚠️ Do NOT move KOReader into `/system/app`

It is tempting: then a factory reset could not remove it. **It breaks KOReader
completely.** Its `MainActivity` is a `NativeActivity`, which loads its native
library by absolute path from `nativeLibraryDir` — on this build always
`/data/app-lib/<name>` — and never falls back to `/system/lib`. You get:

```
java.lang.RuntimeException: Unable to start activity …MainActivity
  Caused by: java.lang.IllegalArgumentException: Unable to find native library: luajit-launcher
```

Copying its five `.so` files into `/system/lib` does **not** help.

The full reasoning, and the evidence that this is a property of the build rather
than of KOReader, is in [`findings.md` §7](findings.md). The short version:

> Relocating an APK into `/system` is only safe for **pure-Java** apps. KOReader
> has native code; the USB helper does not.

## The rule about the HOME category

**Exactly one app on this device should declare HOME.** An earlier helper build
declared it, and because no default was set the device booted showing a
*"Complete action using"* chooser between KOReader and the helper. The helper's
manifest now deliberately omits the HOME category, and that is why the USB screen
never competes with the reader.

If you add any other app, check whether it declares HOME before installing.

## After a factory reset

KOReader lives in `/data`, so a reset removes it. Your books and KOReader's
settings do **not** disappear — they live on the user partition (`mmcblk0p4`,
mounted `/storage/sdcard1`), which the stock recovery's wipe does not target
(`findings.md` §11).

So the recovery is one command:

```bash
adb install koreader.apk
```

Reading position and settings come back with it, because
`/storage/sdcard1/koreader/settings.reader.lua` is still there.

## Where things live

| Path | Contents |
|---|---|
| `/data/app/org.koreader.launcher-1.apk` | the app (reinstall after a wipe) |
| `/data/app-lib/org.koreader.launcher-1/` | its extracted native libraries — **do not delete** |
| `/storage/sdcard1/koreader/` | settings, plugins, history, cache |
| `/storage/sdcard1/koreader/settings.reader.lua` | reading position and preferences |
| `/storage/sdcard1/Books/` | your library |

## WiFi

WiFi is left enabled on purpose: KOReader's dictionary lookup and Wikipedia
integration need it. If you want the device fully offline, turn it off in the
framework settings — nothing in this project depends on it.

## Updating KOReader later

A newer KOReader APK has a higher `versionCode`, so a plain
`adb install -r koreader.apk` installs it into `/data/app` and it works normally.
That is fine here precisely *because* KOReader is a `/data` app — the opposite of
the durability trap described in `findings.md` §5.
