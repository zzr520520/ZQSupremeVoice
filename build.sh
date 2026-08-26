#!/bin/bash
# 本地编译脚本 - 需要 macOS + Xcode
set -e

SDK_PATH=$(xcrun -sdk iphoneos --show-sdk-path)
echo "SDK Path: $SDK_PATH"

xcrun -sdk iphoneos clang -dynamiclib -arch arm64 \
  -isysroot "$SDK_PATH" \
  -miphoneos-version-min=15.0 \
  -fobjc-arc \
  -framework Foundation \
  -framework UIKit \
  -framework AudioToolbox \
  -framework CoreFoundation \
  Tweak.m -o libZQSupremeVoice.dylib

echo "Build success: libZQSupremeVoice.dylib"
file libZQSupremeVoice.dylib
ls -lh libZQSupremeVoice.dylib
