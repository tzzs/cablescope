# CableScope CLI 的 Homebrew formula（源码编译安装）。
#
# 注意：
# - 开源后把本文件中的 OWNER 占位符替换为实际 GitHub 用户/组织名（url / homepage / 注释）。
# - 每次发版需同步更新下方 version 字段（与 GitHub tag v0.x.y 一致）。
# - 后续建议：接入 brew test-bot 为常用 macOS 版本构建并托管 bottle，加速安装。
class CableScopeCli < Formula
  desc "USB-C / Thunderbolt 数据线检测 CLI（充电、传输速率、e-marker、线缆评级）"
  homepage "https://github.com/OWNER/cablescope"
  url "https://github.com/OWNER/cablescope/archive/refs/tags/v#{version}.tar.gz"
  head "https://github.com/OWNER/cablescope.git", branch: "main"
  version "0.1.0"

  # 项目最低支持 macOS 13（Ventura）；swift build 依赖命令行工具（CLT 即可，无需完整 Xcode）
  depends_on macos: :ventura

  def install
    system "swift", "build", "-c", "release", "--product", "CableScopeCLI"
    bin.install ".build/release/CableScopeCLI" => "cablescope"
  end

  test do
    system "#{bin}/cablescope", "--help"
  end
end
