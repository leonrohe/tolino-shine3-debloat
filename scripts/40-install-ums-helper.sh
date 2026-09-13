#!/usr/bin/env bash
# Step 40 - build and install the USB mass-storage helper into /system/app.
#
# WHY THIS EXISTS
#   de.telekom.epub was what called setUsbMassStorageEnabled(true) when the
#   cable was plugged in. With it gone the gadget still advertises
#   `mass_storage`, but nothing ever shares a volume, so the PC sees a 0-byte
#   drive. MTP is not an option on this ROM: the framework knows only
#   audio_source, mass_storage and rndis and ships no MtpService at all.
#
# TWO TRAPS THIS SCRIPT EXISTS TO AVOID
#
#   1. The /data/app trap. Because the base package is a *system* app, PMS lets
#      any same-signature update with a STRICTLY HIGHER versionCode install to
#      /data/app with no privileges at all. That is convenient for iterating and
#      silently wrong for durability: `pm path` then points at /data/app, and a
#      factory reset reverts to whatever stale build is in /system/app. So we
#      delete the /data copy and verify.
#
#   2. The odex trap. KitKat decides whether a cached dex is current from the
#      APK's mtime and size - and `adb push` carries the BUILD MACHINE's mtime.
#      Replace a system APK and the old
#      /data/dalvik-cache/system@app@<Name>.apk@classes.dex can keep running.
#      Symptom: versionCode reads correctly, behaviour is stale. Delete it.
. "$(dirname "$0")/lib.sh"

PKG='org.tolino.umshelper'
SYSTEM_APK='/system/app/UmsHelper.apk'
APK="${1:-$REPO_ROOT/ums-helper/umshelper.apk}"

require_root
ensure_work
check_device

# ---------------------------------------------------------------------------
# build
# ---------------------------------------------------------------------------
if [ "$APK" = "$REPO_ROOT/ums-helper/umshelper.apk" ] && [ "${SKIP_BUILD:-0}" != "1" ]; then
  step "building the helper"
  SDK="${SDK:-$HOME/Android/Sdk}" "$REPO_ROOT/ums-helper/build.sh" || die "helper build failed"
fi
[ -f "$APK" ] || die "no APK at $APK"

need_cmd unzip
V="$(unzip -p "$APK" AndroidManifest.xml >/dev/null 2>&1 && echo ok)"
info "installing $APK ($(stat -c%s "$APK") bytes)"
[ "$V" = ok ] || die "that file does not look like an APK"

# ---------------------------------------------------------------------------
# install into /system/app
# ---------------------------------------------------------------------------
step "installing into /system/app"
adb_ shell "mount -o remount,rw /system" || die "could not remount /system rw"
adb_ push "$APK" "$SYSTEM_APK" >/dev/null || die "push failed"
adb_ shell "chown 0:0 '$SYSTEM_APK'; chmod 644 '$SYSTEM_APK'"
ok "pushed to $SYSTEM_APK"

step "removing any /data/app update (the durability trap)"
if adb_ shell "ls /data/app/ | grep -i umshelper" 2>/dev/null | grep -q .; then
  adb_ shell "rm -f /data/app/org.tolino.umshelper-*.apk"
  adb_ shell "rm -rf /data/app/org.tolino.umshelper-* /data/app-lib/org.tolino.umshelper-*"
  ok "removed the /data/app copy"
else
  ok "none present"
fi

step "clearing the stale odex (the mtime trap)"
if adb_ shell "ls /data/dalvik-cache/ 2>/dev/null | grep -i umshelper" | grep -q .; then
  adb_ shell "rm -f /data/dalvik-cache/*umshelper*"
  ok "deleted; it will be regenerated at boot from the new APK"
else
  ok "none present"
fi

adb_ shell "mount -o remount,ro /system" && ok "/system back to ro"

# ---------------------------------------------------------------------------
# what must be true after the next boot
# ---------------------------------------------------------------------------
cat <<EOF

Installed. Now REBOOT and verify all three:

  adb reboot && sleep 45

  # 1. it must resolve to /system/app, not /data/app
  adb shell pm path $PKG
      -> package:/system/app/UmsHelper.apk

  # 2. the permission must actually be granted
  adb shell dumpsys package $PKG | grep -A3 grantedPermissions
      -> android.permission.MOUNT_UNMOUNT_FILESYSTEMS
         android.permission.KILL_BACKGROUND_PROCESSES

  # 3. plug in the cable: the reader should show its USB screen and the
  #    volume should appear on the PC.

If step 2 is empty, the framework patch (31) did not take - see
docs/troubleshooting.md.
EOF
