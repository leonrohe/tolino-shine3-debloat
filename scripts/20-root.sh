#!/usr/bin/env bash
# Step 20 - obtain root, WITHOUT writing anything to the device.
#
# Root here is `fastboot boot` of a patched boot image: the image is loaded
# into RAM and discarded on the next reboot. The boot partition is never
# written, so this is non-destructive and fully reversible. Nothing in this
# repo requires a permanent root.
#
# The stock boot.img comes from the official firmware - you cannot read your
# own boot partition without root yet, so extract it from the update.zip:
#
#     scripts/20-root.sh extract  ~/Downloads/update.zip     # -> work/stock-boot.img
#     scripts/20-root.sh build                               # -> work/rooted-boot.img
#     scripts/20-root.sh boot                                # RAM-boot it, wait for root
#
# THE TIMING MATTERS. The bootloader only listens for a fastboot command for
# about 5 seconds after it enters fastboot mode. So we always START the
# fastboot command first (it prints "< waiting for any device >") and only
# then trigger the device. Do not reorder this.
. "$(dirname "$0")/lib.sh"

ensure_work
STOCK="$WORK/stock-boot.img"
ROOTED="$WORK/rooted-boot.img"

cmd_extract() {
  local zip="${1:?usage: $0 extract <official-update.zip>}"
  need_cmd unzip
  [ -f "$zip" ] || die "no such file: $zip"
  info "extracting boot.img from $zip"
  unzip -p "$zip" boot.img > "$STOCK" || die "boot.img not found inside $zip"
  ok "wrote $STOCK ($(stat -c%s "$STOCK") bytes, sha256 $(sha "$STOCK"))"
}

cmd_build() {
  need_cmd python3
  [ -f "$STOCK" ] || die "no $STOCK - run '$0 extract <update.zip>' first"
  info "building rooted image from $STOCK"
  "$REPO_ROOT/root/build-rooted-boot.sh" "$STOCK" "$ROOTED"
  ok "rooted image ready: $ROOTED (sha256 $(sha "$ROOTED"))"
}

# Poll adb until it reports a root shell. adbd lives in the ramdisk, so it
# comes back even if the Android framework fails to start.
wait_for_root() {
  local i
  info "waiting for root adb shell (the RAM boot takes 30-60 s)..."
  for i in $(seq 1 60); do
    if [ "$(adb_ get-state 2>/dev/null)" = "device" ]; then
      local id
      id="$(adb_ shell id 2>/dev/null | tr -d '\r')"
      case "$id" in
        uid=0*) ok "root shell up: $id"; return 0 ;;
      esac
    fi
    printf '.'
    sleep 3
  done
  echo
  die "no root shell after 3 minutes. See docs/troubleshooting.md"
}

cmd_boot() {
  need_cmd "$FASTBOOT"
  local img="${1:-$ROOTED}"
  [ -f "$img" ] || die "no such image: $img (run '$0 build' first)"

  # Start the fastboot command BEFORE the device enters fastboot mode.
  info "arming fastboot with $img"
  ( fb_ boot "$img" >"$WORK/fastboot-boot.log" 2>&1 ; echo $? > "$WORK/fastboot-boot.rc" ) &
  local fbpid=$!
  sleep 1

  if [ "$(adb_ get-state 2>/dev/null)" = "device" ]; then
    info "Android is running - rebooting into fastboot"
    adb_ reboot fastboot >/dev/null 2>&1 || true
  else
    cat <<'EOF'

  Android is not reachable, so enter fastboot by hand - the image is already
  waiting for it:

    1. power the reader fully OFF
    2. connect USB
    3. hold POWER continuously for ~30 seconds

  The reader must be given to fastboot within ~5 s of appearing.

EOF
  fi

  # The fastboot client exits as soon as the boot command is accepted.
  local rc=1
  for _ in $(seq 1 90); do
    if ! kill -0 "$fbpid" 2>/dev/null; then
      rc="$(cat "$WORK/fastboot-boot.rc" 2>/dev/null || echo 1)"
      break
    fi
    sleep 1
  done
  sed 's/^/    /' "$WORK/fastboot-boot.log" 2>/dev/null || true
  [ "$rc" = "0" ] || die "fastboot boot failed (rc=$rc). See docs/troubleshooting.md"

  wait_for_root
  check_device
}

case "${1:-}" in
  extract) shift; cmd_extract "$@" ;;
  build)   shift; cmd_build   "$@" ;;
  boot)    shift; cmd_boot    "$@" ;;
  ""|--help|-h)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *) die "unknown command: $1 (try --help)" ;;
esac
