#!/usr/bin/env python3
"""
Patch one attribute value inside an Android binary XML (AXML) file.

Used to change the protectionLevel of a framework permission in
framework-res.apk so that the grant logic accepts it.

Usage:
    patch-axml.py <in.xml> <out.xml> <element-name> <match-attr> <match-value> \
                  <patch-attr> <new-int-value>
"""
import struct
import sys


class StringPool:
    def __init__(self, data, off):
        (self.type, self.header_size, self.size) = struct.unpack_from('<HHI', data, off)
        assert self.type == 0x0001, f'not a string pool: {self.type:#x}'
        (string_count, style_count, flags, strings_start, styles_start) = \
            struct.unpack_from('<IIIII', data, off + 8)
        self.string_count = string_count
        self.flags = flags
        self.utf8 = bool(flags & (1 << 8))
        self.base = off
        self.offsets = [struct.unpack_from('<I', data, off + self.header_size + 4 * i)[0]
                        for i in range(string_count)]
        self.strings_start = strings_start

    def get(self, data, idx):
        if idx == 0xFFFFFFFF or idx >= self.string_count:
            return None
        p = self.base + self.strings_start + self.offsets[idx]
        if self.utf8:
            # u16 utf16-length (varint), u8 utf8-length (varint), then bytes + NUL
            n = data[p]
            p += 2 if (n & 0x80) else 1
            n = data[p]
            p += 2 if (n & 0x80) else 1
            end = data.index(b'\x00', p)
            return data[p:end].decode('utf-8', 'replace')
        n = struct.unpack_from('<H', data, p)[0]
        p += 2
        if n & 0x8000:
            n = ((n & 0x7FFF) << 16) | struct.unpack_from('<H', data, p)[0]
            p += 2
        return data[p:p + n * 2].decode('utf-16-le', 'replace')


def patch(data, element, match_attr, match_value, patch_attr, new_value):
    (magic, file_size) = struct.unpack_from('<II', data, 0)
    assert magic == 0x00080003, f'not AXML: {magic:#x}'
    off = 8
    pool = None
    patches = []
    while off < len(data):
        (ctype, hsize, csize) = struct.unpack_from('<HHI', data, off)
        if csize == 0:
            break
        if ctype == 0x0001:
            pool = StringPool(data, off)
        elif ctype == 0x0102:  # StartElement
            # ResXMLTree_node: header(8) lineNumber(4) comment(4)
            # ResXMLTree_attrExt: ns(4)@16 name(4)@20 attributeStart(2)@24
            #                     attributeSize(2)@26 attributeCount(2)@28
            (line, comment, ns, name) = struct.unpack_from('<IIII', data, off + 8)
            (attr_start, attr_size, attr_count) = struct.unpack_from('<HHH', data, off + 24)
            el_name = pool.get(data, name)
            if el_name == element:
                attrs = {}
                for i in range(attr_count):
                    a = off + 16 + attr_start + i * attr_size
                    a_ns, a_name, a_raw = struct.unpack_from('<III', data, a)
                    a_tsize, a_res0, a_type, a_data = struct.unpack_from('<HBBI', data, a + 12)
                    attrs[pool.get(data, a_name)] = (a + 16, a_raw, a_type, a_data)
                if match_attr in attrs:
                    raw = attrs[match_attr][1]
                    if pool.get(data, raw) == match_value:
                        if patch_attr not in attrs:
                            raise SystemExit(f'{patch_attr} not on element')
                        pos, _, atype, aval = attrs[patch_attr]
                        patches.append((pos, atype, aval))
                        print(f'  element <{element}> matching {match_attr}={match_value}')
                        print(f'    {patch_attr}: {aval} -> {new_value}  (at file offset {pos - 4})')
        off += csize
    if not patches:
        raise SystemExit('no matching element found')
    out = bytearray(data)
    for pos, atype, aval in patches:
        struct.pack_into('<I', out, pos, new_value)
    return bytes(out), len(patches)


def main():
    src, dst, element, match_attr, match_value, patch_attr, new_value = sys.argv[1:8]
    data = open(src, 'rb').read()
    out, n = patch(data, element, match_attr, match_value, patch_attr, int(new_value))
    open(dst, 'wb').write(out)
    print(f'  patched {n} occurrence(s) -> {dst}')


if __name__ == '__main__':
    main()
