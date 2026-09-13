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

adb_ shell "mount -o remount,rw /system" || die "could not remount /system rw"
ok "/system is rw"

step "removing"
for f in "${APPS[@]}"; do
  adb_ shell "rm -f '$f' '${f%.apk}.odex'"    && ok "removed $(basename "$f")"
done
for d in "${DIRS[@]}"; do
  adb_ shell "rm -rf '$d'"                     && ok "removed $(basename "$d")"
done
for f in "${FILES[@]}"; do
  adb_ shell "rm -f '$f'"                      && ok "removed $(basename "$f")"
done

# ---------------------------------------------------------------------------
# blackhole the metrics / remote-config host, in case the app is ever restored
# ---------------------------------------------------------------------------
HOST='nerz.clone.sda.t-online.de'
step "blackholing $HOST in /system/etc/hosts"
adb_ pull /system/etc/hosts "$WORK/hosts.orig" >/dev/null 2>&1 || true
if adb_ shell "grep -q '$HOST' /system/etc/hosts" 2>/dev/null; then
  ok "already present"
else
  adb_ shell "printf '127.0.0.1 %s\n' '$HOST' >> /system/etc/hosts"
  ok "added"
fi

adb_ shell "mount -o remount,ro /system" && ok "/system back to ro"

step "result"
adb_ shell df /system 2>/dev/null | tr -d '\r' | tail -1 | sed 's/^/    /'
cat <<'EOF'

Debloat complete. Remaining caveats:
  * MOUNT_UNMOUNT_FILESYSTEMS is still signature|system, so USB mass storage
    is now dead - run 31-patch-framework.sh and 40-install-ums-helper.sh.
  * Reboot to let PackageManager forget the removed packages.
EOF
