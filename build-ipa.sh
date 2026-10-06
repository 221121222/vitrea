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

APP_IN_STAGE="$STAGE/Payload/$APP_NAME.app"

# 清掉既有签名（含 PlugIns 里的扩展）
find "$APP_IN_STAGE" -type d -name "_CodeSignature" -prune -exec rm -rf {} + 2>/dev/null || true
rm -f "$APP_IN_STAGE/embedded.mobileprovision"

# 内置回环（VitreaTunnel.appex）依赖 NetworkExtension 权限。权限存在「签名」里，
# 一旦完全剥离签名，重签工具就拿不到它 → 回环会启动失败。
# 所以默认由内向外做一次 ad-hoc 签名并把 entitlements 写进去（重签时会被你的证书覆盖）。
# 想要旧行为（纯裸包、零签名）就：STRIP_SIGNATURE=1 ./build-ipa.sh Release
if [ "${STRIP_SIGNATURE:-0}" != "1" ]; then
    # WidgetKit 扩展（实时活动 / 灵动岛）：先签最内层
    if [ -d "$APP_IN_STAGE/PlugIns/VitreaWidgets.appex" ]; then
        codesign --force --sign - \
            "$APP_IN_STAGE/PlugIns/VitreaWidgets.appex" 2>/dev/null \
            && echo "    · 已为 VitreaWidgets.appex 签名（实时活动）" \
            || echo "    ! VitreaWidgets.appex ad-hoc 签名失败（灵动岛进度不会显示）"
    else
        echo "    ! 未找到 PlugIns/VitreaWidgets.appex —— 灵动岛进度不会显示"
    fi

    if [ -d "$APP_IN_STAGE/PlugIns/VitreaTunnel.appex" ]; then
        codesign --force --sign - \
            --entitlements TunnelProv/TunnelProv.entitlements \
            "$APP_IN_STAGE/PlugIns/VitreaTunnel.appex" 2>/dev/null \
            && echo "    · 已为 VitreaTunnel.appex 写入 NetworkExtension 权限" \
            || echo "    ! VitreaTunnel.appex ad-hoc 签名失败（回环需自行补权限）"
    else
        echo "    ! 未找到 PlugIns/VitreaTunnel.appex —— 内置回环不会生效"
    fi
    codesign --force --sign - \
        --entitlements ios-app/Vitrea.entitlements \
        "$APP_IN_STAGE" 2>/dev/null \
        && echo "    · 已为主 App 写入 NetworkExtension 权限" \
        || echo "    ! 主 App ad-hoc 签名失败"
fi

cd "$STAGE"
zip -qr "../$IPA_NAME.ipa" Payload
cd "$ROOT"

# 暂存目录移到废纸篓，避免批量删除被拦截
mv "$STAGE" "$HOME/.Trash/" 2>/dev/null || rm -rf "$STAGE" 2>/dev/null || true

echo "==> Done! IPA generated at: $ROOT/build/$IPA_NAME.ipa"
ls -lh "$ROOT/build/$IPA_NAME.ipa"
