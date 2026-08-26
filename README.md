# ZQSupremeVoice

iOS arm64 动态库，注入音频上行 DSP 处理。

## 功能

- **软压限**：tanhf 曲线，增益后锁定 -0.1 dBFS
- **噪声门**：低电平样本归零，过滤底噪
- **强制开麦**：拦截 closeMicro / pauseAudio
- **禁用 AGC**：防止 RTC 内置自动增益压低声音
- **码率锁定**：192 kbps 上行
- **双指双击面板**：两指连点两下唤出控制面板

## 构建

GitHub Actions 自动编译，每次 push 到 main 自动发布。

本地编译（需 macOS + Xcode）：
```bash
./build.sh
```

## 使用

将 `libZQSupremeVoice.dylib` 注入目标 App 进程，双指双击屏幕唤出面板。
