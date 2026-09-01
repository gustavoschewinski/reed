cask "reed" do
  # NOTE TO THE OWNER: this file describes the cask, but `brew install
  # --cask gustavoschewinski/tap/reed` (the line in README.md) does not
  # work yet. Homebrew casks are installed from a *tap* repository named
  # `homebrew-<tap>` — here, `gustavoschewinski/homebrew-tap` — and that
  # repository does not exist. The release workflow in this repo also
  # never pushes to one; it only builds and uploads `Reed.dmg` to GitHub
  # Releases.
  #
  # To make the Homebrew install work:
  #   1. Create a repository named `homebrew-tap` under this GitHub account.
  #   2. Copy this file into it as `Casks/reed.rb` (path matters to Homebrew).
  #   3. After each release, update `version` and `sha256` below (see the
  #      note on `sha256`) and push the change to that tap repository —
  #      by hand, or by adding a step to the release workflow that does it.
  # Until all three are done, keep README.md pointing at the DMG as the
  # primary install path, not this command.
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
