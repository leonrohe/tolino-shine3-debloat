#!/usr/bin/env bash
# Step 0 - confirm we are talking to the right device, and report what is there.
#
# Run this FIRST, every session. Every other script refuses to touch a device
# whose ro.product.device is not ntx_6sl.
. "$(dirname "$0")/lib.sh"

check_device

step "storage"
adb_ shell df 2>/dev/null | tr -d '\r' | grep -vE 'tmpfs|Filesystem' || true

step "existing modifications"
for f in /system/app/EPubProd.apk /system/app/SystemCrashReporter.apk \
         /system/media/preinstalled /system/app/UmsHelper.apk; do
  printf '    %-40s ' "$(basename "$f")"
  adb_ shell "ls -d $f 2>/dev/null || echo absent" | tr -d '\r'
done
printf '    %-40s ' "KOReader"
adb_ shell "pm path org.koreader.launcher 2>/dev/null || echo absent" | tr -d '\r'

step "recovery payload on /share (needed to go back to stock)"
adb_ shell "ls -la /share/orig_update.zip 2>/dev/null || echo 'NOT PRESENT'" | tr -d '\r'

ok "device check complete"
