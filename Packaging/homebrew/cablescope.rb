# CableScope.app 的 Homebrew cask（安装 notarized DMG）。
#
# 这是发布到 tzzs/homebrew-tap tap 的模板：.github/workflows/release.yml
# 在每次发版时会把此文件复制过去、替换 version 与 sha256（用实际 DMG 的哈希）后推送，
# 因此本文件里的 version/sha256 只是占位值，不需要手动同步。
#
# 注意：
# - DMG 文件名需与 .github/workflows/release.yml 产物保持一致：CableScope-<version>.dmg
cask "cablescope" do
  version "0.1.0"
  sha256 :no_check

  url "https://github.com/tzzs/cablescope/releases/download/v#{version}/CableScope-#{version}.dmg"
  name "CableScope"
  desc "USB-C / Thunderbolt 数据线检测菜单栏工具（充电、传输速率、e-marker、线缆评级）"
  homepage "https://github.com/tzzs/cablescope"

  depends_on macos: ">= :ventura"

  app "CableScope.app"

  zap trash: [
    "~/Library/Application Support/CableScope",
    "~/Library/Preferences/com.cablescope.app.plist",
  ]
end
