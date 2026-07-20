#!/usr/bin/env bash
# ============================================================
#  Mineradio iOS Shell 一键 build / archive / install / launch
#  Usage:
#    ./ios-shell/run.sh                 # 默认: 模拟器 build + install + launch
#    ./ios-shell/run.sh build           # 只 build
#    ./ios-shell/run.sh install         # install + launch (仅模拟器)
#    ./ios-shell/run.sh open            # 在 Xcode 中打开项目
#    ./ios-shell/run.sh device          # 真机: archive 出 .xcarchive (供 Xcode Organizer / SideStore / Sideloadly 导出 IPA)
#  配置（环境变量）：
#    SIM_UDID      默认 iPad Pro 13-inch (M5) 模拟器
#    DEVICE_UDID   真机 UDID（设置后 build/device 走真机）
#    WEB_BASE_URL  WebView 加载地址，注入 App 的 Info.plist（如 http://192.168.1.10:3001）；不填则用 project.yml 默认
#    TEAM_ID       真机签名 Team（可选，exportArchive 时用）
# ============================================================
set -e

cd "$(dirname "$0")"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
export PATH="$DEVELOPER_DIR/usr/bin:$DEVELOPER_DIR/bin:$PATH"

SIM_UDID="${SIM_UDID:-E84A828A-C2DD-4569-BA74-5005156740E5}"
DEVICE_UDID="${DEVICE_UDID:-}"
WEB_BASE_URL="${WEB_BASE_URL:-}"
TEAM_ID="${TEAM_ID:-}"
APP_ID="${APP_ID:-com.mineradio.app}"
PROJECT="MineradioApp.xcodeproj"
SCHEME="MineradioApp"
CONFIG="Debug"
DERIVED="build"

# 真机模式判定
if [ -n "$DEVICE_UDID" ]; then
  DESTINATION="platform=iOS,id=$DEVICE_UDID"
  APP_PATH="$DERIVED/Build/Products/${CONFIG}-iphoneos/Mineradio.app"
  ARCHIVE_PATH="$DERIVED/Mineradio-device.xcarchive"
else
  DESTINATION="platform=iOS Simulator,id=$SIM_UDID"
  APP_PATH="$DERIVED/Build/Products/${CONFIG}-iphonesimulator/Mineradio.app"
  ARCHIVE_PATH="$DERIVED/Mineradio-sim.xcarchive"
fi

# 把 WEB_BASE_URL 作为构建期 Info.plist 注入（覆盖 project.yml 默认值）
BUILD_SETTINGS=()
if [ -n "$WEB_BASE_URL" ]; then
  BUILD_SETTINGS+=("INFOPLIST_KEY_WEB_BASE_URL=$WEB_BASE_URL")
fi

step() { printf "\n\033[1;33m▶ %s\033[0m\n" "$*"; }
ok()   { printf "\033[1;32m✓ %s\033[0m\n" "$*"; }
die()  { printf "\033[1;31m✗ %s\033[0m\n" "$*" >&2; exit 1; }

gen() {
  step "生成 Xcode 项目 (xcodegen)"
  if [ ! -d "$PROJECT" ] || [ project.yml -nt "$PROJECT" ]; then
    npx -y -p xcodegen xcodegen generate
    ok "已生成 $PROJECT"
  else
    ok "$PROJECT 已存在，跳过"
  fi
}

build() {
  gen
  step "xcodebuild (destination=$DESTINATION)"
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "$DESTINATION" \
    -configuration "$CONFIG" \
    -derivedDataPath "$DERIVED" \
    "${BUILD_SETTINGS[@]}" \
    build | tail -3
  [ -d "$APP_PATH" ] || die "build 失败，未找到 $APP_PATH"
  ok "build 成功 → $APP_PATH"
}

# 真机：archive 出 .xcarchive，便于 Xcode Organizer / SideStore / Sideloadly 导出 IPA
archive() {
  gen
  step "xcodebuild archive (destination=$DESTINATION)"
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "$DESTINATION" \
    -configuration "$CONFIG" \
    -derivedDataPath "$DERIVED" \
    -archivePath "$ARCHIVE_PATH" \
    "${BUILD_SETTINGS[@]}" \
    archive | tail -5
  [ -d "$ARCHIVE_PATH" ] || die "archive 失败，未找到 $ARCHIVE_PATH"
  ok "archive 成功 → $ARCHIVE_PATH"
  echo "下一步：Xcode → Window → Organizer 导出 IPA，或用 SideStore / Sideloadly 直接签装此 .xcarchive 内的 App"
}

install() {
  step "确保 simulator 已 boot ($SIM_UDID)"
  xcrun simctl bootstatus "$SIM_UDID" -b 2>/dev/null || true
  step "安装 app"
  xcrun simctl install "$SIM_UDID" "$APP_PATH"
  ok "已安装"
  step "启动 app ($APP_ID)"
  xcrun simctl launch "$SIM_UDID" "$APP_ID"
  ok "已启动"
}

case "${1:-all}" in
  build)          build ;;
  archive|device) archive ;;
  install)        build && install ;;
  open)           gen; open "$PROJECT" ;;
  all|"")         build && install ;;
  *)              die "未知命令: $1（可用: build | archive/device | install | open | all）" ;;
esac

ok "完成"
