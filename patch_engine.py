#!/usr/bin/env python3
"""
ZQMusic 主二进制静态修补脚本
- 替换官方 Team ID 为个人证书的 Team ID
- 替换原始 Bundle ID 为新的 Bundle ID（可选，分身版用）
- 中和 _CodeSignature 引用
全部等长替换，不改变文件大小，不破坏 Mach-O 结构
"""

import sys
import os
import struct

# ========== 官方硬编码值（从原版二进制提取） ==========
OFFICIAL_TEAM_ID = b"7QW5G8QMV9"     # 10 位官方 Team ID
ORIGINAL_BUNDLE_ID = b"com.zhenqu.music"  # 原始 Bundle ID

def find_and_replace(data, old, new, label):
    """等长字符串替换"""
    if len(new) != len(old):
        print(f"[-] {label}: 长度不一致，无法等长替换 ({len(old)} -> {len(new)})")
        return 0
    
    count = 0
    pos = 0
    while True:
        pos = data.find(old, pos)
        if pos == -1:
            break
        data[pos:pos+len(old)] = new
        pos += len(old)
        count += 1
    
    if count > 0:
        print(f"[+] {label}: 替换了 {count} 处 ({old.decode(errors='replace')} -> {new.decode(errors='replace')})")
    else:
        print(f"[!] {label}: 未找到 '{old.decode(errors='replace')}'")
    
    return count


def patch_macho(macho_path, personal_team_id, new_bundle_id=None):
    if not os.path.exists(macho_path):
        print(f"[-] 文件不存在: {macho_path}")
        sys.exit(1)
    
    # 验证参数长度
    if len(personal_team_id) != len(OFFICIAL_TEAM_ID):
        print(f"[-] Team ID 长度必须是 {len(OFFICIAL_TEAM_ID)} 位")
        sys.exit(1)
    
    new_team_bytes = personal_team_id.encode('utf-8')
    
    new_bundle_bytes = None
    if new_bundle_id:
        if len(new_bundle_id) != len(ORIGINAL_BUNDLE_ID):
            print(f"[-] Bundle ID 长度必须和原始 '{ORIGINAL_BUNDLE_ID.decode()}' 一致 ({len(ORIGINAL_BUNDLE_ID)} 字符)")
            print(f"    当前提供 '{new_bundle_id}' ({len(new_bundle_id)} 字符)")
            sys.exit(1)
        new_bundle_bytes = new_bundle_id.encode('utf-8')
    
    with open(macho_path, "rb") as f:
        data = bytearray(f.read())
    
    print(f"[*] 读取二进制: {macho_path} ({len(data)} 字节)")
    print()
    
    total = 0
    
    # 1. 替换 Team ID
    total += find_and_replace(data, OFFICIAL_TEAM_ID, new_team_bytes, "Team ID")
    
    # 2. 替换 Bundle ID（可选）
    if new_bundle_bytes:
        total += find_and_replace(data, ORIGINAL_BUNDLE_ID, new_bundle_bytes, "Bundle ID")
    
    # 3. 中和 _CodeSignature 引用（改成不存在的路径，必须等长）
    old_cs = b"_CodeSignature"
    new_cs = b"_CodeSignaturX"  # 等长替换，最后一个字符改掉
    total += find_and_replace(data, old_cs, new_cs, "_CodeSignature")
    
    print()
    print(f"[=] 总共替换了 {total} 处")
    
    with open(macho_path, "wb") as f:
        f.write(data)
    
    print(f"[+] 写入成功: {macho_path}")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("用法: python3 patch_engine.py <Mach-O 路径> <个人 Team ID> [新 Bundle ID]")
        print()
        print("说明:")
        print("  - Team ID 必须是 10 位")
        print("  - Bundle ID 可选，用于分身版（长度必须和原始 com.zhenqu.music 一致）")
        sys.exit(1)
    
    macho_path = sys.argv[1]
    team_id = sys.argv[2]
    bundle_id = sys.argv[3] if len(sys.argv) > 3 else None
    
    patch_macho(macho_path, team_id, bundle_id)
