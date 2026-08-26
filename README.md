# ZQSupremeVoice - GCD 拦截自毁防护

iOS arm64 动态库，通过 **GCD 入口拦截 + 信号备用 + Bundle 保护** 三层防护，
对抗主二进制内嵌静态安全引擎的自毁逻辑。

## 核心原理

### 第 1 层：GCD 入口拦截（主防线）
主二进制安全引擎检测签名失败后，通过 `dispatch_async_f` 向 GCD 队列派发
跳转到 `0xb5a00000` 的伪造任务。我们在 `dispatch_async_f` / `dispatch_async` /
`dispatch_sync_f` / `dispatch_after_f` 入口处检查函数指针地址，
匹配自毁页范围的直接 `return` 丢弃，不进入线程池执行。

**为什么不用 sigaction**：RTC 引擎（rcrtc::PosixSignalHandler）启动后会重新
覆盖全局信号表，导致 dylib 注册的 sigaction 被冲掉。GCD 入口拦截不依赖
信号机制，无法被覆盖。

### 第 2 层：信号定时重注册（备用防线）
虽然会被 RTC 覆盖，但使用 `dispatch_source` 定时器每 5 秒重新注册 sigaction，
在窗口期内仍能拦截自毁段错误。

### 第 3 层：Bundle 伪装与路径保护
- `bundleIdentifier` → 伪装原包名
- `bundleWithPath:` → 空值安全保护，防止 lstat 断点陷阱

## 拦截的 GCD 函数

| 函数 | 拦截方式 |
|------|----------|
| `dispatch_async_f` | 检查 work 函数指针，自毁地址则丢弃 |
| `dispatch_async` | 检查 Block invoke 指针，自毁地址则丢弃 |
| `dispatch_sync_f` | 同上 |
| `dispatch_after_f` | 同上（延迟派发） |

## 构建

GitHub Actions 自动编译，每次 push 到 main 自动发布 Release。

```bash
./build.sh
```

## 注入与重签名

```bash
# 从原始 IPA 全新解压
rm -rf Payload_Workspace
unzip original.ipa -d Payload_Workspace
APP_PATH=Payload_Workspace/Payload/xxx.app

# 注入 dylib（@executable_path）
cp libPatchZQ.dylib "$APP_PATH/"
python3 insert_dylib.py "$APP_PATH/xxx" "@executable_path/libPatchZQ.dylib"

# 清理冲突组件
rm -rf "$APP_PATH/PlugIns" "$APP_PATH/Watch" "$APP_PATH/_CodeSignature" "$APP_PATH/SC_Info"
rm -f "$APP_PATH/embedded.mobileprovision"

# zsign 重签名
zsign -f -b "com.zhenqu.music" -k cert.p12 -p password \
  -m profile.mobileprovision -o signed.ipa "$APP_PATH"
```

## 崩溃演进与修复历程

| 阶段 | 崩溃位置 | 原因 | 修复方案 |
|------|----------|------|----------|
| v1 | Thread 0 启动 | fishhook + dyld4 段保护冲突 | 移除 fishhook |
| v2 | Thread 7 后台 | ZSE 检测 mobileprovision 自毁 | Hook NSData + 保留文件 |
| v3 | Thread 3 XPC | memmem 内存扫描 + 伪造 Block 自毁 | C interposition + 剥离 ZSE |
| v4 | GCD 子线程 | 主二进制静态引擎 0xb5a00000 自毁 | 信号捕获 + pthread_exit |
| v5 | 主线程 Assets.car | Hook 文件 API 干扰 CoreUI 加载 | 极简模式：仅信号+Bundle |
| **v6** | **主线程 lstat** | **sigaction 被 RTC PosixSignalHandler 覆盖** | **GCD 入口拦截 + 定时重注册信号** |

## 文件结构

```
├── PatchZQ.m               # GCD 拦截 + 信号备用 + Bundle 保护
├── insert_dylib.py         # Mach-O 注入脚本
├── remove_dylib_dep.py     # Mach-O 移除 dylib 依赖
├── build.sh                # 本地编译脚本
├── .github/workflows/build.yml  # CI 干净注入 + zsign -b 重签
└── README.md
```

## 免责声明

仅供学习研究用途，使用需遵守当地法律法规及目标应用用户协议。
