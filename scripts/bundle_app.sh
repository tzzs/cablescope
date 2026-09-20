#!/bin/bash
# 将 CableScopeApp 打包为 macOS .app bundle（调试用途 + CI 打包；正式分发需 Developer ID 签名 + 公证）
#
# 环境变量（均可省略，省略时保持原有行为）：
# - APP_VERSION        写入 Info.plist 的 CFBundleShortVersionString（缺省 0.1.0）
# - CODESIGN_IDENTITY  Developer ID 签名身份（缺省空 = 不签名，产出未签名 bundle；
#                      CI 无证书环境由此保持可用）。设置后使用 hardened runtime 签名。
# - SWIFT_BUILD_FLAGS  追加给 swift build 的额外参数（按空格分词）。Homebrew 的
#                      cablescope-app formula 用它传 --disable-sandbox：SwiftPM 自带的
#                      构建沙盒与 Homebrew 的沙盒会互相干扰。
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION="${1:-release}"
APP_VERSION="${APP_VERSION:-0.1.0}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
SWIFT_BUILD_FLAGS="${SWIFT_BUILD_FLAGS:-}"

# SWIFT_BUILD_FLAGS 故意不加引号：需要按空格分词成多个参数，空值时展开为无参数。
# shellcheck disable=SC2086
swift build -c "$CONFIGURATION" --product CableScopeApp $SWIFT_BUILD_FLAGS

# shellcheck disable=SC2086
BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path $SWIFT_BUILD_FLAGS)"
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
    <key>CFBundleDevelopmentRegion</key> <string>zh-Hans</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>zh-Hans</string>
        <string>en</string>
    </array>
</dict>
</plist>
PLIST

cp "$BIN_PATH/CableScopeApp" "$APP_DIR/Contents/MacOS/CableScopeApp"

# ---- SwiftPM 资源 bundle（如 CableKit 的 CableScope_CableKit.bundle，内含 usb-vendors.json）----
# 放进 Contents/Resources/（标准 macOS app bundle 位置）。历史上放在 .app 包根目录
# 是为了迁就 SwiftPM 生成的 resource_bundle_accessor.swift（用 Bundle.main.bundleURL
# 查找）——但本项目所有资源查找早已改用自建的安全探测（VendorDirectory/
# KitLocalization/AppLocalization/BrandGlyph 统一的候选路径列表，均把
# Bundle.main.resourceURL 排第一位、Bundle.main.bundleURL 只作兜底），不依赖那份
# 自动生成代码，可以放回标准位置。放根目录还有个真实代价：codesign --deep 对
# Contents/ 之外的内容一律报 "unsealed contents present in the bundle root" 并以
# 非零退出码中断整个签名（ad-hoc/正式签名身份下都实测复现过，之前脚本会在这一步
# 静默提前退出，后面"已生成 App 图标"往后的步骤全部不会执行）；Contents/Resources/
# 是签名正常覆盖并密封的标准路径，不会有这个问题。
shopt -s nullglob
RESOURCE_BUNDLES=("$BIN_PATH"/*.bundle)
shopt -u nullglob
if (( ${#RESOURCE_BUNDLES[@]} > 0 )); then
    for bundle in "${RESOURCE_BUNDLES[@]}"; do
        cp -R "$bundle" "$APP_DIR/Contents/Resources/"
        echo "已嵌入资源 bundle：$(basename "$bundle")"
    done
fi

# ---- App 自身的 .lproj 额外平铺一份到 Contents/Resources/ ----
# SwiftUI 的 Text/Label(LocalizedStringKey) 默认只认 Bundle.main 自身直接下辖的
# *.lproj（不会钻进上面那个嵌套的 CableScope_CableScopeApp.bundle 里找，即便现在
# 这个 bundle 本身也在 Contents/Resources/ 下，嵌套关系没变）；真正的 Xcode 原生
# target 打包时资源直接编译进 Contents/Resources，没有这层嵌套，这里手动补一份
# 形成同等效果——CableScopeApp 自己的 Localizable.xcstrings 才会在语言切换时生效。
# 只平铺 CableScopeApp 自己的语言目录，CableKit 的文案走的是自建的 KitLocalization
# （显式传 locale），不依赖这条路径。
APP_RESOURCE_BUNDLE="$APP_DIR/Contents/Resources/CableScope_CableScopeApp.bundle/Contents/Resources"
if [[ -d "$APP_RESOURCE_BUNDLE" ]]; then
    shopt -s nullglob
    for lproj in "$APP_RESOURCE_BUNDLE"/*.lproj; do
        cp -R "$lproj" "$APP_DIR/Contents/Resources/"
        echo "已平铺语言目录：$(basename "$lproj")"
    done
    shopt -u nullglob
fi

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
    # 至少 ad-hoc 签名（身份 "-"，不需要证书）：完全不签名的 .app 在较新 macOS 上会让
    # UNUserNotificationCenter.current() 内部校验签名失败，直接抛未捕获的 Objective-C
    # 异常崩掉整个进程（Swift try/catch 接不住）——本地调试构建也会真的点开设置页触发，
    # 不是只有分发包才会踩到。ad-hoc 签名不提供身份验证/不能公证，但足够让代码签名校验
    # 通过，本地调试链路不受影响。
    echo "未设置 CODESIGN_IDENTITY，使用 ad-hoc 签名（无身份验证，仅避免未签名崩溃）"
    codesign --force --deep --sign - "$APP_DIR"
fi

echo "已生成 $APP_DIR"
echo "启动：open $APP_DIR"
