#!/bin/bash
# 将 CableScopeApp 打包为 macOS .app bundle（调试用途 + CI 打包；正式分发需 Developer ID 签名 + 公证）
#
# 环境变量（均可省略，省略时保持原有行为）：
# - APP_VERSION        写入 Info.plist 的 CFBundleShortVersionString（缺省 0.1.0）
# - CODESIGN_IDENTITY  Developer ID 签名身份（缺省空 = 不签名，产出未签名 bundle；
#                      CI 无证书环境由此保持可用）。设置后使用 hardened runtime 签名。
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION="${1:-release}"
APP_VERSION="${APP_VERSION:-0.1.0}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
swift build -c "$CONFIGURATION" --product CableScopeApp

BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path)"
APP_DIR="build/CableScope.app"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>CableScope</string>
    <key>CFBundleDisplayName</key>       <string>CableScope</string>
    <key>CFBundleIdentifier</key>        <string>com.cablescope.app</string>
    <key>CFBundleExecutable</key>        <string>CableScopeApp</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>LSUIElement</key>               <true/>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSHumanReadableCopyright</key>  <string>© 2026 CableScope</string>
</dict>
</plist>
PLIST

cp "$BIN_PATH/CableScopeApp" "$APP_DIR/Contents/MacOS/CableScopeApp"

# ---- 隐私清单（MAS 提审要求；DMG 分发同样无害）----
if [[ -f "Packaging/privacy/PrivacyInfo.xcprivacy" ]]; then
    cp "Packaging/privacy/PrivacyInfo.xcprivacy" "$APP_DIR/Contents/Resources/"
fi

# ---- App 图标：从全出血 1024 master 生成经典 .icns（全 macOS 版本兼容，无需 actool）----
# master 即 appiconset 的 512@2x 槽位（1024×1024），与 Xcode 路径同源
ICON_MASTER="Packaging/assets/AppIcon.xcassets/AppIcon.appiconset/icon_512x512@2x.png"
if [[ -f "$ICON_MASTER" ]] && command -v iconutil >/dev/null 2>&1; then
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for spec in "16 16" "32 32" "128 128" "256 256" "512 512"; do
        set -- $spec
        sips -z "$1" "$1" "$ICON_MASTER" --out "$ICONSET/icon_${2}x${2}.png" >/dev/null 2>&1
        sips -z "$(($1 * 2))" "$(($1 * 2))" "$ICON_MASTER" --out "$ICONSET/icon_${2}x${2}@2x.png" >/dev/null 2>&1
    done
    if iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns" 2>/dev/null; then
        echo "已生成 App 图标（AppIcon.icns）"
    else
        echo "⚠️ iconutil 生成 icns 失败，bundle 将无图标（不影响功能）"
    fi
fi

# ---- Widget 扩展：SwiftPM 产不出 appex，用 xcodebuild 补建并嵌入 ----
# 依赖链：xcodegen（生成工程）→ xcodebuild（构建 appex）；任一环节缺失则跳过并提示。
if command -v xcodegen >/dev/null 2>&1 && command -v xcodebuild >/dev/null 2>&1; then
    [[ -d CableScope.xcodeproj ]] || xcodegen generate >/dev/null 2>&1
    if xcodebuild -project CableScope.xcodeproj -scheme CableScopeWidget \
        -configuration Release build CODE_SIGNING_ALLOWED=NO >/dev/null 2>&1; then
        BUILT_DIR="$(xcodebuild -project CableScope.xcodeproj -scheme CableScopeWidget \
            -configuration Release -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR =/{print $3}' | head -1)"
        WIDGET_APPEX="$(find "$BUILT_DIR" -maxdepth 1 -name '*.appex' 2>/dev/null | head -1)"
        if [[ -n "$WIDGET_APPEX" ]]; then
            mkdir -p "$APP_DIR/Contents/PlugIns"
            cp -R "$WIDGET_APPEX" "$APP_DIR/Contents/PlugIns/"
            echo "已嵌入 Widget 扩展：$(basename "$WIDGET_APPEX")"
        else
            echo "⚠️ 未找到构建产物 appex，跳过 Widget 嵌入"
        fi
    else
        echo "⚠️ xcodebuild 构建 Widget 失败，跳过嵌入（App 本体不受影响）"
    fi
else
    echo "⚠️ 缺 xcodegen/xcodebuild，跳过 Widget 嵌入（纯 SwiftPM 环境）"
fi

if [[ -n "$CODESIGN_IDENTITY" ]]; then
    echo "使用签名身份：$CODESIGN_IDENTITY（hardened runtime + trusted timestamp）"
    codesign --force --deep --sign "$CODESIGN_IDENTITY" \
        --options runtime --timestamp "$APP_DIR"
else
    echo "未设置 CODESIGN_IDENTITY，跳过签名（未签名 bundle）"
fi

echo "已生成 $APP_DIR"
echo "启动：open $APP_DIR"
