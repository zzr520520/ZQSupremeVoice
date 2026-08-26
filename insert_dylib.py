#!/usr/bin/env python3
"""
向 Mach-O 二进制注入 LC_LOAD_DYLIB load command
用法: python3 insert_dylib.py <macho_path> <dylib_install_name>
"""
import struct
import sys


def insert_dylib(macho_path, dylib_path):
    with open(macho_path, 'rb') as f:
        data = bytearray(f.read())

    magic = struct.unpack_from('<I', data, 0)[0]

    if magic == 0xfeedfacf:  # MH_MAGIC_64 (little-endian)
        hdr_size = 32
        ncmds_offset = 16
        sizeofcmds_offset = 24
    elif magic == 0xfeedface:
        hdr_size = 28
        ncmds_offset = 16
        sizeofcmds_offset = 20
    elif magic == 0xcafebabe:
        # FAT binary - 需要找 arm64 slice
        print("FAT binary detected, finding arm64 slice...")
        nfat_arch = struct.unpack_from('>I', data, 4)[0]
        arch_offset = 8
        found_offset = None
        for i in range(nfat_arch):
            cputype = struct.unpack_from('>I', data, arch_offset)[0]
            offset = struct.unpack_from('>I', data, arch_offset + 8)[0]
            size = struct.unpack_from('>I', data, arch_offset + 12)[0]
            # CPU_TYPE_ARM64 = 0x0100000c (ARM64)
            if cputype == 0x0100000c:
                found_offset = offset
                print(f"  Found arm64 slice at offset {offset}")
                break
            arch_offset += 20

        if found_offset is None:
            print("ERROR: arm64 slice not found in FAT binary")
            sys.exit(1)

        # 递归处理 arm64 slice
        slice_data = bytearray(data[found_offset:])
        sub_magic = struct.unpack_from('<I', slice_data, 0)[0]
        print(f"  arm64 slice magic: {hex(sub_magic)}")

        if sub_magic == 0xfeedfacf:
            hdr_size = 32
            ncmds_offset = 16
            sizeofcmds_offset = 24
        else:
            print(f"ERROR: unsupported sub-magic: {hex(sub_magic)}")
            sys.exit(1)

        ncmds = struct.unpack_from('<I', slice_data, ncmds_offset)[0]
        sizeofcmds = struct.unpack_from('<I', slice_data, sizeofcmds_offset)[0]

        new_cmd, cmd_size = build_load_dylib_cmd(dylib_path)

        struct.pack_into('<I', slice_data, ncmds_offset, ncmds + 1)
        struct.pack_into('<I', slice_data, sizeofcmds_offset, sizeofcmds + cmd_size)

        cmds_end = hdr_size + sizeofcmds
        slice_data[cmds_end:cmds_end] = new_cmd

        # 替换原始 slice
        data[found_offset:found_offset + len(data) - found_offset] = slice_data
        # 由于 slice 变长了，需要重新写整个文件
        # 实际上 slice 变长会覆盖后面的数据，FAT header 中的 size 也要更新
        # 简单做法：重新构建
        print("FAT binary injection requires updating FAT header - using flat append approach")
        sys.exit(1)

    else:
        print(f"ERROR: unknown magic: {hex(magic)}")
        sys.exit(1)

    # 处理非 FAT 的情况
    ncmds = struct.unpack_from('<I', data, ncmds_offset)[0]
    sizeofcmds = struct.unpack_from('<I', data, sizeofcmds_offset)[0]

    new_cmd, cmd_size = build_load_dylib_cmd(dylib_path)

    struct.pack_into('<I', data, ncmds_offset, ncmds + 1)
    struct.pack_into('<I', data, sizeofcmds_offset, sizeofcmds + cmd_size)

    cmds_end = hdr_size + sizeofcmds
    data[cmds_end:cmds_end] = new_cmd

    with open(macho_path, 'wb') as f:
        f.write(data)

    print(f"OK: injected {dylib_path} (cmd_size={cmd_size})")


def build_load_dylib_cmd(dylib_path):
    """构造 LC_LOAD_DYLIB command"""
    dylib_name = dylib_path.encode('utf-8') + b'\x00'
    pad = (8 - len(dylib_name) % 8) % 8
    dylib_name_padded = dylib_name + b'\x00' * pad

    name_offset = 24  # offset of name string from start of command
    cmd_size = name_offset + len(dylib_name_padded)
    if cmd_size % 8 != 0:
        cmd_size += 8 - (cmd_size % 8)

    # LC_LOAD_DYLIB = 0xC
    cmd = struct.pack('<II', 0x0C, cmd_size)
    # dylib struct: offset, timestamp, current_version, compatibility_version
    cmd += struct.pack('<IIII', name_offset, 0, 0x00010000, 0x00010000)
    cmd += dylib_name_padded
    cmd += b'\x00' * (cmd_size - len(cmd))

    return cmd, cmd_size


if __name__ == '__main__':
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <macho_path> <dylib_install_name>")
        sys.exit(1)
    insert_dylib(sys.argv[1], sys.argv[2])
