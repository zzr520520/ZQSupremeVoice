# ZQSupremeVoice - 签名绕过补丁

iOS arm64 动态库，纯 Objective-C Runtime Swizzling 实现，兼容 iOS 15 ~ iOS 17+。

## 设计原则

- **零 fishhook**：完全移除 C 符号重绑定，避免 iOS 17 dyld4 崩溃
- **纯 ObjC Swizzling**：仅使用 `method_setImplementation`，安全稳定
- **文件存在 + 内容为空**：保留 embedded.mobileprovision 文件存在，但 Hook 读取返回 nil，防止加固空指针崩溃

## 功能

| Hook 目标 | 作用 |
|----------|------|
| `NSBundle.bundleIdentifier` | 伪装原包 BundleID |
| `NSBundle.infoDictionary` | 替换 CFBundleIdentifier |
| `NSBundle.objectForInfoDictionaryKey:` | 拦截键值读取 |
| `NSBundle.localizedInfoDictionary` | 本地化字典伪装 |
| `NSData.dataWithContentsOfFile:` | 拦截 mobileprovision 读取 → 返回 nil |
| `NSData.dataWithContentsOfFile:options:error:` | 同上，带错误信息 |
| `NSFileManager.fileExistsAtPath:` | 隐藏 SC_Info / CodeResources |
| `NSFileManager.contentsAtPath:` | 阻止读取签名相关文件 |

### 关键策略：文件保留 + 读取拦截

ZSE 等加固框架检测 `embedded.mobileprovision` 时：
- 如果文件**不存在** → 空指针异常 → 崩溃
- 如果文件**存在但读取为空** → 校验失败 → 可能触发自毁
- 如果文件**存在且读取被拦截返回 nil** → 加固认为读取出错 → 跳过校验 ✅

因此 `embedded.mobileprovision` 保留在包内，通过 Hook `NSData` 的读取接口返回 nil，
同时 `NSFileManager.fileExistsAtPath:` 对 mobileprovision 路径仍返回 YES。

## 构建

GitHub Actions 自动编译，每次 push 到 main 自动发布 Release。

本地编译（需 macOS + Xcode）：
```bash
./build.sh
```

## 注入与重签名

```bash
# 1. 解压
unzip app.ipa -d tmp
APP_PATH=tmp/Payload/xxx.app

# 2. 放入 Frameworks 目录
mkdir -p "$APP_PATH/Frameworks"
cp libPatchZQ.dylib "$APP_PATH/Frameworks/"

# 3. @rpath 注入
python3 insert_dylib.py "$APP_PATH/xxx" "@rpath/libPatchZQ.dylib"

# 4. 清理（保留 embedded.mobileprovision）
rm -rf "$APP_PATH/PlugIns"
rm -rf "$APP_PATH/Watch"
rm -rf "$APP_PATH/_CodeSignature"
rm -rf "$APP_PATH/SC_Info"

# 5. zsign -f 强制全量重签名
zsign -f -k cert.p12 -p password -m profile.mobileprovision -o signed.ipa "$APP_PATH"
```

### GitHub Actions 自动重签名

在 Secrets 配置 `P12_BASE64` / `P12_PASSWORD` / `PROVISION_BASE64` / `IPA_URL` 后自动完成全流程。

## 文件结构

```
├── PatchZQ.m               # 核心 Hook（纯 ObjC Runtime）
├── insert_dylib.py         # Mach-O 注入脚本
├── build.sh                # 本地编译脚本
├── .github/workflows/build.yml  # CI
└── README.md
```

## 崩溃演进与修复历程

| 阶段 | 崩溃位置 | 原因 | 修复方案 |
|------|----------|------|----------|
| 第一版 | Thread 0 启动 | fishhook + dyld4 段保护冲突 | 移除 fishhook，改用纯 ObjC Swizzling |
| 第二版 | Thread 7 后台 | ZSE 反打包校验触发自毁 | Hook NSData 拦截 mobileprovision + 保留文件存在 |

## 免责声明

仅供学习研究用途，使用需遵守当地法律法规及目标应用用户协议。
