# KOReader as the home app

KOReader is the only launcher on the device. That is deliberate, and it does not
happen by itself.

## The official APK is not a launcher

The release APK from GitHub does not declare the HOME category, so Android will
never offer it as a home app. This is verified by parsing the binary manifest of
`koreader-android-arm-v2026.07.1.apk` straight from the release:

| MAIN intent-filter of `org.koreader.launcher.MainActivity` | official APK | after the patch |
|---|---|---|
| `android.intent.category.LAUNCHER` | yes | yes |
| `android.intent.category.LEANBACK_LAUNCHER` | yes | yes |
| `android.intent.category.HOME` | **no** | **yes** |
| `android.intent.category.DEFAULT` | **no** | **yes** |

Compare the official APK with the patched one:

```
official  : 29,085,335 B   signer CN=Qingping Hou, OU=KOReader    HOME categories: 0
patched   : 29,149,815 B   signer CN=Android Debug                HOME categories: 1
```

> **Do not be fooled by a patched APK lying around.** If you inherit a
> `koreader.apk` from an earlier attempt it may already be the rebuilt,
> debug-signed one, and inspecting *that* will tell you the official APK has
> HOME when it does not. Check the signature, not just the manifest.

## Prepare a HOME-capable APK

You have to add the category yourself. With `apktool` and `uber-apk-signer`:

```bash
curl -sL -o koreader.apk \
  https://github.com/koreader/koreader/releases/download/v2026.07.1/koreader-android-arm-v2026.07.1.apk

java -jar apktool.jar d -f -o koreader-dec koreader.apk
```

In `koreader-dec/AndroidManifest.xml`, take `MainActivity`'s `MAIN` filter:

```xml
<intent-filter>
    <action android:name="android.intent.action.MAIN"/>
    <category android:name="android.intent.category.LAUNCHER"/>
    <category android:name="android.intent.category.LEANBACK_LAUNCHER"/>
</intent-filter>
```

and add the two categories:

```xml
    <category android:name="android.intent.category.HOME"/>
    <category android:name="android.intent.category.DEFAULT"/>
```

Then rebuild, sign, and install:

```bash
java -jar apktool.jar b koreader-dec -o koreader-home-unsigned.apk
java -jar uber-apk-signer.jar -a koreader-home-unsigned.apk --overwrite

# the debug-key signature differs from the official one, so an existing install
# must go first - this deletes KOReader's APP data, not your books
adb uninstall org.koreader.launcher
adb install koreader-home-unsigned.apk
```

Confirm the result before you rely on it:

```bash
aapt2 dump xmltree --file AndroidManifest.xml koreader-home-unsigned.apk \
  | grep -c android.intent.category.HOME        # must be >= 1, not 0
```

## Why this is a hard requirement, not a nicety

`scripts/30-debloat.sh` deletes `EPubProd.apk`, the only other app declaring
HOME. Remove it while the replacement cannot be a launcher and the device boots
to a screen with no way to start anything. So `30-debloat.sh` refuses to run
unless it can confirm that some installed launcher really declares HOME. It pulls
the installed APK and parses its manifest. `--force` overrides.

Nothing else needs to "set" the home app: with EPubProd gone, KOReader is the
sole candidate, so Android resolves HOME to it with no preference and no chooser.
A chooser only appears while *both* are installed, during the window between
installing KOReader and running the debloat.

## ⚠️ Do NOT move KOReader into `/system/app`

It is tempting: then a factory reset could not remove it. **It breaks KOReader
completely.** Its `MainActivity` is a `NativeActivity`, which loads its native
library by absolute path from `nativeLibraryDir` (on this build always
`/data/app-lib/<name>`) and never falls back to `/system/lib`. You get:

```
java.lang.RuntimeException: Unable to start activity …MainActivity
  Caused by: java.lang.IllegalArgumentException: Unable to find native library: luajit-launcher
```

Copying its five `.so` files into `/system/lib` does not help.

The full reasoning, and the evidence that this is a property of the build rather
than of KOReader, is in [`findings.md` §7](findings.md). The short version:

> Relocating an APK into `/system` is only safe for pure-Java apps. KOReader has
> native code. The USB helper does not.

## The rule about the HOME category

**Exactly one app on this device should declare HOME.** An earlier helper build
declared it, and because no default was set the device booted showing a
*"Complete action using"* chooser between KOReader and the helper. The helper's
manifest now deliberately omits the HOME category, so the USB screen never
competes with the reader.

If you add any other app, check it before installing:

```bash
aapt2 dump xmltree --file AndroidManifest.xml some.apk | grep -c category.HOME
```

## After a factory reset

KOReader lives in `/data`, so a reset removes it. Because of the patched
signature, reinstall from your **prepared** APK, not from GitHub.

Your books and KOReader's settings do not disappear. They live on the user
partition (`mmcblk0p4`, mounted `/storage/sdcard1`), which the stock recovery's
wipe does not target (`findings.md` §11), so reading position comes back with
`/storage/sdcard1/koreader/settings.reader.lua`.

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
framework settings. Nothing in this project depends on it.

## Updating KOReader later — read this before you try

Because the installed copy is debug-signed, `adb install -r` of a newer
*official* APK fails with `INSTALL_FAILED_UPDATE_INCOMPATIBLE`. Updating means
the full cycle: uninstall, prepare the new version (manifest patch + sign),
install. The uninstall takes KOReader's app data with it. Its real settings and
reading positions are on `/storage/sdcard1`, so they survive, but anything kept
in `/data/data/org.koreader.launcher` does not.
