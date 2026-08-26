#!/usr/bin/env python3
"""
Mach-O 静态二进制修补脚本
将主二进制中硬编码的官方 Team ID 替换为个人证书 Team ID，
使内联编译的签名扫描直接比对通过，从根源消除自毁触发。
"""

import sys
import os
import re
from collections import Counter

# 官方原版 Team ID（10 字符）— 通过二进制字符串分析确认
ORIGINAL_TEAM_ID = b"9ZSR9Q37TC"


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

    def printable(b):
        return "".join(chr(c) if 32 <= c < 127 else "." for c in b)

    # ---- 1. 替换所有独立出现的 Team ID ----
    # 独立 = 前后不是字母数字（避免误伤更长的字符串）
    total_count = 0
    pos = 0
    while True:
        pos = data.find(ORIGINAL_TEAM_ID, pos)
        if pos == -1:
            break

        # 检查边界：前后字符不应是字母或数字
        before_ok = (pos == 0) or (data[pos - 1] < 0x30 or (0x39 < data[pos - 1] < 0x41) or (0x5A < data[pos - 1] < 0x61) or data[pos - 1] > 0x7A)
        after_pos = pos + len(ORIGINAL_TEAM_ID)
        after_ok = (after_pos >= len(data)) or (data[after_pos] < 0x30 or (0x39 < data[after_pos] < 0x41) or (0x5A < data[after_pos] < 0x61) or data[after_pos] > 0x7A)

        if before_ok and after_ok:
            ctx_start = max(0, pos - 24)
            ctx_end = min(len(data), after_pos + 24)
            context_before = data[ctx_start:pos]
            context_after = data[after_pos:ctx_end]
            print(f"  [+] TeamID at 0x{pos:08X}  ...{printable(context_before)}[{ORIGINAL_TEAM_ID.decode()}]{printable(context_after)}...")
            data[pos:after_pos] = new_team_id_bytes
            total_count += 1

        pos += 1  # 逐字节搜索，允许重叠

    print(f"\n[*] Standalone TeamID replaced: {total_count}")

    # ---- 2. 替换 TeamID.com.zhenqu.music 格式（keychain / app group）----
    old_keychain = ORIGINAL_TEAM_ID + b".com.zhenqu.music"
    new_keychain = new_team_id_bytes + b".com.zhenqu.music"
    keychain_count = 0
    pos = 0
    while True:
        pos = data.find(old_keychain, pos)
        if pos == -1:
            break
        data[pos:pos + len(old_keychain)] = new_keychain
        pos += len(old_keychain)
        keychain_count += 1

    print(f"[*] Keychain/AppGroup format replaced: {keychain_count}")

    total = total_count + keychain_count
    if total == 0:
        print("\n[!] WARNING: No TeamID patterns found!")
        print("[*] Top 10-char alphanumeric candidates in binary:")
        text = data.decode("latin-1")
        matches = re.findall(r'(?<![A-Za-z0-9])[A-Z0-9]{10}(?![A-Za-z0-9])', text)
        freq = Counter(matches)
        for pattern, cnt in freq.most_common(20):
            if cnt >= 2:
                print(f"    {pattern}: {cnt} occurrences")

    # ---- 3. 写入修改后的二进制 ----
    with open(binary_path, "wb") as f:
        f.write(data)

    new_size = os.path.getsize(binary_path)
    print(f"\n[+] Binary patched successfully. Size: {file_size:,} → {new_size:,} bytes")
    assert new_size == file_size, "Binary size changed!"
    return total


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(f"Usage: python3 {sys.argv[0]} <path_to_MachO> <personal_team_id>")
        print(f"  Original TeamID: {ORIGINAL_TEAM_ID.decode()}")
        print(f"  Example: python3 {sys.argv[0]} ZQMusic ABCDE12345")
        sys.exit(1)
    patch_binary(sys.argv[1], sys.argv[2])
