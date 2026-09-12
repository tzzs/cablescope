#!/bin/bash
# 将 CableScopeApp 打包为 macOS .app bundle（调试用途；正式分发建议用 Xcode 工程 + 公证）
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION="${1:-release}"
swift build -c "$CONFIGURATION" --product CableScopeApp

BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path)"
APP_DIR="build/CableScope.app"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>CableScope</string>
    <key>CFBundleDisplayName</key>       <string>CableScope</string>
    <key>CFBundleIdentifier</key>        <string>com.cablescope.app</string>
    <key>CFBundleExecutable</key>        <string>CableScopeApp</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <key>LSUIElement</key>               <true/>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSHumanReadableCopyright</key>  <string>© 2026 CableScope</string>
</dict>
</plist>
PLIST

cp "$BIN_PATH/CableScopeApp" "$APP_DIR/Contents/MacOS/CableScopeApp"

echo "已生成 $APP_DIR"
echo "启动：open $APP_DIR"
