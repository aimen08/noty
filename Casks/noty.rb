cask "noty" do
  arch intel: "-intel"

  # The release workflow rewrites the version and both checksums on every release.
  version "1.9.2"
  sha256 arm:   "22565cb29d9a9c65f47c8015dcaf3ae1483592ca4b2cbdea26cd17dcc71b8b7d",
         intel: "69684810ef857b6b08adbcd814fbfbb25158c5543d98ab2b411a7d83ddf201c9"

  url "https://github.com/aimen08/noty/releases/download/v#{version}/Noty#{arch}.dmg"
  name "Noty"
  desc "Sticky notes that live at the edge of the screen"
  homepage "https://github.com/aimen08/noty"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: :sequoia

  app "Noty.app"

  zap trash: [
    "~/Library/Application Support/Noty",
    "~/Library/Caches/app.noty.Noty",
    "~/Library/HTTPStorages/app.noty.Noty",
    "~/Library/Preferences/app.noty.Noty.plist",
  ]
end
