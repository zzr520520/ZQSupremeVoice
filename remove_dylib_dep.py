#!/usr/bin/env python3
"""
从 Mach-O 二进制中移除指定的 dylib 依赖（LC_LOAD_DYLIB / LC_LOAD_WEAK_DYLIB）
用法: python3 remove_dylib_dep.py <macho_path> <keyword>
"""
import struct
import sys


def remove_dylib_dep(macho_path, keyword):
    with open(macho_path, 'rb') as f:
        data = bytearray(f.read())

    magic = struct.unpack_from('<I', data, 0)[0]

    if magic == 0xfeedfacf:  # MH_MAGIC_64
        hdr_size = 32
        ncmds_offset = 16
        sizeofcmds_offset = 24
    elif magic == 0xfeedface:
        hdr_size = 28
        ncmds_offset = 16
        sizeofcmds_offset = 20
    elif magic == 0xcafebabe:
        print("FAT binary not supported by this script (use lipo -thin arm64 first)")
        return 0
    else:
        print(f"Unknown magic: {hex(magic)}")
        return 0

    ncmds = struct.unpack_from('<I', data, ncmds_offset)[0]
    sizeofcmds = struct.unpack_from('<I', data, sizeofcmds_offset)[0]
    print(f"Load commands: {ncmds}, size: {sizeofcmds}")

    offset = hdr_size
    removed = 0
    i = 0
    while i < ncmds:
        cmd = struct.unpack_from('<I', data, offset)[0]
        cmdsize = struct.unpack_from('<I', data, offset + 4)[0]

        # LC_LOAD_DYLIB = 0xC, LC_LOAD_WEAK_DYLIB = 0x18
        # 还要考虑 re-export 等变体
        dylib_cmds = {0x0C, 0x18, 0x8000000C, 0x80000018, 0x1B, 0x8000001B}
        if cmd in dylib_cmds:
            # dylib 结构体中 name offset 在第 8 字节处 (cmd:4 + cmdsize:4 = 8)
            name_offset = struct.unpack_from('<I', data, offset + 8)[0]
            name_addr = offset + name_offset
            # 找字符串结尾
            try:
                name_end = data.index(b'\x00', name_addr)
            except ValueError:
                name_end = name_addr + 64
            name = data[name_addr:name_end].decode('utf-8', errors='replace')

            if keyword in name:
                print(f"  移除: {name}")
                del data[offset:offset + cmdsize]
                removed += 1
                ncmds -= 1
                sizeofcmds -= cmdsize
                continue

        offset += cmdsize
        i += 1

    if removed > 0:
        struct.pack_into('<I', data, ncmds_offset, ncmds)
        struct.pack_into('<I', data, sizeofcmds_offset, sizeofcmds)
        with open(macho_path, 'wb') as f:
            f.write(data)
        print(f"完成：移除了 {removed} 个 dylib 依赖")
    else:
        print(f"未找到包含 '{keyword}' 的 dylib 依赖")

    return removed


if __name__ == '__main__':
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <macho_path> <keyword>")
        sys.exit(1)
    remove_dylib_dep(sys.argv[1], sys.argv[2])
