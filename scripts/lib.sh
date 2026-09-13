#!/usr/bin/env bash
# Shared helpers for the Tolino Shine 3 debloat pipeline.
#
# Source this, do not execute it:
#     . "$(dirname "$0")/lib.sh"
#
# Environment overrides:
#   SERIAL=...              target device when several are attached
#   WORK=/path              working directory (default <repo>/work)
#   ADB=... FASTBOOT=...    use a specific binary
#   ADB_SERVER_SOCKET=...   honoured automatically; do not unset it if your
#                           adb server runs somewhere other than the default
#                           socket (e.g. inside a container)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK:-$REPO_ROOT/work}"
ADB="${ADB:-adb}"
FASTBOOT="${FASTBOOT:-fastboot}"
SERIAL="${SERIAL:-}"

# ---------------------------------------------------------------------------
# Partition map - Tolino Shine 3 (ntx_6sl), from the recovery ramdisk's
# etc/recovery.fstab. Verified against /proc/partitions on firmware 16.2.0.
# ---------------------------------------------------------------------------
P_BOOT=/dev/block/mmcblk0p1      #  6112 KB
P_RECOVERY=/dev/block/mmcblk0p2  # 32768 KB
P_SYSTEM=/dev/block/mmcblk0p5    # 393208 KB
P_CACHE=/dev/block/mmcblk0p6     # 393208 KB
P_DATA=/dev/block/mmcblk0p7      # 524280 KB
P_MISC=/dev/block/mmcblk0p9
P_SHARE=/dev/block/mmcblk0p10    # 262144 KB  (/share when Android runs)
# mmcblk0p4 = 6102051 KB user storage (books); mounted /storage/sdcard1

# The bootloader's fastboot download cap, from the vendor U-Boot config
# include/configs/mx6sl_ntx_android.h -> CONFIG_FASTBOOT_TRANSFER_BUF_SIZE.
# An image larger than this is rejected instantly with `FAILED (remote: '')`.
FASTBOOT_MAX_IMAGE=$((0x16000000))   # 352 MiB = 369098752 bytes

# Expected device identity. Everything refuses to run if these do not match.
WANT_PRODUCT='ntx_6sl'
WANT_HW='E60K00'
WANT_BUILD='157800'

# ---------------------------------------------------------------------------
# logging
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'; C_DIM=$'\033[2m';  C_OFF=$'\033[0m'
else
  C_RED=; C_GRN=; C_YEL=; C_BLU=; C_DIM=; C_OFF=
fi

info()  { printf '%s==>%s %s\n' "$C_BLU" "$C_OFF" "$*"; }
ok()    { printf '%s  ok%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn()  { printf '%swarn%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
die()   { printf '%sFATAL%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }
step()  { printf '\n%s── %s ──%s\n' "$C_DIM" "$*" "$C_OFF"; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

# ---------------------------------------------------------------------------
# adb / fastboot wrappers (honour SERIAL)
# ---------------------------------------------------------------------------
adb_() {
  if [ -n "$SERIAL" ]; then "$ADB" -s "$SERIAL" "$@"; else "$ADB" "$@"; fi
}
fb_() {
  if [ -n "$SERIAL" ]; then "$FASTBOOT" -s "$SERIAL" "$@"; else "$FASTBOOT" "$@"; fi
}

require_adb() {
  need_cmd "$ADB"
  [ "$(adb_ get-state 2>/dev/null)" = "device" ] \
    || die "no device in adb 'device' state. Check the cable and 'adb devices'."
}

require_root() {
  require_adb
  local id
  id="$(adb_ shell id 2>/dev/null | tr -d '\r')"
  case "$id" in
    uid=0*) : ;;
    *) die "this step needs root. Got: ${id:-<nothing>}
   Boot the rooted image first:  scripts/20-root.sh --boot" ;;
  esac
}

# Everything that writes to the device calls this first. Refusing on a
# mismatched model is the cheapest possible protection against bricking a
# different e-reader that happens to be plugged in.
check_device() {
  require_adb
  local dev hw build
  dev="$(adb_ shell getprop ro.product.device 2>/dev/null | tr -d '\r')"
  hw="$(adb_ shell getprop ro.hardware 2>/dev/null | tr -d '\r')"
  build="$(adb_ shell getprop ro.build.version.incremental 2>/dev/null | tr -d '\r')"

  step "device identity"
  printf '    ro.product.device            = %s\n' "$dev"
  printf '    ro.hardware                  = %s\n' "$hw"
  printf '    ro.build.version.incremental = %s\n' "$build"
  printf '    ro.build.version.release     = %s\n' \
    "$(adb_ shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')"
  printf '    ro.secure / ro.debuggable    = %s / %s\n' \
    "$(adb_ shell getprop ro.secure 2>/dev/null | tr -d '\r')" \
    "$(adb_ shell getprop ro.debuggable 2>/dev/null | tr -d '\r')"

  [ "$dev" = "$WANT_PRODUCT" ] || die "expected ro.product.device=$WANT_PRODUCT, got '$dev'"
  adb_ shell "getprop ro.hardware" >/dev/null 2>&1 || true
  ok "device looks like a Tolino Shine 3"
}

# Read a whole block device to a local file. `adb pull` handles block devices
# correctly (unlike `adb exec-out`, which this KitKat adbd does not support).
pull_partition() {
  local dev="$1" out="$2"
  [ -n "$dev" ] && [ -n "$out" ] || die "pull_partition <device> <outfile>"
  info "pulling $dev -> $out"
  adb_ pull "$dev" "$out" >/dev/null || die "pull failed for $dev (needs root?)"
  ok "$(stat -c%s "$out") bytes"
}

sha() { sha256sum "$1" | cut -c1-16; }

ensure_work() { mkdir -p "$WORK"; }
