#!/usr/bin/env bash
#
# CableScope.app 一行安装脚本：
#
#   curl -fsSL https://raw.githubusercontent.com/tzzs/cablescope/main/scripts/install.sh | bash
#
# 从最新 GitHub Release 下载预编译 DMG，校验 sha256，把 CableScope.app 放进
# /Applications——不要求用户有 Xcode，也不需要走 Homebrew。
#
# 为什么 curl 装的未公证 app 能直接打开：com.apple.quarantine 是浏览器等下载工具
# 主动打的属性，curl 不打——没有隔离属性，Gatekeeper 的首次启动检查根本不会触发，
# ad-hoc 签名即可运行。（与 formula 本机编译无需公证是同一个原理。）
#
# 环境变量（主要供测试与特殊场景）：
#   CABLESCOPE_TAG          固定版本（如 v0.4.1），默认取 latest release
#   CABLESCOPE_INSTALL_DIR  安装目录，默认 /Applications
#   CABLESCOPE_REPO         仓库坐标，默认 tzzs/cablescope

set -euo pipefail

REPO="${CABLESCOPE_REPO:-tzzs/cablescope}"
INSTALL_DIR="${CABLESCOPE_INSTALL_DIR:-/Applications}"
TAG="${CABLESCOPE_TAG:-}"

fail() { printf 'install: %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "CableScope 仅支持 macOS"
command -v curl >/dev/null 2>&1 || fail "需要 curl"

if [[ -z "$TAG" ]]; then
  TAG="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
    | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p')"
  [[ -n "$TAG" ]] || fail "无法解析 ${REPO} 的最新版本号，可用 CABLESCOPE_TAG=vX.Y.Z 指定"
fi
VERSION="${TAG#v}"
BASE="https://github.com/${REPO}/releases/download/${TAG}"

TMP="$(mktemp -d)"
cleanup() {
  hdiutil detach "${TMP}/mnt" -quiet 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

echo "下载 CableScope-${VERSION}.dmg（${TAG}）…"
curl -fL --progress-bar -o "${TMP}/CableScope.dmg" "${BASE}/CableScope-${VERSION}.dmg" \
  || fail "下载失败：${BASE}/CableScope-${VERSION}.dmg"

# 校验文件自 v0.4.1 之后才随 release 发布，旧 tag 没有资产时降级为提示而非失败。
if curl -fsSL -o "${TMP}/sha256" "${BASE}/CableScope-${VERSION}.dmg.sha256" 2>/dev/null; then
  EXPECTED="$(awk '{print $1}' "${TMP}/sha256")"
  ACTUAL="$(shasum -a 256 "${TMP}/CableScope.dmg" | awk '{print $1}')"
  [[ "$EXPECTED" == "$ACTUAL" ]] \
    || fail "sha256 校验不通过（期望 ${EXPECTED}，实际 ${ACTUAL}），中止安装"
  echo "sha256 校验通过。"
else
  echo "警告：${TAG} 未发布校验文件，跳过完整性校验。" >&2
fi

mkdir "${TMP}/mnt"
hdiutil attach -nobrowse -quiet "${TMP}/CableScope.dmg" -mountpoint "${TMP}/mnt" \
  || fail "DMG 挂载失败"
[[ -d "${TMP}/mnt/CableScope.app" ]] || fail "DMG 内未找到 CableScope.app"

DEST="${INSTALL_DIR}/CableScope.app"
[[ -w "$INSTALL_DIR" ]] || fail "${INSTALL_DIR} 不可写；用 sudo 重跑，或设置 CABLESCOPE_INSTALL_DIR 指向可写目录"
if [[ -e "$DEST" ]]; then
  echo "覆盖已存在的 ${DEST}"
  # 覆盖运行中的 app 的磁盘内容是允许的，但内存里还是旧版本，必须提醒重启。
  if pgrep -x CableScopeApp >/dev/null 2>&1; then
    echo "检测到 CableScope 正在运行，安装后请退出并重新打开以生效。"
  fi
  rm -rf "$DEST"
fi
ditto "${TMP}/mnt/CableScope.app" "$DEST"

echo "✅ CableScope ${VERSION} 已安装到 ${DEST}"
echo "启动：open \"${DEST}\"（菜单栏工具，启动后出现在菜单栏）"
