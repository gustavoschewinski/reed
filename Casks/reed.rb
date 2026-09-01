cask "reed" do
  version "0.1.0"
  # Placeholder — the real value doesn't exist until v0.1.0 is tagged and
  # the release workflow has built Reed.dmg. After the release:
  #   curl -fL -o Reed.dmg https://github.com/gustavoschewinski/reed/releases/download/v0.1.0/Reed.dmg
  #   shasum -a 256 Reed.dmg
  # and paste the result in below.
  sha256 "REPLACE_WITH_ACTUAL_SHA256_AFTER_RELEASE"

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
