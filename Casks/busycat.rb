cask "busycat" do
  version "1.1.6"
  sha256 "98babb604697e50c9216a3c91c64c6f3929eaae0c9f25520cab741cec94de6bf"

  url "https://github.com/mangomandu/busycat/releases/download/v#{version}/BusyCat-#{version}-macOS.dmg"
  name "BusyCat"
  desc "Menu bar cat driven by CPU and GPU compute load"
  homepage "https://github.com/mangomandu/busycat"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "BusyCat.app"

  zap trash: [
    "~/Library/Preferences/com.dlfnek.busycat.plist",
    "~/Library/Saved Application State/com.dlfnek.busycat.savedState",
  ]

  caveats <<~EOS
    BusyCat is not notarized yet. If macOS blocks the first launch, open
    System Settings > Privacy & Security and choose "Open Anyway".
    BusyCat currently supports Apple Silicon Macs only.
  EOS
end
