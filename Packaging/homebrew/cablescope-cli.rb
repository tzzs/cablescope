# CableScope CLI 的 Homebrew formula（从源码构建）。
#
# 这是发布到 tzzs/homebrew-tap 的模板：.github/workflows/release.yml 在每次发版时
# 把此文件复制过去、替换 url 与 sha256（GitHub 按 tag 自动生成的源码 tarball 的哈希）
# 后推送，因此本文件里的 url/sha256 只是占位值，不需要手动同步。
#
# 为什么 CLI 走 formula 而不是 cask：formula 在用户机器上从源码编译，产物不带
# quarantine 属性，不需要 Developer ID 签名或公证。cask 分发的是预编译 DMG，
# 必须公证，否则装完会被 Gatekeeper 拦下——两条渠道的成本差异来自 macOS 的
# 安全模型，不是 Homebrew 的规定。
#
# 三个名字故意不一致，各自服务于不同的场景：
#   包名   cablescope-cli   用户敲 `brew install`，要和 cask "cablescope"（装
#                           CableScope.app）区分开，同一个 tap 内不撞 token
#   命令名 cablescope       用户在终端敲，要短
#   target CableScopeCLI    源码层面的标识（Package.swift），不该出现在用户命令里
class CablescopeCli < Formula
  desc "Inspect USB-C / Thunderbolt cables from your terminal"
  homepage "https://github.com/tzzs/cablescope"
  url "https://github.com/tzzs/cablescope/archive/refs/tags/v0.0.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"

  depends_on xcode: ["15.0", :build]
  # 与 Package.swift 的 platforms: [.macOS(.v14)] 保持一致（Sonoma = macOS 14）
  depends_on macos: ">= :sonoma"

  def install
    # --disable-sandbox：SwiftPM 自带的构建沙盒与 Homebrew 的沙盒会互相干扰
    system "swift", "build", "-c", "release",
           "--product", "CableScopeCLI", "--disable-sandbox"

    # CableKit 的资源（usb-vendors.json、英文 .strings）是一个独立的
    # CableScope_CableKit.bundle，与可执行文件分开产出——两者必须装进同一个目录。
    #
    # 不能直接 bin.install 可执行文件：经 bin 里的符号链接调用时 `Bundle.main`
    # 停在 bin/（不解析符号链接），CableKitResourceBundle.probe() 的候选 1/3
    # 都会落空；唯一命中的是候选 2（`Bundle(for:).resourceURL`，走 dyld 镜像
    # 路径、会解析符号链接）指向的 libexec/。实测验证见 AGENTS.md。
    libexec.install ".build/release/CableScopeCLI"
    libexec.install ".build/release/CableScope_CableKit.bundle"
    bin.install_symlink libexec/"CableScopeCLI" => "cablescope"
  end

  test do
    # 与 RealEnvironmentSmokeTests 同一立场：不假设任何硬件存在。`brew test`
    # 跑在什么都没插的机器上也必须正常退出——无设备时走降级分支属合法结果。
    assert_match "CableScope", shell_output("#{bin}/cablescope pretty")

    # 快照路径端到端跑通且产出合法 JSON（解析失败会抛异常让 test 失败）。
    require "json"
    snapshot = JSON.parse(shell_output("#{bin}/cablescope snapshot"))
    assert snapshot.key?("power"), "snapshot 缺少 power 字段"
    assert snapshot.key?("sessions"), "snapshot 缺少 sessions 字段"

    # 注意：以上都**不能**证明 CableScope_CableKit.bundle 装到位了——资源缺失时
    # KitLocalization/VendorDirectory 的设计就是静默降级（probe() 失败返回 nil），
    # 输出不会变化也不会报错。要钉住那一点需要一个只有 bundle 在位才出现的
    # 输出特征，目前没有稳定的候选（厂商名依赖真实插着线缆）。
  end
end
