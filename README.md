# ZQSupremeVoice - 签名绕过 & 自毁防护补丁

iOS arm64 动态库，**信号捕获 + C interposition + ObjC Swizzling** 三层防护，专门对抗主二进制内嵌的静态反打包自毁引擎。

## 核心原理：四层防护

### 第 1 层：信号捕获（最核心）
主二进制内嵌的安全引擎检测到签名/TeamID/BundleID 不匹配时，会向 GCD 队列派发
一个跳转到非法地址 `0xb5a00000` 的 Block 任务，执行时触发 `SIGSEGV` 导致全 App 崩溃。

**解决方案**：注册 `sigaction` 捕获 `SIGSEGV` / `SIGBUS`，检测到自毁地址时，
使用 `pthread_exit(NULL)` 安全退出当前子线程，主线程和 UI 完全不受影响。

| 信号 | 触发场景 | 处理方式 |
|------|----------|----------|
| `SIGSEGV` | 段错误，跳转到 0xb5a00000 | 自毁地址 → pthread_exit；其他 → 原始处理 |
| `SIGBUS` | 总线错误（部分设备表现） | 同上 |

### 第 2 层：C 符号 Interposition
dylib 导出与系统同名的 C 函数，dyld 优先使用我们的版本。

| 拦截函数 | 作用 |
|----------|------|
| `open()` | 阻止打开 mobileprovision / SC_Info / _CodeSignature |
| `stat()` | 阻止 stat 这些文件 |
| `fopen()` | 阻止 fopen 读取 |

### 第 3 层：ObjC Runtime Swizzling

| Hook 目标 | 作用 |
|----------|------|
| `NSBundle.bundleIdentifier` | 伪装原包 BundleID |
| `NSBundle.infoDictionary` | 替换 CFBundleIdentifier |
| `NSBundle.objectForInfoDictionaryKey:` | 拦截键值读取 |

### 第 4 层：CI 构建期处理

| 操作 | 作用 |
|------|------|
| 删除 `ZSE.framework` | 剥离外部安全加固库 |
| `zsign -b com.zhenqu.music` | 强制保留原包名，防止 ID 校验触发自毁 |
| `zsign -f` | 强制全量覆盖签名 |
| `find -delete` 清理历史 dylib | 防止 libPatchZQ 4.dylib 累积副本 |

## 构建

GitHub Actions 自动编译，每次 push 到 main 自动发布 Release。

本地编译（需 macOS + Xcode）：
```bash
./build.sh
```

## 注入与重签名

```bash
# 1. 解压（每次从原始 IPA 开始，避免累积）
rm -rf Payload_Dir
unzip app.ipa -d Payload_Dir
APP_PATH=Payload_Dir/Payload/xxx.app

# 2. 清理所有历史 dylib 残留
find "$APP_PATH" -name "*PatchZQ*" -delete

# 3. 剥离 ZSE（可选）
rm -rf "$APP_PATH/Frameworks/ZSE.framework"

# 4. 注入单一干净 dylib
mkdir -p "$APP_PATH/Frameworks"
cp libPatchZQ.dylib "$APP_PATH/Frameworks/"
python3 insert_dylib.py "$APP_PATH/xxx" "@rpath/libPatchZQ.dylib"

# 5. 清理冲突组件（保留 embedded.mobileprovision）
rm -rf "$APP_PATH/PlugIns" "$APP_PATH/Watch" "$APP_PATH/_CodeSignature" "$APP_PATH/SC_Info"

# 6. zsign 重签名（-b 强制原包名）
zsign -f -b "com.zhenqu.music" -k cert.p12 -p password \
  -m profile.mobileprovision -o signed.ipa "$APP_PATH"
```

### GitHub Actions 自动重签名

在 Secrets 配置：
- `P12_BASE64` — 证书 p12 base64
- `P12_PASSWORD` — 证书密码
- `PROVISION_BASE64` — 描述文件 base64
- `IPA_URL` — 原始 IPA 下载链接

## 崩溃演进与修复历程

| 阶段 | 崩溃位置 | 原因 | 修复方案 |
|------|----------|------|----------|
| 第一版 | Thread 0 启动 | fishhook + dyld4 段保护冲突 | 移除 fishhook |
| 第二版 | Thread 7 后台 | ZSE 检测 mobileprovision 自毁 | Hook NSData + 保留文件 |
| 第三版 | Thread 3 XPC | memmem 内存扫描 + 伪造 Block 自毁 | C interposition + 剥离 ZSE |
| 第四版 | GCD 子线程 | 主二进制静态引擎 0xb5a00000 自毁 | **信号捕获 + pthread_exit** |

## 文件结构

```
├── PatchZQ.m               # 核心：信号捕获 + C interception + ObjC swizzle
├── insert_dylib.py         # Mach-O 注入脚本
├── remove_dylib_dep.py     # Mach-O 移除 dylib 依赖（ZSE 剥离用）
├── build.sh                # 本地编译脚本
├── .github/workflows/build.yml  # CI + ZSE 剥离 + zsign -b 重签
└── README.md
```

## 免责声明

仅供学习研究用途，使用需遵守当地法律法规及目标应用用户协议。
