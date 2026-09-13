#!/usr/bin/env python3
"""
Replace AndroidManifest.xml inside framework-res.apk, preserving every other
entry (name, order, compression, attributes).

The APK's JAR signature becomes stale - that is expected and intentional:
PackageManagerService.collectCertificatesLI() reuses the signatures cached in
packages.xml without re-verifying, provided the file's lastModified() still
equals the cached timestamp. We restore that timestamp on the device after
pushing, so verification is never triggered.
"""
import shutil
import sys
import zipfile

src, dst, new_manifest = sys.argv[1], sys.argv[2], sys.argv[3]
replacement = open(new_manifest, 'rb').read()

zin = zipfile.ZipFile(src, 'r')
zout = zipfile.ZipFile(dst, 'w')
count = replaced = 0
try:
    for item in zin.infolist():
        data = zin.read(item.filename)
        if item.filename == 'AndroidManifest.xml':
            data = replacement
            replaced += 1
        zi = zipfile.ZipInfo(item.filename, date_time=item.date_time)
        zi.compress_type = item.compress_type
        zi.external_attr = item.external_attr
        zi.internal_attr = item.internal_attr
        zi.create_system = item.create_system
        zi.comment = item.comment
        zout.writestr(zi, data)
        count += 1
finally:
    zout.close()
    zin.close()

print(f'  entries copied: {count}   AndroidManifest.xml replaced: {replaced}')
assert replaced == 1, 'expected exactly one AndroidManifest.xml'
