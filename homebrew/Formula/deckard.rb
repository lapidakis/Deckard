# Deckard Homebrew formula
#
# This file is the canonical content of `Formula/deckard.rb` in the
# `lapidakis/homebrew-deckard` tap repo. It is committed here as the
# starting template; the release workflow (.github/workflows/release.yml)
# rewrites the URL + sha256 + version on each tag push and pushes the
# updated formula to the tap repo.
#
# Users:  brew tap lapidakis/deckard && brew install deckard
# Maintainers: see docs/releasing.md → "Homebrew tap" for the one-time setup.
class Deckard < Formula
  desc "Mac-resident MCP server proxying Apple-native services to AI agents"
  homepage "https://github.com/lapidakis/Deckard"
  version "1.0.0-beta.3"
  url "https://github.com/lapidakis/Deckard/releases/download/v1.0.0-beta.3/deckard-v1.0.0-beta.3-arm64.tar.gz"
  sha256 "6dc5569cebd4e026849dfd133b706d6049c0514ff2bfb8abb3510c9900a00921"
  license "MIT"

  # Apple Silicon only — Deckard's release pipeline currently targets arm64.
  # An Intel slice could ship later if there's demand, but EventKit /
  # AppleScript bridges have only been verified on Apple Silicon.
  depends_on arch: :arm64
  depends_on macos: :sonoma

  livecheck do
    url :stable
    strategy :github_latest
  end

  def install
    bin.install "deckard"
  end

  def caveats
    <<~EOS
      Deckard installed the daemon binary. Finish setup with:

        deckard config init
        deckard auth add default --profile trusted
        deckard install

      `deckard install` registers ~/Library/LaunchAgents/com.lapidakis.deckard.plist
      and bootstraps the daemon under launchd. The first call to each
      surface (Mail / Calendar / Reminders / Apple Events) triggers a
      one-time macOS permission prompt; click Allow.

      Updates: use `brew upgrade deckard`. `deckard self-update` refuses
      to swap a Homebrew-managed binary because brew's metadata would
      mismatch and the next `brew upgrade` would re-download to undo it.

      Docs: https://github.com/lapidakis/Deckard
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/deckard version")
  end
end
