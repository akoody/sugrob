# Homebrew cask template. Fill in the sha256 from a release SHA256SUMS.txt,
# then publish it in a tap repository named homebrew-sugrob.
cask "sugrob" do
  version "3.2.0"
  sha256 :no_check

  url "https://github.com/akoody/sugrob/releases/download/v#{version}/Sugrob.dmg"
  name "Sugrob"
  desc "Living snow for the macOS desktop"
  homepage "https://github.com/akoody/sugrob"

  depends_on macos: ">= :ventura"

  app "Sugrob.app"

  zap trash: "~/Library/Preferences/io.github.sugrob.app.plist"
end
