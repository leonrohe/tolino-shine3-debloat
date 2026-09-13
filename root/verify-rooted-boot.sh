#!/usr/bin/env bash
#
# Verify a patched Tolino boot image against the stock one it was built from.
# Asserts: kernel byte-identical, header identical except ramdisk_size, and the
# ramdisk differs ONLY in default.prop and sbin/adbd (plus the meaningless cpio
# TRAILER mode). Also re-derives the adbd patch from the stock binary.
#
# Usage: ./verify-rooted-boot.sh stock-boot.img rooted-boot.img
#
set -euo pipefail

STOCK="${1:?usage: $0 <stock-boot.img> <rooted-boot.img>}"
ROOTED="${2:?usage: $0 <stock-boot.img> <rooted-boot.img>}"

ADBD_PATCHED_MD5='98bbfe2462b221eedb944f72315df789'

python3 - "$STOCK" "$ROOTED" "$ADBD_PATCHED_MD5" <<'PY'
import struct, gzip, hashlib, sys

stock, rooted, want_adbd = sys.argv[1], sys.argv[2], sys.argv[3]
fail = []

def parts(p):
    d = open(p,'rb').read()
    if d[:8] != b'ANDROID!':
        raise SystemExit(f'{p}: not an Android boot image')
    u = lambda o: struct.unpack_from('<I', d, o)[0]
    ks, rs, ps = u(8), u(16), u(36)
    pg = lambda n: (n + ps - 1)//ps*ps
    return d, u, d[ps:ps+ks], gzip.decompress(d[ps+pg(ks):ps+pg(ks)+rs])

ad, au, ak, ar = parts(stock)
bd, bu, bk, br = parts(rooted)

print('--- header ---')
for off, n in {8:'kernel_size',12:'kernel_addr',16:'ramdisk_size',20:'ramdisk_addr',
               24:'second_size',28:'second_addr',32:'tags_addr',36:'page_size',
               40:'header_version',44:'os_version'}.items():
    x, y = au(off), bu(off)
    if x == y:
        print(f'  {n:<16} {hex(x):<12} same')
    elif n == 'ramdisk_size':
        print(f'  {n:<16} {x} -> {y}   (expected)')
    else:
        print(f'  {n:<16} {x} -> {y}   *** UNEXPECTED ***'); fail.append(n)
for label, sl in (('name', slice(48,64)), ('cmdline', slice(64,576)), ('id', slice(576,608))):
    same = ad[sl] == bd[sl]
    note = 'same' if same else ('preserved' if label == 'id' else '*** DIFFERS ***')
    print(f'  {label:<16} {note}')
    if label != 'id' and not same:
        fail.append(label)

print('--- kernel (the touch drivers live here) ---')
if ak == bk:
    print(f'  byte-identical ({len(bk)} bytes)')
    print(f'  md5 {hashlib.md5(bk).hexdigest()}')
else:
    print('  *** KERNEL DIFFERS - this is what breaks touchscreens ***'); fail.append('kernel')

print('--- ramdisk ---')
def parse(d):
    out, i = {}, 0
    while i + 110 <= len(d) and d[i:i+6] in (b'070701', b'070702'):
        f = lambda k: int(d[i+6+8*k:i+6+8*k+8], 16)
        mode, uid, gid, size, ns = f(1), f(2), f(3), f(6), f(11)
        nm = d[i+110:i+110+ns-1].decode('utf-8','replace')
        hdr = (110 + ns + 3)//4*4
        out[nm] = (mode, uid, gid, d[i+hdr:i+hdr+size])
        i += hdr + (size+3)//4*4
    return out

A, B = parse(ar), parse(br)
if set(A) != set(B):
    print('  *** file lists differ ***'); fail.append('ramdisk file list')
else:
    diff = [n for n in sorted(A) if A[n] != B[n]]
    print(f'  entries: {len(A)}')
    print(f'  differing: {diff}')
    unexpected = [n for n in diff if n not in ('default.prop', 'sbin/adbd', 'TRAILER!!!')]
    if unexpected:
        fail.append('unexpected ramdisk changes ' + str(unexpected))

print('--- the adbd patch ---')
got = hashlib.md5(B['sbin/adbd'][3]).hexdigest()
print(f'  patched adbd md5 {got}')
if got != want_adbd:
    print(f'  *** does not match the known-good binary {want_adbd} ***')
    fail.append('adbd md5')
else:
    print('  == byte-identical to the community image\'s proven patched adbd ==')

d = bytearray(A['sbin/adbd'][3])
NOP2 = b'\x00\xbf'
for label, pat in (('setgroups/setgid/setuid', bytes.fromhex('4ff4fa600ef086ed0028dfd14ff4fa6016f047f80028d9d1')),
                   ('prctl(PR_CAPBSET_DROP)',  bytes.fromhex('0ef0deed'))):
    i = d.find(pat)
    if i < 0:
        print(f'  *** pattern for {label} missing from stock adbd ***'); fail.append(label); continue
    d[i:i+len(pat)] = NOP2 * (len(pat)//2)
same = bytes(d) == B['sbin/adbd'][3]
print(f'  re-derived from stock == shipped: {same}')
if not same:
    fail.append('adbd re-derivation')

print('--- default.prop ---')
txt = B['default.prop'][3].decode()
for want in ('ro.secure=0', 'ro.debuggable=1', 'persist.service.adb.enable=1',
             'persist.sys.usb.config=mass_storage,adb'):
    ok = any(l.strip() == want for l in txt.splitlines())
    print(f'  {want:<40} {"present" if ok else "*** MISSING ***"}')
    if not ok:
        fail.append(want)

print()
if fail:
    print('RESULT: *** FAILED *** ->', ', '.join(fail)); sys.exit(1)
print('RESULT: OK')
print('  kernel byte-identical; header identical except ramdisk_size;')
print('  ramdisk differs only in default.prop and sbin/adbd, and that adbd is')
print('  byte-identical to the community root image\'s proven binary.')
PY
