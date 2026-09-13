# CableScope.app 的 Homebrew cask（安装 notarized DMG）。
#
# 注意：
# - 开源后把本文件中的 OWNER 占位符替换为实际 GitHub 用户/组织名（url / homepage / 注释）。
# - 每次发版需同步更新 version 与 sha256（正式发布后把 :no_check 替换为 DMG 的实际 sha256）。
# - DMG 文件名与 .github/workflows/release.yml 产物保持一致：CableScope-<version>.dmg
cask "cablescope" do
  version "0.1.0"
  sha256 :no_check

  url "https://github.com/OWNER/cablescope/releases/download/v#{version}/CableScope-#{version}.dmg"
  name "CableScope"
  desc "USB-C / Thunderbolt 数据线检测菜单栏工具（充电、传输速率、e-marker、线缆评级）"
  homepage "https://github.com/OWNER/cablescope"

  depends_on macos: ">= :ventura"

  app "CableScope.app"

  zap trash: [
    "~/Library/Application Support/CableScope",
    "~/Library/Preferences/com.cablescope.app.plist",
  ]
end
