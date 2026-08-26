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
  PatchZQ.m fishhook.c -o libPatchZQ.dylib

strip -x libPatchZQ.dylib

echo ""
echo "Build success: libPatchZQ.dylib"
file libPatchZQ.dylib
ls -lh libPatchZQ.dylib
