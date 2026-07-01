cask "busycat" do
  version "1.1.1"
  sha256 "97f0eee20b48aa2a891f43da8fcd0722e9ef34891fece6575f0da54714e9b020"

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
    "~/Library/Preferences/com.mangomandu.BusyCat.plist",
    "~/Library/Saved Application State/com.mangomandu.BusyCat.savedState",
  ]

  caveats <<~EOS
    BusyCat is not notarized yet. If macOS blocks the first launch, open
    System Settings > Privacy & Security and choose "Open Anyway".
  EOS
end
