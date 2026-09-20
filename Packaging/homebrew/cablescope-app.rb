# CableScope.app 的 Homebrew formula（从源码构建）。
#
# 为什么 App 会有 formula 和 cask 两条路：
#   cask "cablescope"        下载预编译 DMG。Homebrew 的 cask 子系统**主动**给下载的
#                            app 打 com.apple.quarantine（无用户侧开关可关），因此
#                            必须经 Apple 公证，否则装完打不开。
#   formula "cablescope-app" 在用户机器上编译。本机产物压根不带 quarantine 属性，
#                            Gatekeeper 的首次启动检查不会被触发，ad-hoc 签名即可。
#                            实测：本机构建的 .app 无 quarantine、可直接启动，尽管
#                            `spctl -a` 报 rejected（该评估只对被隔离的文件生效）。
#
# 两条路并存是有意的：cask 体验更好（秒装、自动进 /Applications），formula 不依赖
# Apple 开发者证书。没有证书时只有 formula 可用；有了证书两条都可用，用户自选。
#
# 这是发布到 tzzs/homebrew-tap 的模板：release.yml 每次发版复制过去并替换
# url 与 sha256，因此这里的值只是占位。
class CablescopeApp < Formula
  desc "Inspect USB-C / Thunderbolt cables from the menu bar"
  homepage "https://github.com/tzzs/cablescope"
  url "https://github.com/tzzs/cablescope/archive/refs/tags/v0.0.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"

  depends_on xcode: ["15.0", :build]
  # 与 Package.swift 的 platforms: [.macOS(.v14)] 保持一致（Sonoma = macOS 14）。
  # 注意：formula 里要写符号 :sonoma；">= :sonoma" 是 cask 专用语法，放这里会让 brew 报
  # "unknown or unsupported macOS version"。
  depends_on macos: :sonoma

  def install
    # bundle_app.sh 负责组装 .app（Info.plist、资源、图标、Widget 嵌入、ad-hoc 签名）。
    # 没有 CODESIGN_IDENTITY 时它退到 ad-hoc 签名——这是必需的，完全不签名的 .app 会
    # 让 UNUserNotificationCenter 的签名校验抛 ObjC 异常直接崩掉进程。
    ENV["APP_VERSION"] = version.to_s
    # SwiftPM 自带的构建沙盒与 Homebrew 的沙盒会互相干扰
    ENV["SWIFT_BUILD_FLAGS"] = "--disable-sandbox"
    system "./scripts/bundle_app.sh", "release"

    prefix.install "build/CableScope.app"
  end

  # formula 不能像 cask 那样把 .app 放进 /Applications（Homebrew 只在自己的 prefix
  # 里写文件），所以由用户自行软链——这是 formula 装 GUI 应用的固有代价。
  def caveats
    <<~EOS
      CableScope.app 已安装到：
        #{opt_prefix}/CableScope.app

      让它出现在访达与启动台：
        ln -sfn #{opt_prefix}/CableScope.app /Applications/CableScope.app

      或直接启动：
        open #{opt_prefix}/CableScope.app
    EOS
  end

  test do
    app = prefix/"CableScope.app"
    assert_predicate app/"Contents/MacOS/CableScopeApp", :executable?

    # 资源 bundle 必须在 .app 内部——缺失时 KitLocalization/VendorDirectory 会静默
    # 降级而不是报错，所以这里显式钉住它存在。
    assert_predicate app/"Contents/Resources/CableScope_CableKit.bundle", :directory?

    # 版本号确实被 APP_VERSION 注入了 Info.plist
    plist = app/"Contents/Info.plist"
    assert_match version.to_s,
                 shell_output("/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' #{plist}")

    # 签名完整（ad-hoc 也算有效签名）——签名损坏会让通知功能被整体禁用
    system "codesign", "--verify", "--deep", app
  end
end
