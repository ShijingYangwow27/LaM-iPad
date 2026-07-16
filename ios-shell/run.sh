#!/usr/bin/env bash
# ============================================================
#  Mineradio iOS Shell 一键 build + install + launch
#  Usage:
#    ./ios-shell/run.sh                 # 默认: build + install + launch
#    ./ios-shell/run.sh build           # 只 build
#    ./ios-shell/run.sh install         # install + launch
#    ./ios-shell/run.sh open            # 在 Xcode 中打开项目
#  配置：
#    SIM_UDID  默认 iPad Pro 13-inch (M5)
#    APP_ID    默认 com.mineradio.app
#    DEV_URL   默认 http://192.168.31.251:3000/
# ============================================================
set -e

cd "$(dirname "$0")"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
export PATH="$DEVELOPER_DIR/usr/bin:$DEVELOPER_DIR/bin:$PATH"

SIM_UDID="${SIM_UDID:-E84A828A-C2DD-4569-BA74-5005156740E5}"
APP_ID="${APP_ID:-com.mineradio.app}"
PROJECT="MineradioApp.xcodeproj"
SCHEME="MineradioApp"
CONFIG="Debug"
DERIVED="build"
APP_PATH="$DERIVED/Build/Products/${CONFIG}-iphonesimulator/Mineradio.app"

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
  step "xcodebuild (destination=$SIM_UDID)"
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,id=$SIM_UDID" \
    -configuration "$CONFIG" \
    -derivedDataPath "$DERIVED" \
    build | tail -3
  [ -d "$APP_PATH" ] || die "build 失败，未找到 $APP_PATH"
  ok "build 成功 → $APP_PATH"
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
  build)   build ;;
  install) build && install ;;
  open)    gen; open "$PROJECT" ;;
  all|"")  build && install ;;
  *)       die "未知命令: $1（可用: build | install | open | all）" ;;
esac

ok "完成"
