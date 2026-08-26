# ZQSupremeVoice - 极简自毁防护补丁

iOS arm64 动态库，**仅做两件事**：信号捕获 + Bundle 伪装。
最大限度减少对系统正常流程的干扰，确保 Assets.car / CoreUI 完整加载。

## 为什么极简

之前的版本 Hook 了 `open` / `stat` / `NSData` 等底层文件 API，
导致主线程加载 152MB Assets.car 资源包时 CoreUI 获取到 nil 或损坏数据，
触发 `SIGILL` 非法指令崩溃（`CUICatalog namedLookupWithName:` → `NSConcreteData bytes`）。

**本版原则**：只在信号层拦截自毁，绝不 Hook 任何文件系统 API。

## 核心功能

### 1. 信号捕获（自毁防护）
主二进制内嵌安全引擎检测到签名/TeamID/BundleID 不匹配时，向 GCD 队列派发
跳转到非法地址 `0xb5a00000` 的 Block → 触发 `SIGSEGV` 崩溃。

**防护方式**：`sigaction` 捕获 `SIGSEGV` / `SIGBUS` / `SIGILL`，
检测到自毁地址时调用 `pthread_exit(NULL)` 仅退出当前子线程，主进程完全不受影响。

### 2. Bundle 伪装
仅 Hook `[NSBundle mainBundle].bundleIdentifier`，伪装为原包名 `com.zhenqu.music`。
不 Hook `infoDictionary`、`objectForInfoDictionaryKey:` 等其他方法，
避免影响系统资源查找路径。

## 构建

GitHub Actions 自动编译，每次 push 到 main 自动发布 Release。

本地编译：
```bash
./build.sh
```

## 注入与重签名（干净流程）

```bash
# 1. 从原始 IPA 全新解压（关键：不要复用之前注入过的包）
rm -rf Payload_Workspace
unzip original.ipa -d Payload_Workspace
APP_PATH=Payload_Workspace/Payload/xxx.app

# 2. 可选：剥离 ZSE.framework
rm -rf "$APP_PATH/Frameworks/ZSE.framework"

# 3. 注入单一 dylib
mkdir -p "$APP_PATH/Frameworks"
cp libPatchZQ.dylib "$APP_PATH/Frameworks/"
python3 insert_dylib.py "$APP_PATH/xxx" "@rpath/libPatchZQ.dylib"

# 4. 清理冲突组件（不要删 Assets.car！不要删 embedded.mobileprovision！）
rm -rf "$APP_PATH/PlugIns" "$APP_PATH/Watch" "$APP_PATH/_CodeSignature" "$APP_PATH/SC_Info"

# 5. zsign 重签名（-b 强制原包名）
zsign -f -b "com.zhenqu.music" -k cert.p12 -p password \
  -m profile.mobileprovision -o signed.ipa "$APP_PATH"
```

### GitHub Actions 自动重签名

在 Secrets 配置：
- `P12_BASE64` — 证书 p12 base64
- `P12_PASSWORD` — 证书密码
- `PROVISION_BASE64` — 描述文件 base64
- `IPA_URL` — 原始 IPA 下载链接

CI 会每次从原始 IPA 全新解压注入，确保无累积。

## 崩溃演进与修复历程

| 阶段 | 崩溃位置 | 原因 | 修复方案 |
|------|----------|------|----------|
| 第一版 | Thread 0 启动 | fishhook + dyld4 段保护冲突 | 移除 fishhook |
| 第二版 | Thread 7 后台 | ZSE 检测 mobileprovision 自毁 | Hook NSData + 保留文件 |
| 第三版 | Thread 3 XPC | memmem 内存扫描 + 伪造 Block 自毁 | C interposition + 剥离 ZSE |
| 第四版 | GCD 子线程 | 主二进制静态引擎 0xb5a00000 自毁 | 信号捕获 + pthread_exit |
| **第五版** | **主线程 Assets.car** | **Hook 文件 API 干扰 CoreUI 资源加载** | **极简模式：只信号+Bundle，移除所有文件Hook** |

## 文件结构

```
├── PatchZQ.m               # 极简版：信号捕获 + bundleIdentifier 伪装
├── insert_dylib.py         # Mach-O 注入脚本
├── remove_dylib_dep.py     # Mach-O 移除 dylib 依赖（ZSE 剥离用）
├── build.sh                # 本地编译脚本
├── .github/workflows/build.yml  # CI 干净注入 + zsign -b 重签
└── README.md
```

## 免责声明

仅供学习研究用途，使用需遵守当地法律法规及目标应用用户协议。
