# ZQSupremeVoice - 签名绕过补丁

iOS arm64 动态库，用于绕过个人证书重签名后的闪退问题。

## 功能

| Hook 目标 | 作用 |
|----------|------|
| `NSBundle.bundleIdentifier` | 伪装成原包 BundleID (`com.zhenqu.music`) |
| `NSBundle.infoDictionary` | 替换 CFBundleIdentifier |
| `ptrace` | 拦截 PT_DENY_ATTACH 反调试 |
| `fopen` / `open` | 阻止读取 `embedded.mobileprovision` / `_CodeSignature` / `SC_Info` |
| `sysctl` | 清除 P_TRACED 标志位，隐藏调试状态 |

## 崩溃原因与修复思路

个人证书重签名后闪退的常见原因：

1. **Framework 深层签名不完整** — 使用 `zsign` 自动递归签名所有内嵌 Framework / dylib
2. **Entitlements 权限冲突** — 移除 PlugIns / Watch / App Groups 相关内容
3. **ZSE / 加固对抗** — 本 dylib 伪装 BundleID、拦截签名文件读取、绕过反调试

## 构建

GitHub Actions 自动编译：每次 push 到 main 分支 → 编译 dylib → 发布 Release

本地编译（需 macOS + Xcode）：
```bash
xcrun -sdk iphoneos clang -dynamiclib -arch arm64 \
  -isysroot $(xcrun -sdk iphoneos --show-sdk-path) \
  -miphoneos-version-min=15.0 \
  -fobjc-arc \
  -framework Foundation \
  -framework UIKit \
  PatchZQ.m fishhook.c -o libPatchZQ.dylib
```

## 使用

### 方式一：optool 注入 + zsign 重签名
```bash
# 1. 解压 IPA
unzip app.ipa -d tmp

# 2. 复制 dylib
cp libPatchZQ.dylib tmp/Payload/xxx.app/

# 3. 注入 Load Command
optool install -c load -p "@executable_path/libPatchZQ.dylib" -t tmp/Payload/xxx.app/xxx

# 4. 清理插件
rm -rf tmp/Payload/xxx.app/PlugIns
rm -rf tmp/Payload/xxx.app/Watch
rm -rf tmp/Payload/xxx.app/_CodeSignature
rm -rf tmp/Payload/xxx.app/SC_Info

# 5. zsign 重签名
zsign -k cert.p12 -p password -m profile.mobileprovision -o signed.ipa tmp/Payload/xxx.app
```

### 方式二：GitHub Actions 自动重签名
在仓库 Settings → Secrets 中配置：
- `P12_BASE64` — 证书 p12 的 base64
- `P12_PASSWORD` — 证书密码
- `PROVISION_BASE64` — 描述文件 mobileprovision 的 base64
- `IPA_URL` — 原始 IPA 下载链接

然后触发 workflow_dispatch 即可自动完成注入+重签名。

## 文件结构

```
├── PatchZQ.m                    # 核心 Hook 代码
├── fishhook.h / fishhook.c      # Facebook fishhook 符号重绑定库
├── build.sh                     # 本地编译脚本
├── .github/workflows/build.yml  # CI 构建 + 注入 + 重签名
└── README.md
```

## 免责声明

仅供学习研究用途，使用需遵守当地法律法规及目标应用用户协议。
