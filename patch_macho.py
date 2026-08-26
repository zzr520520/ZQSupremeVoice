#!/usr/bin/env python3
"""
Mach-O 静态二进制修补脚本
将主二进制中硬编码的官方 Team ID 替换为个人证书 Team ID，
使内联编译的签名扫描直接比对通过，从根源消除自毁触发。
"""

import sys
import os
import struct

# 官方原版 Team ID（10 字符）
ORIGINAL_TEAM_ID = b"7QW5G8QMV9"

# 需要同时替换的其他特征字符串（加固可能多处校验）
EXTRA_SEARCH_REPLACE = []


def patch_binary(binary_path, new_team_id):
    if not os.path.exists(binary_path):
        print(f"[!] Error: Binary not found at {binary_path}")
        sys.exit(1)

    file_size = os.path.getsize(binary_path)
    print(f"[*] Binary size: {file_size:,} bytes ({file_size / 1024 / 1024:.1f} MB)")

    with open(binary_path, "rb") as f:
        data = bytearray(f.read())

    new_team_id_bytes = new_team_id.encode("utf-8")

    if len(new_team_id_bytes) != 10:
        print(f"[!] Target Team ID must be exactly 10 characters long, got: {len(new_team_id)} ({new_team_id})")
        sys.exit(1)

    if new_team_id_bytes == ORIGINAL_TEAM_ID:
        print("[!] New Team ID is the same as original, nothing to patch.")
        return

    # ---- 1. 替换所有硬编码的 Team ID ----
    count = 0
    pos = 0
    while True:
        pos = data.find(ORIGINAL_TEAM_ID, pos)
        if pos == -1:
            break
        # 打印前后上下文帮助定位（每侧各 20 字节）
        ctx_start = max(0, pos - 20)
        ctx_end = min(len(data), pos + len(ORIGINAL_TEAM_ID) + 20)
        context_before = data[ctx_start:pos]
        context_after = data[pos + len(ORIGINAL_TEAM_ID):ctx_end]
        # 尝试打印可打印字符，不可打印的用 . 代替
        def printable(b):
            return "".join(chr(c) if 32 <= c < 127 else "." for c in b)
        print(f"  [+] Found TeamID at offset 0x{pos:08X}  context: ...{printable(context_before)}[{ORIGINAL_TEAM_ID.decode()}]{printable(context_after)}...")
        data[pos:pos + 10] = new_team_id_bytes
        pos += 10
        count += 1

    print(f"\n[*] Total Team ID strings replaced: {count}")

    if count == 0:
        print("[!] WARNING: No Team ID found in binary. Check if the original Team ID is correct.")
        # 列出二进制中所有 10 字符大写字母+数字的字符串帮助排查
        print("\n[*] Scanning for potential TeamID patterns (10 uppercase alphanumeric chars)...")
        import re
        text = data.decode("latin-1")
        # Team ID 格式：10 个大写字母和数字
        matches = [(m.start(), m.group()) for m in re.finditer(r'[A-Z0-9]{10}', text)]
        # 过滤：只打印在 __TEXT 段附近或出现多次的
        from collections import Counter
        freq = Counter(m[1] for m in matches)
        for pattern, cnt in freq.most_common(20):
            if cnt >= 2:
                print(f"    {pattern}: {cnt} occurrences")

    # ---- 2. 写入修改后的二进制 ----
    with open(binary_path, "wb") as f:
        f.write(data)

    new_size = os.path.getsize(binary_path)
    print(f"\n[+] Mach-O binary patched successfully. Size: {file_size:,} → {new_size:,} bytes")
    assert new_size == file_size, "Binary size changed! Replacement must be same length."


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python3 patch_macho.py <path_to_MachO> <personal_team_id>")
        print("  Example: python3 patch_macho.py ZQMusic ABCDE12345")
        sys.exit(1)
    patch_binary(sys.argv[1], sys.argv[2])
