#!/usr/bin/env bash
# Step 31 - make MOUNT_UNMOUNT_FILESYSTEMS grantable, by patching framework-res.apk.
#
# WHY THIS IS NEEDED
#   Our USB helper needs android.permission.MOUNT_UNMOUNT_FILESYSTEMS, which is
#   declared protectionLevel="signature|system". This build's grant logic does
#   NOT honour the `system` flag:
#
#     W/PackageManager: Not granting permission
#       android.permission.MOUNT_UNMOUNT_FILESYSTEMS to package
#       org.tolino.umshelper (protectionLevel=18 flags=0x8be45)
#
#   protectionLevel is a bitfield: 0x12 = signature(0x2)|system(0x10). Dropping
#   it to 0 makes the permission `normal`, i.e. granted to anyone who asks.
#
#   SECURITY TRADE-OFF, stated plainly: after this change ANY app on the reader
#   can request MOUNT_UNMOUNT_FILESYSTEMS. On a single-purpose, sideload-only
#   e-reader that is judged acceptable; on a general-purpose device it would not
#   be.
#
# WHY THE TIMESTAMP MATTERS (the part that makes this work at all)
#   We change AndroidManifest.xml inside a *signed* APK, so its JAR signature
#   goes stale. KitKat's PackageManagerService.collectCertificatesLI() reuses
#   the signatures cached in /data/system/packages.xml WITHOUT re-verifying,
#   provided the file's lastModified() still matches the cached timestamp:
#
#       codePath.equals(...) && timeStamp == lastModified() && signatures != null
#
#   So we restore the original mtime after pushing. Change it and PMS re-verifies,
#   the stale signature fails, and you get a broken framework.
#
# The patch is deterministic: stock bfe142cacab7214b7abf312d43f3758d always
# produces f2aaeee092d30e8628214b300acc8798. This script refuses to run on an
# input it does not recognise, and refuses to install an output it cannot verify.
. "$(dirname "$0")/lib.sh"

STOCK_MD5='bfe142cacab7214b7abf312d43f3758d'
PATCHED_MD5='f2aaeee092d30e8628214b300acc8798'
PERM='android.permission.MOUNT_UNMOUNT_FILESYSTEMS'

ORIG="$WORK/framework-res.orig.apk"
PATCHED="$WORK/framework-res.patched.apk"

require_root
ensure_work
check_device
need_cmd python3

revert_mode=0
[ "${1:-}" = "--revert" ] && revert_mode=1

if [ ! -f "$ORIG" ]; then
  info "pulling the stock framework-res.apk (first run)"
  adb_ pull /system/framework/framework-res.apk "$ORIG" >/dev/null || die "pull failed"
fi

got="$(md5sum "$ORIG" | awk '{print $1}')"
info "stock framework-res.apk md5 $got"
if [ "$got" != "$STOCK_MD5" ]; then
  if [ "$got" = "$PATCHED_MD5" ]; then
    warn "the device already carries the PATCHED framework-res.apk"
  else
    die "unrecognised framework-res.apk ($got).
   Expected $STOCK_MD5. This script is written for one specific firmware
   (16.2.0 / build 157800); patching a different one blindly is how you brick
   a device. Verify your firmware, or update the hashes deliberately."
  fi
fi

# ---------------------------------------------------------------------------
# build the patched APK (locally, deterministically)
# ---------------------------------------------------------------------------
if [ "$revert_mode" = "1" ]; then
  INSTALL="$ORIG"
  info "REVERT mode - will reinstall the stock framework-res.apk"
else
  step "building the patched APK"
  T="$WORK/fwpatch"; rm -rf "$T"; mkdir -p "$T"
  unzip -o -q "$ORIG" AndroidManifest.xml -d "$T" || die "no AndroidManifest.xml in the APK"
  python3 "$REPO_ROOT/framework-patch/patch-axml.py" \
      "$T/AndroidManifest.xml" "$T/AndroidManifest.patched.xml" \
      permission name "$PERM" protectionLevel 0 || die "AXML patch failed"
  python3 "$REPO_ROOT/framework-patch/repack-apk.py" \
      "$ORIG" "$PATCHED" "$T/AndroidManifest.patched.xml" || die "repack failed"

  out="$(md5sum "$PATCHED" | awk '{print $1}')"
  [ "$out" = "$PATCHED_MD5" ] \
    || die "patched APK md5 $out != expected $PATCHED_MD5 - refusing to install"
  ok "patched APK verified: $out ($(stat -c%s "$PATCHED") bytes)"
  INSTALL="$PATCHED"
fi

# ---------------------------------------------------------------------------
# install in place, preserving the timestamp
# ---------------------------------------------------------------------------
step "installing"
adb_ shell "mount -o remount,rw /system" || die "could not remount /system rw"

# Keep a copy on /cache with its timestamps, so we can restore the original
# mtime after overwriting the file. `cp -p` preserves it.
adb_ shell "cp -p /system/framework/framework-res.apk /cache/fwres.mtime-ref"
before="$(adb_ shell "ls -l --time-style=+%Y-%m-%dT%H:%M:%S /system/framework/framework-res.apk" | tr -d '\r' | awk '{print $6}')"
info "original mtime: $before"

adb_ push "$INSTALL" /system/framework/framework-res.apk >/dev/null || die "push failed"
adb_ shell "chown 0:0 /system/framework/framework-res.apk; chmod 644 /system/framework/framework-res.apk"
adb_ shell "busybox touch -r /cache/fwres.mtime-ref /system/framework/framework-res.apk" \
  || die "could not restore the mtime - aborting before reboot (PMS would re-verify the signature)"

after="$(adb_ shell "ls -l --time-style=+%Y-%m-%dT%H:%M:%S /system/framework/framework-res.apk" | tr -d '\r' | awk '{print $6}')"
[ "$before" = "$after" ] || die "mtime changed ($before -> $after). Signature cache will miss."
ok "mtime preserved: $after"

dev_md5="$(adb_ shell "md5 /system/framework/framework-res.apk" | tr -d '\r' | awk '{print $1}')"
ok "on-device md5: $dev_md5"

adb_ shell "rm -f /cache/fwres.mtime-ref"
adb_ shell "mount -o remount,ro /system" && ok "/system back to ro"

cat <<EOF

Framework patch installed.

  now:   $dev_md5
  stock: $STOCK_MD5   (scripts/31-patch-framework.sh --revert restores this)

REBOOT for PackageManager to pick it up. After the reboot, check that the
permission really is grantable:

  adb shell dumpsys package org.tolino.umshelper | grep -A3 grantedPermissions

Note: /system/app/*.odex files will be regenerated on first boot; that is normal.
EOF
