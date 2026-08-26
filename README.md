# ZQSupremeVoice - 签名绕过补丁

iOS arm64 动态库，C 符号 interposition + ObjC Runtime Swizzling 双层拦截，兼容 iOS 15 ~ iOS 17+。

## 核心机制：双层拦截

### C 层（符号导出覆盖 / Interposition）
dylib 导出与系统同名的 C 函数，dyld 加载时优先使用我们的版本，
通过 `dlsym(RTLD_NEXT, ...)` 调用原始系统实现。

| 拦截函数 | 作用 |
|----------|------|
| `open()` | 阻止打开 mobileprovision / SC_Info / _CodeSignature |
| `openat()` | 同上（相对路径版本） |
| `stat()` | 阻止 stat 这些文件 |
| `lstat()` | 同上 |
| `fopen()` | 阻止 fopen 读取 |

### ObjC 层（Method Swizzling）

| Hook 目标 | 作用 |
|----------|------|
| `NSBundle.bundleIdentifier` | 伪装原包 BundleID |
| `NSBundle.infoDictionary` | 替换 CFBundleIdentifier |
| `NSBundle.objectForInfoDictionaryKey:` | 拦截键值读取 |
| `NSBundle.localizedInfoDictionary` | 本地化字典伪装 |
| `NSData +dataWithContentsOfFile:` | 拦截描述文件读取 |
| `NSFileManager.fileExistsAtPath:` | 隐藏 SC_Info / CodeResources |
| `NSFileManager.contentsAtPath:` | 阻止读取签名相关文件 |

### CI 层（构建期剥离）

| 操作 | 作用 |
|------|------|
| 删除 `ZSE.framework` | 彻底移除安全加固/反作弊库 |
| 移除主二进制 ZSE 依赖 | 从 Load Commands 中剥离 |
| `zsign -f` 强制全量重签 | 确保所有 Framework 签名一致 |

## 为什么不用 fishhook

iOS 17 dyld4 对 `__DATA_CONST` 段和符号表做了强化保护。
fishhook 在 `_dyld_register_func_for_add_image` 中遍历系统镜像时会触发 `EXC_BAD_ACCESS`。

**本项目使用 dylib interposition（符号导出覆盖）** 替代 fishhook：
- 我们的 dylib 导出与系统同名的函数（`open`、`stat`、`fopen` 等）
- dyld 在扁平命名空间中优先查找先加载的库
- 再通过 `dlsym(RTLD_NEXT, ...)` 链到系统原始实现
- 完全在 dyld 的合法机制内，不触碰受保护内存

## 构建

GitHub Actions 自动编译，每次 push 到 main 自动发布 Release。

本地编译（需 macOS + Xcode）：
```bash
./build.sh
```

验证导出符号：
```bash
nm -gU libPatchZQ.dylib | grep -E "open|stat|fopen"
```

## 注入与重签名

```bash
# 1. 解压
unzip app.ipa -d tmp
APP_PATH=tmp/Payload/xxx.app

# 2. 剥离 ZSE.framework（可选，推荐）
rm -rf "$APP_PATH/Frameworks/ZSE.framework"
# 同时从主二进制移除 LC_LOAD_DYLIB（用 python 脚本或 optool）

# 3. 放入 Frameworks 目录
mkdir -p "$APP_PATH/Frameworks"
cp libPatchZQ.dylib "$APP_PATH/Frameworks/"

# 4. @rpath 注入
python3 insert_dylib.py "$APP_PATH/xxx" "@rpath/libPatchZQ.dylib"

# 5. 清理（保留 embedded.mobileprovision，由 C 层拦截）
rm -rf "$APP_PATH/PlugIns"
rm -rf "$APP_PATH/Watch"
rm -rf "$APP_PATH/_CodeSignature"
rm -rf "$APP_PATH/SC_Info"

# 6. zsign -f 强制全量重签名
zsign -f -k cert.p12 -p password -m profile.mobileprovision -o signed.ipa "$APP_PATH"
```

### GitHub Actions 自动重签名

在 Secrets 配置 `P12_BASE64` / `P12_PASSWORD` / `PROVISION_BASE64` / `IPA_URL` 后自动完成：
编译 dylib → 下载 IPA → 剥离 ZSE → 注入 dylib → 清理 → zsign 重签 → 上传产物

## 崩溃演进与修复历程

| 阶段 | 崩溃位置 | 原因 | 修复方案 |
|------|----------|------|----------|
| 第一版 | Thread 0 启动 | fishhook + dyld4 段保护冲突 | 移除 fishhook，改用纯 ObjC Swizzling |
| 第二版 | Thread 7 后台 | ZSE 检测 mobileprovision 触发自毁 | Hook NSData + 保留文件存在 |
| 第三版 | Thread 3 XPC | memmem 内存扫描 + 伪造 Block 自毁 | C 层 interposition 拦截 open/stat + CI 剥离 ZSE |

## 文件结构

```
├── PatchZQ.m               # 核心 Hook（C interposition + ObjC Swizzling）
├── insert_dylib.py         # Mach-O 注入脚本
├── build.sh                # 本地编译脚本
├── .github/workflows/build.yml  # CI + ZSE 剥离 + zsign 重签
└── README.md
```

## 免责声明

仅供学习研究用途，使用需遵守当地法律法规及目标应用用户协议。
