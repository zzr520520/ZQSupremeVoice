# ZQSupremeVoice - 签名绕过补丁

iOS arm64 动态库，纯 Objective-C Runtime Swizzling 实现，兼容 iOS 15 ~ iOS 17+。

## 设计原则

- **零 fishhook**：完全移除 C 符号重绑定（fishhook/rebind_symbols），避免 iOS 17 dyld4 的 __DATA_CONST 段保护崩溃
- **纯 ObjC Swizzling**：仅使用 `method_setImplementation` 交换 OC 方法实现，安全稳定
- **极简依赖**：仅依赖 Foundation + objc/runtime

## 功能

| Hook 目标 | 作用 |
|----------|------|
| `NSBundle.bundleIdentifier` | 伪装成原包 BundleID (`com.zhenqu.music`) |
| `NSBundle.infoDictionary` | 替换字典中的 CFBundleIdentifier |
| `NSBundle.objectForInfoDictionaryKey:` | 拦截键值读取 |
| `NSBundle.localizedInfoDictionary` | 本地化字典伪装 |
| `NSFileManager.fileExistsAtPath:` | 隐藏签名相关文件 |
| `NSFileManager.contentsAtPath:` | 阻止读取 mobileprovision / SC_Info 等 |

## 构建

GitHub Actions 自动编译，每次 push 到 main 自动发布 Release。

本地编译（需 macOS + Xcode）：
```bash
./build.sh
```

## 注入方式

### 使用 insert_dylib.py
```bash
# 1. 解压 IPA
unzip app.ipa -d tmp

# 2. 放到 Frameworks 目录
mkdir -p tmp/Payload/xxx.app/Frameworks
cp libPatchZQ.dylib tmp/Payload/xxx.app/Frameworks/

# 3. 注入 @rpath 加载命令
python3 insert_dylib.py tmp/Payload/xxx.app/xxx "@rpath/libPatchZQ.dylib"

# 4. 清理冲突文件
rm -rf tmp/Payload/xxx.app/PlugIns
rm -rf tmp/Payload/xxx.app/Watch
rm -rf tmp/Payload/xxx.app/_CodeSignature
rm -rf tmp/Payload/xxx.app/SC_Info
rm -f tmp/Payload/xxx.app/embedded.mobileprovision

# 5. zsign 重签名
zsign -k cert.p12 -p password -m profile.mobileprovision -o signed.ipa tmp/Payload/xxx.app
```

### GitHub Actions 自动重签名
在仓库 Settings → Secrets 配置：
- `P12_BASE64` — 证书 p12 的 base64
- `P12_PASSWORD` — 证书密码
- `PROVISION_BASE64` — 描述文件 base64
- `IPA_URL` — 原始 IPA 下载链接

触发 workflow_dispatch 或 push 到 main 即可自动完成全流程。

## 文件结构

```
├── PatchZQ.m               # 核心 Hook 代码（纯 ObjC Runtime）
├── insert_dylib.py         # Mach-O 注入脚本
├── build.sh                # 本地编译脚本
├── .github/workflows/build.yml  # CI 构建 + 注入 + 重签名
└── README.md
```

## 为什么不用 fishhook

iOS 17 的 dyld4 对 `__DATA_CONST` 段和符号表做了强化保护。传统 fishhook 在
`_dyld_register_func_for_add_image` 回调中遍历系统镜像解析符号时，读取受保护内存
会直接触发 `EXC_BAD_ACCESS (SIGSEGV)` 崩溃。

纯 ObjC Runtime Swizzling 只操作 `class_getInstanceMethod` + `method_setImplementation`，
完全在 OC 运行时的合法路径内，不会触及 dyld 的受保护段。

## 免责声明

仅供学习研究用途，使用需遵守当地法律法规及目标应用用户协议。
