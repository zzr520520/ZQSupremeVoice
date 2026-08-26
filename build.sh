#!/bin/bash
# 本地编译脚本 - 需要 macOS + Xcode
set -e

SDK_PATH=$(xcrun -sdk iphoneos --show-sdk-path)
echo "SDK Path: $SDK_PATH"

xcrun -sdk iphoneos clang -dynamiclib -arch arm64 \
  -isysroot "$SDK_PATH" \
  -miphoneos-version-min=15.0 \
  -framework Foundation \
  -fobjc-arc -O2 \
  PatchZQ.m -o libPatchZQ.dylib

install_name_tool -id "@rpath/libPatchZQ.dylib" libPatchZQ.dylib
strip -x libPatchZQ.dylib

echo ""
echo "Build success: libPatchZQ.dylib"
file libPatchZQ.dylib
ls -lh libPatchZQ.dylib
echo ""
echo "导出符号:"
nm -gU libPatchZQ.dylib
echo ""
echo "依赖库:"
otool -L libPatchZQ.dylib
