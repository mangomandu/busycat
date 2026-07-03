cask "busycat" do
  version "1.1.2"
  sha256 "58d541f8dbb3fd7d1638bf24faf971508624d2045e01e5110e54854240b32519"

  url "https://github.com/mangomandu/busycat/releases/download/v#{version}/BusyCat-#{version}-macOS.dmg"
  name "BusyCat"
  desc "Menu bar cat whose speed reflects CPU and GPU load"
  homepage "https://github.com/mangomandu/busycat"

  livecheck do
    url :url
    strategy :github_latest
  end

  app "BusyCat.app"

  zap trash: [
    "~/Library/Preferences/com.dlfnek.busycat.plist",
    "~/Library/Saved Application State/com.dlfnek.busycat.savedState",
  ]

  caveats <<~EOS
    BusyCat is not notarized yet. If macOS blocks the first launch, open
    System Settings > Privacy & Security and choose "Open Anyway".
  EOS
end
