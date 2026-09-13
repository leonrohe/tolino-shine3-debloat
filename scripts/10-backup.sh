#!/usr/bin/env bash
# Step 10 - back up the partitions we are about to modify.
#
# Requires a ROOTED session (scripts/20-root.sh --boot), which is RAM-only and
# writes nothing - so the correct order is: boot rooted image, back up, then
# modify. Backing up is what makes everything afterwards reversible.
#
# `adb pull` reads block devices fine. `adb exec-out` does NOT work against the
# KitKat adbd in this firmware - it fails with `error: closed` - so do not
# "fix" this by switching to exec-out.
. "$(dirname "$0")/lib.sh"

require_root
ensure_work
check_device

DEST="${1:-$WORK/backups}"
mkdir -p "$DEST"

step "backing up (this takes ~2 minutes for /system at ~3.5 MB/s)"
pull_partition "$P_BOOT"   "$DEST/boot-partition-p1.img"
pull_partition "$P_SYSTEM" "$DEST/system-partition-p5.img"

step "validating"
if command -v dumpe2fs >/dev/null 2>&1; then
  if dumpe2fs -h "$DEST/system-partition-p5.img" >/dev/null 2>&1; then
    ok "system image parses as ext4"
    dumpe2fs -h "$DEST/system-partition-p5.img" 2>/dev/null \
      | grep -E '^Filesystem state|^Block count|^Free blocks' | sed 's/^/    /'
  else
    die "system image does not parse as ext4 - the pull was incomplete"
  fi
else
  warn "dumpe2fs not installed (e2fsprogs) - skipping ext4 validation"
fi

# The boot partition is 6,258,688 bytes but the boot.img inside it is smaller;
# record the hash of the whole partition so restores can be verified exactly.
step "hashes"
( cd "$DEST" && sha256sum ./*.img | tee SHA256SUMS ) | sed 's/^/    /'

cat <<EOF

Backup complete -> $DEST

  boot   $(sha "$DEST/boot-partition-p1.img")
  system $(sha "$DEST/system-partition-p5.img")

Keep this somewhere that is NOT the device. To restore, see docs/backup-restore.md.
EOF
