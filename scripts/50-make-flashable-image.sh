#!/usr/bin/env bash
# Step 50 - turn a raw /system image into one the bootloader will accept.
#
# THE PROBLEM
#   The vendor U-Boot caps a single fastboot download:
#
#     include/configs/mx6sl_ntx_android.h
#     #define CONFIG_FASTBOOT_TRANSFER_BUF_SIZE 0x16000000 /* 352M byte */
#
#     drivers/fastboot/fastboot.c:1086
#     if (g_fastboot_datalen > CONFIG_FASTBOOT_TRANSFER_BUF_SIZE) {
#             DBG_ERR("Download too much data"); ... sends "FAIL"
#
#   A full 384 MiB /system image is 32 MiB over, and gets rejected instantly
#   with `Sending 'system' ... FAILED (remote: '')` - before any transfer.
#   There is NO sparse-image support in this U-Boot either, so do not try to
#   sneak a sparse image past it: it would be written raw and destroy /system.
#
# THE FIX
#   /system only *uses* ~298 MB, so shrink the filesystem to fit. A filesystem
#   smaller than its partition is perfectly legal; the tail is simply unused.
#
#   Order matters. resize2fs refuses to run without a preceding e2fsck, and
#   growing the filesystem back leaves the resize inode's i_size stale, so a
#   second e2fsck is required or `e2fsck -fn` reports "still has errors" and
#   you would be flashing a dirty filesystem.
#
# Usage:
#   scripts/50-make-flashable-image.sh <raw-system.img> [out.img] [--blocks N]
. "$(dirname "$0")/lib.sh"

need_cmd resize2fs
need_cmd e2fsck
need_cmd dumpe2fs

SRC="${1:?usage: $0 <raw-system.img> [out.img] [--blocks N]}"
OUT="${2:-${1%.img}-FLASHABLE.img}"
BLOCKS=""
[ "${3:-}" = "--blocks" ] && BLOCKS="${4:?--blocks needs a value}"
[ -f "$SRC" ] || die "no such file: $SRC"

BLOCK_SIZE="$(dumpe2fs -h "$SRC" 2>/dev/null | awk '/^Block size/{print $3}')"
TOTAL="$(dumpe2fs -h "$SRC" 2>/dev/null | awk '/^Block count/{print $3}')"
FREE="$(dumpe2fs -h "$SRC" 2>/dev/null | awk '/^Free blocks/{print $3}')"
[ -n "$BLOCK_SIZE" ] || die "$SRC does not look like an ext4 filesystem"

USED=$((TOTAL - FREE))
MARGIN=$((8 * 1024 * 1024))                     # stay clear of the exact cap
MAXBLOCKS=$(( (FASTBOOT_MAX_IMAGE - MARGIN) / BLOCK_SIZE ))

step "source image"
printf '    size        %s bytes (%s MiB)\n' "$(stat -c%s "$SRC")" "$(( $(stat -c%s "$SRC") / 1048576 ))"
printf '    block size  %s\n' "$BLOCK_SIZE"
printf '    blocks      %s total, %s used, %s free\n' "$TOTAL" "$USED" "$FREE"
printf '    free space  %s MiB\n' "$(( FREE * BLOCK_SIZE / 1048576 ))"

step "fastboot limit"
printf '    cap         %s bytes (%s MiB)\n' "$FASTBOOT_MAX_IMAGE" "$(( FASTBOOT_MAX_IMAGE / 1048576 ))"
printf '    max blocks  %s (with 8 MiB margin)\n' "$MAXBLOCKS"

if [ -z "$BLOCKS" ]; then
  if [ "$TOTAL" -le "$MAXBLOCKS" ]; then
    BLOCKS="$TOTAL"
    info "the source already fits; no shrinking needed"
  else
    BLOCKS="$MAXBLOCKS"
  fi
fi
TARGET=$(( BLOCKS * BLOCK_SIZE ))
[ "$TARGET" -lt "$FASTBOOT_MAX_IMAGE" ] \
  || die "target $TARGET bytes is not under the cap ($FASTBOOT_MAX_IMAGE)"
NEWFREE=$(( BLOCKS - USED ))
[ "$NEWFREE" -gt 0 ] || die "target is smaller than the used space ($USED blocks)"

step "target"
printf '    blocks      %s\n' "$BLOCKS"
printf '    size        %s bytes (%s MiB)\n' "$TARGET" "$(( TARGET / 1048576 ))"
printf '    free space  %s MiB\n' "$(( NEWFREE * BLOCK_SIZE / 1048576 ))"

cp "$SRC" "$OUT"
info "e2fsck (required before resize2fs)"
e2fsck -f -y "$OUT" >/dev/null 2>&1 || true
info "resize2fs -> $BLOCKS blocks"
resize2fs "$OUT" "$BLOCKS" >/dev/null 2>&1 || die "resize2fs failed"
# Without this truncate the FILE stays at its original size and is still
# rejected by the bootloader, even though the filesystem shrank.
truncate -s "$TARGET" "$OUT" || die "truncate failed"
info "e2fsck again (fixes the resize inode left behind)"
e2fsck -f -y "$OUT" >/dev/null 2>&1 || true

step "validate"
e2fsck -fn "$OUT" 2>&1 | grep -qi 'WARNING' \
  && die "filesystem still reports errors - do NOT flash this" \
  || ok "e2fsck -fn clean"
[ "$(stat -c%s "$OUT")" -eq "$TARGET" ] || die "file size != filesystem size"
ok "file size matches filesystem size"
dumpe2fs -h "$OUT" 2>/dev/null | grep -E '^Filesystem state|^Block count|^Free blocks' | sed 's/^/    /'

step "result"
printf '    %s\n' "$OUT"
printf '    sha256 %s\n' "$(sha256sum "$OUT" | awk '{print $1}')"
printf '    flash with: fastboot flash system %s\n' "$(basename "$OUT")"
