class Buildrhookscli < Formula
  APP_VERSION = File.read(File.join(__dir__, "VERSION")).strip.freeze

  desc "Relay Codex hook events into BuildrAI's repository-local raw hook queue."
  homepage "https://github.com/michaelversus/BuildrHooksCLI"
  url "https://github.com/michaelversus/BuildrHooksCLI.git", tag: APP_VERSION
  version APP_VERSION

  depends_on "xcode": [:build]

  def install
    system "make", "install", "prefix=#{prefix}"
  end

  test do
    system "#{bin}/buildrhooks", "--version"
  end
end
