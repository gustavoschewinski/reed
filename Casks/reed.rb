# Homebrew cask for Reed.
#
# Homebrew installs casks from a tap repository, so this file only becomes
# installable once it is copied to `Casks/reed.rb` in a repository named
# `homebrew-tap` under the same GitHub account, with `version` and `sha256`
# pointing at a published release:
#
#   shasum -a 256 Reed.dmg
#
# Until then the DMG on the Releases page is the install path, and README.md
# says so.
cask "reed" do
  version "0.1.0"
  # Placeholder until a release exists: `shasum -a 256 Reed.dmg`.
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/gustavoschewinski/reed/releases/download/v#{version}/Reed.dmg"
  name "Reed"
  desc "On-device dictation for macOS"
  homepage "https://github.com/gustavoschewinski/reed"

  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  app "Reed.app"

  zap trash: [
    "~/Library/Application Support/Reed",
    "~/Library/Preferences/com.gustavoschewinski.reed.plist",
  ]
end
