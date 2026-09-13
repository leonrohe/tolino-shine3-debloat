#!/usr/bin/env bash
# Step 30 - remove the store/login/telemetry stack and the retail content.
#
# Requires a rooted session (scripts/20-root.sh boot).
#
# >>> BEFORE RUNNING THIS, MAKE SURE YOU HAVE ANOTHER HOME APP INSTALLED. <<<
# EPubProd.apk IS the stock launcher. Delete it with no replacement and the
# device boots to an empty screen with no way to start anything. Install
# KOReader (or any launcher) first; see docs/koreader-as-home.md.
#
# Everything here is inside /system, which you have already imaged in step 10,
# so this is reversible even if you get it wrong.
. "$(dirname "$0")/lib.sh"

ASSUME_YES=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --yes|-y) ASSUME_YES=1 ;;
    --force)  FORCE=1 ;;
    *) die "unknown option: $arg (use --yes, --force)" ;;
  esac
done

require_root
ensure_work
check_device

# ---------------------------------------------------------------------------
# what gets removed, and why
# ---------------------------------------------------------------------------
APPS=(
  "/system/app/EPubProd.apk"            # shop, login, Adobe/LCP DRM, usage metrics
  "/system/app/SystemCrashReporter.apk" # standalone crash telemetry
  "/system/app/CubeLiveWallpapers.apk"  # AOSP sample live wallpaper
  "/system/app/BasicDreams.apk"         # AOSP sample screensaver
)
DIRS=(
  "/system/media/preinstalled"          # ~41 MB retail demo/promo content, 8 languages
)
FILES=(
  "/system/etc/ota.conf"                # dead reference to a factory LAN IP
)

# ---------------------------------------------------------------------------
# guard: never leave the device without a launcher
# ---------------------------------------------------------------------------
if [ "$FORCE" != "1" ]; then
  if ! adb_ shell "pm path org.koreader.launcher" 2>/dev/null | grep -q package:; then
    if ! adb_ shell "pm list packages" 2>/dev/null | grep -qiE 'launcher|nova|apex|kiss'; then
      die "no alternative HOME app found, and EPubProd.apk is the stock launcher.
   Install one first (see docs/koreader-as-home.md), or pass --force to override."
    fi
  fi
  ok "an alternative launcher is present"
fi

step "will remove"
for f in "${APPS[@]}" "${DIRS[@]}" "${FILES[@]}"; do printf '    %s\n' "$f"; done

if [ "$ASSUME_YES" != "1" ]; then
  printf '\nProceed? [y/N] '
  read -r a
  case "$a" in y|Y) : ;; *) die "aborted" ;; esac
fi

sh_ok "mount -o remount,rw /system" || die "could not remount /system rw"
system_is_rw || die "/system is still not rw - refusing to continue"
ok "/system is rw"

step "removing"
for f in "${APPS[@]}"; do
  if sh_ok "rm -f '$f' '${f%.apk}.odex'"; then ok "removed $(basename "$f")"
  else warn "failed to remove $f"; fi
done
for d in "${DIRS[@]}"; do
  if sh_ok "rm -rf '$d'"; then ok "removed $(basename "$d")"
  else warn "failed to remove $d"; fi
done
for f in "${FILES[@]}"; do
  if sh_ok "rm -f '$f'"; then ok "removed $(basename "$f")"
  else warn "failed to remove $f"; fi
done

# ---------------------------------------------------------------------------
# blackhole the metrics / remote-config host, in case the app is ever restored
#
# Note the sh_ok: `adb shell "grep -q ..."` ALWAYS reports success on this
# adbd, which made an earlier version of this script claim "already present"
# on a freshly formatted /system. See the note in lib.sh.
# ---------------------------------------------------------------------------
HOST='nerz.clone.sda.t-online.de'
step "blackholing $HOST in /system/etc/hosts"
adb_ pull /system/etc/hosts "$WORK/hosts.orig" >/dev/null 2>&1 || true
if sh_ok "grep -q '$HOST' /system/etc/hosts"; then
  ok "already present"
else
  # `echo`, not `printf`: this device's shell has NO printf (gets "printf: not
  # found", rc=127). echo is an mksh builtin and works; `busybox printf` does
  # too if a format string is ever needed.
  sh_ok "echo '127.0.0.1 $HOST' >> /system/etc/hosts" \
    || die "could not append to /system/etc/hosts"
  sh_ok "grep -q '$HOST' /system/etc/hosts" \
    || die "hosts entry did not stick"
  ok "added and verified"
fi

# A ro remount legitimately fails with "Device or resource busy" while Android
# is running from /system, so verify the actual state instead of the exit code.
sh_ok "mount -o remount,ro /system" || true
if system_is_rw; then
  warn "/system is still mounted rw (busy). Harmless - a reboot clears it,"
  warn "and nothing is written to /system after this point."
else
  ok "/system back to ro"
fi

step "result"
adb_ shell df /system 2>/dev/null | tr -d '\r' | tail -1 | sed 's/^/    /'
cat <<'EOF'

Debloat complete. Remaining caveats:
  * MOUNT_UNMOUNT_FILESYSTEMS is still signature|system, so USB mass storage
    is now dead - run 31-patch-framework.sh and 40-install-ums-helper.sh.
  * Reboot to let PackageManager forget the removed packages.
EOF
