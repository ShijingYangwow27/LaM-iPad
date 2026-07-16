#!/bin/bash
# Mineradio iPad 模拟器截图脚本
# 用法：./scripts/ipad-screenshot.sh <device-id> <name> [url]
# 例：./scripts/ipad-screenshot.sh 24B29F43-... mini
set -e

DEVICE_ID="$1"
NAME="$2"
URL="${3:-http://192.168.31.251:8765/public/index.html}"

SIM=/Applications/Xcode.app/Contents/Developer/usr/bin/simctl
DIR="/Users/yangshijing/Documents/trae_projects/Mineradio- macOS_副本/docs/assets/ipad-baseline"
mkdir -p "$DIR"

echo "[$NAME] boot..."
$SIM boot "$DEVICE_ID" 2>&1 | head -2 || true

echo "[$NAME] wait bootstatus..."
$SIM bootstatus "$DEVICE_ID" -b 2>&1 | tail -3

echo "[$NAME] openurl $URL"
# 先关掉所有 Safari 标签，再 launch Safari 带 URL（避免开在新 tab）
$SIM terminate "$DEVICE_ID" com.apple.mobilesafari 2>/dev/null || true
sleep 1
$SIM launch "$DEVICE_ID" com.apple.mobilesafari "$URL" 2>&1 | head -3 || true

# 等页面加载（iPad 8.3" 启动到完整渲染大约 25-35 秒）
sleep 30

echo "[$NAME] screenshot home"
RAW="$DIR/${NAME}-home-raw.png"
$SIM io "$DEVICE_ID" screenshot "$RAW" 2>&1 | tail -2

# simctl 截图是物理朝向；横屏时图像被转 90° CW，自动 +90° 转正
OUT="$DIR/${NAME}-home.png"
sips -r 90 "$RAW" --out "$OUT" 2>&1 | tail -1
rm -f "$RAW"

echo "[$NAME] done -> $OUT"
