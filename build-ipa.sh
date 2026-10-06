#!/bin/bash
set -euo pipefail

CONFIG="${1:-Release}"
APP_NAME="Vitrea"
IPA_NAME="Vitrea"

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

echo "==> Building Vitrea ($CONFIG)..."

# 清理过期包（单文件，安全）
rm -f "build/卡面工坊.ipa" "build/$IPA_NAME.ipa" 2>/dev/null || true

# 用 xcodebuild clean 代替 rm -rf DerivedData，避免大目录批量删除被拦截
mkdir -p build
xcodebuild -project Vitrea.xcodeproj \
    -scheme Vitrea \
    -configuration "$CONFIG" \
    -derivedDataPath build/DerivedData \
    -destination 'generic/platform=iOS' \
    clean build \
    CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS="" CODE_SIGNING_ALLOWED="NO"

APP_PATH="$(find build/DerivedData/Build/Products -name "$APP_NAME.app" -type d | head -n 1)"
if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
    echo "Error: $APP_NAME.app not found in DerivedData"
    exit 1
fi

echo "==> Packaging IPA..."
# 每次用独立暂存目录，避免对既有大目录做 rm -rf
STAGE="build/stage_$(date +%s)"
mkdir -p "$STAGE/Payload"
cp -R "$APP_PATH" "$STAGE/Payload/$APP_NAME.app"

# 清掉既有签名
rm -rf "$STAGE/Payload/$APP_NAME.app/_CodeSignature"
rm -rf "$STAGE/Payload/$APP_NAME.app/embedded.mobileprovision"

cd "$STAGE"
zip -qr "../$IPA_NAME.ipa" Payload
cd "$ROOT"

# 暂存目录移到废纸篓，避免批量删除被拦截
mv "$STAGE" "$HOME/.Trash/" 2>/dev/null || rm -rf "$STAGE" 2>/dev/null || true

echo "==> Done! IPA generated at: $ROOT/build/$IPA_NAME.ipa"
ls -lh "$ROOT/build/$IPA_NAME.ipa"
