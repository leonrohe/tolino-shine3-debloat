#!/usr/bin/env bash
#
# Build a root-ADB boot image for the Tolino Shine 3 (ntx_6sl) from the STOCK
# firmware boot image, changing the absolute minimum.
#
# Two changes, both inside the ramdisk:
#
#  1. sbin/adbd — two NOP patches. The vendor built adbd WITHOUT
#     ALLOW_ADBD_ROOT, so ro.debuggable/ro.secure alone are NOT enough: adbd
#     unconditionally drops privileges. NOP out
#        (a) the setgroups/setgid/setuid block          (24 bytes -> 12 NOPs)
#        (b) prctl(PR_CAPBSET_DROP)                     ( 4 bytes ->  2 NOPs)
#     This reproduces, byte-for-byte, the patched adbd shipped in the
#     ALLESebook community root image (md5 98bbfe2462b221eedb944f72315df789).
#     The stock adbd is identical from 14.1.0 through 16.2.0, so the same
#     patch applies to our 16.2.0 binary (md5 1d23e203eba05102e6cb642a117b8d64).
#
#  2. default.prop — the same properties the community image uses.
#
# The KERNEL is copied through byte-for-byte. This matters: the Shine 3 shipped
# with at least three different touch controllers (Cypress cyttsp5_mt, STMicro
# fts, Elan) and their drivers are built INTO the kernel, not modules — so a
# mismatched kernel is exactly what kills the touchscreen.
#
# Always `fastboot boot` (RAM only) before ever considering `fastboot flash`.
#
# Usage:  ./build-rooted-boot.sh stock-boot.img rooted-boot.img
#
set -euo pipefail

STOCK="${1:?usage: $0 <stock-boot.img> <out.img>}"
OUT="${2:?usage: $0 <stock-boot.img> <out.img>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ADBD_STOCK_MD5='1d23e203eba05102e6cb642a117b8d64'
ADBD_PATCHED_MD5='98bbfe2462b221eedb944f72315df789'

echo "== 1. split stock boot image =="
python3 - "$STOCK" "$WORK" <<'PY'
import struct, gzip, sys
src, work = sys.argv[1], sys.argv[2]
d = open(src,'rb').read()
assert d[:8] == b'ANDROID!', 'not an Android boot image'
u = lambda o: struct.unpack_from('<I', d, o)[0]
ks, rs, ps = u(8), u(16), u(36)
pg = lambda n: (n + ps - 1)//ps*ps
open(work+'/kernel','wb').write(d[ps:ps+ks])
rd = d[ps+pg(ks):ps+pg(ks)+rs]
if rd[:2] != b'\x1f\x8b':
    raise SystemExit('ramdisk is not gzip-compressed - adapt this script')
open(work+'/ramdisk.cpio','wb').write(gzip.decompress(rd))
print(f'  kernel {ks} bytes, ramdisk {rs} bytes (gzip) -> cpio')
PY

echo "== 2. unpack ramdisk =="
mkdir -p "$WORK/rd"
( cd "$WORK/rd" && umask 000 && cpio -idm --no-absolute-filenames < "$WORK/ramdisk.cpio" >/dev/null 2>&1 )
echo "  $(find "$WORK/rd" -mindepth 1 | wc -l) entries"

echo "== 3. patch sbin/adbd =="
python3 - "$WORK" "$ADBD_STOCK_MD5" "$ADBD_PATCHED_MD5" <<'PY'
import hashlib, sys
work, want_stock, want_patched = sys.argv[1], sys.argv[2], sys.argv[3]
path = work + '/rd/sbin/adbd'
d = bytearray(open(path,'rb').read())
got = hashlib.md5(bytes(d)).hexdigest()
print(f'  stock adbd md5 {got}')
if got != want_stock:
    raise SystemExit(f'FATAL: unexpected stock adbd (want {want_stock}) - refusing to guess')
NOP2 = b'\x00\xbf'   # ARM Thumb NOP
for label, pat in (('setgroups/setgid/setuid', bytes.fromhex('4ff4fa600ef086ed0028dfd14ff4fa6016f047f80028d9d1')),
                   ('prctl(PR_CAPBSET_DROP)',  bytes.fromhex('0ef0deed'))):
    i = d.find(pat)
    if i < 0 or d.find(pat, i+1) >= 0:
        raise SystemExit(f'FATAL: pattern for {label} not found exactly once')
    d[i:i+len(pat)] = NOP2 * (len(pat)//2)
    print(f'  NOPed {label:26} at 0x{i:x} ({len(pat)//2} NOPs)')
open(path,'wb').write(bytes(d))
out = hashlib.md5(bytes(d)).hexdigest()
print(f'  patched adbd md5 {out}')
if out != want_patched:
    raise SystemExit(f'FATAL: patched adbd does not match the known-good binary ({want_patched})')
print('  == matches the community image\'s proven patched adbd exactly ==')
PY

echo "== 4. patch default.prop =="
# ro.secure/ro.debuggable are now belt-and-braces (the adbd patch is what does
# the work), but they match the community image so we keep the recipe identical.
sed -i \
  -e 's/^ro\.secure=1$/ro.secure=0/' \
  -e 's/^ro\.debuggable=0$/ro.debuggable=1/' \
  "$WORK/rd/default.prop"
grep -q '^persist\.service\.adb\.enable=' "$WORK/rd/default.prop" || \
  printf 'persist.service.adb.enable=1\n' >> "$WORK/rd/default.prop"
grep -q '^persist\.sys\.usb\.config=' "$WORK/rd/default.prop" && \
  sed -i 's/^persist\.sys\.usb\.config=mass_storage$/persist.sys.usb.config=mass_storage,adb/' "$WORK/rd/default.prop"

for want in '^ro\.secure=0$' '^ro\.debuggable=1$' '^persist\.service\.adb\.enable=1$' '^persist\.sys\.usb\.config=mass_storage,adb$'; do
  grep -q "$want" "$WORK/rd/default.prop" || { echo "FATAL: default.prop missing $want"; exit 1; }
done
sed 's/^/    /' "$WORK/rd/default.prop"

echo "== 5. repack ramdisk (root:root, newc) and restore symlink modes =="
( cd "$WORK/rd" && find . -mindepth 1 | LC_ALL=C sort | cpio -o -H newc --owner=root:root --reproducible 2>/dev/null | gzip -9 > "$WORK/ramdisk-new.gz" )
python3 - "$WORK" <<'PY'
# Two normalisations, both against the STOCK cpio, so that the only remaining
# differences are the two files we intended to change:
#
#  1. GNU cpio cannot record a symlink mode other than 0777 (Linux reports lstat
#     mode 0777 for symlinks); the stock ramdisk uses 0750. Restore the stock
#     value.
#  2. Restore the stock mtime. This is what makes the build REPRODUCIBLE:
#     python rewrites sbin/adbd and `sed -i` rewrites default.prop, so both get
#     the CURRENT time, which lands in the cpio header and changes on every
#     build (and shifts the whole gzip stream with it). Normalising to the
#     stock timestamp keeps the output deterministic AND keeps the verifier's
#     "differs only in default.prop and sbin/adbd" check meaningful.
import gzip, sys
work = sys.argv[1]
stock = open(work+'/ramdisk.cpio','rb').read()
new   = bytearray(gzip.decompress(open(work+'/ramdisk-new.gz','rb').read()))
def walk(d):
    i, out = 0, []
    while i + 110 <= len(d) and d[i:i+6] in (b'070701', b'070702'):
        f = lambda k: int(d[i+6+8*k:i+6+8*k+8], 16)
        size, ns = f(6), f(11)
        nm = d[i+110:i+110+ns-1].decode('utf-8','replace')
        hdr = (110 + ns + 3)//4*4
        # f(1)=mode (field 2), f(5)=mtime (field 6)
        out.append((nm, i, f(1), f(5)))
        i += hdr + (size+3)//4*4
    return out
sm = {n: (m, t) for n, _, m, t in walk(stock)}
fixed = mtimes = 0
for n, off, m, t in walk(bytes(new)):
    if n not in sm:
        continue
    smode, smtime = sm[n]
    if smode != m and (smode & 0o170000) == 0o120000:
        new[off+6+8:off+6+16] = ('%08x' % smode).encode(); fixed += 1
    if smtime != t:
        new[off+6+8*5:off+6+8*6] = ('%08x' % smtime).encode(); mtimes += 1
open(work+'/ramdisk-new.cpio','wb').write(bytes(new))
# Deterministic gzip: mtime=0 and no stored filename. Plain `gzip.open(...,9)`
# stamps the CURRENT time into the header, which makes the whole boot image
# differ on every build even though the contents are byte-identical. That is
# why an earlier build produced sha256 865c9443... and a later one 6b17c56d...
with open(work+'/ramdisk-new.gz','wb') as fh:
    with gzip.GzipFile(filename='', mode='wb', compresslevel=9,
                       fileobj=fh, mtime=0) as gz:
        gz.write(bytes(new))
print(f'  symlink modes restored: {fixed}')
PY

echo "== 6. patch the stock image IN PLACE (header stays byte-identical) =="
python3 - "$STOCK" "$WORK" "$OUT" <<'PY'
import struct, sys
src, work, out = sys.argv[1], sys.argv[2], sys.argv[3]
d = open(src,'rb').read()
u = lambda o: struct.unpack_from('<I', d, o)[0]
ks, ps = u(8), u(36)
pg = lambda n: (n + ps - 1)//ps*ps
new_rd = open(work+'/ramdisk-new.gz','rb').read()
header = bytearray(d[:ps])
struct.pack_into('<I', header, 16, len(new_rd))   # ramdisk_size: the ONLY header change
# The 32-byte `id` field (offset 576) is preserved verbatim: its generation
# algorithm could not be reproduced from the stock image, and U-Boot does not
# verify it - it is informational only.
blob = bytes(header) + d[ps:ps+pg(ks)] + new_rd + b'\0'*(pg(len(new_rd))-len(new_rd))
open(out,'wb').write(blob)
print(f'  wrote {out} ({len(blob)} bytes; stock {len(d)})')
PY

echo "== 7. verify =="
"$HERE/verify-rooted-boot.sh" "$STOCK" "$OUT"
