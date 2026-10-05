#!/bin/bash
# 小鲸鱼挂件 Mac 版一键安装：编译 → 组装 WhalePet.app → 启动
# 用法：解压后双击 install.command
set -e
cd "$(dirname "$0")"

if ! command -v swiftc >/dev/null 2>&1; then
  osascript -e 'display dialog "首次使用需要安装苹果编译工具（Xcode Command Line Tools）。\n\n点「好」后弹出安装窗口，一路同意即可，装完（约10分钟）再双击一次 install.command。" with title "小鲸鱼挂件" buttons {"好"} default button 1' >/dev/null 2>&1 || true
  xcode-select --install >/dev/null 2>&1 || true
  exit 0
fi

echo "编译中，约半分钟……"
mkdir -p build
swiftc -O whale-mac.swift -o build/whale-pet-mac

APP=WhalePet.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/"
cp build/whale-pet-mac "$APP/Contents/MacOS/"
for f in whale.png rua.gif Ya1.wav Ya2.wav D1.wav D2.wav; do
  [ -f "$f" ] && cp "$f" "$APP/Contents/Resources/"
done

# 本地 ad-hoc 签名，避免部分系统拒绝运行
codesign --force -s - "$APP" >/dev/null 2>&1 || true

osascript -e 'display dialog "小鲸鱼已就位！\n\n已自动启动。以后双击 WhalePet.app 就能用。\n\n想开机自启：系统设置 → 通用 → 登录项，把 WhalePet.app 拖进去。" with title "小鲸鱼挂件" buttons {"开跑"} default button 1' >/dev/null 2>&1 || true
open "$APP"
echo "完成。WhalePet.app 已启动。"
