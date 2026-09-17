#!/usr/bin/env ruby
# Use only published download assets when building the live site. PR previews
# keep the version being prepared in source; no credentials enter site output.
require 'json'
require 'yaml'
require 'time'

abort 'usage: sync-release.rb RELEASE_JSON [RELEASE_YAML]' unless (1..2).cover?(ARGV.length)
release = JSON.parse(File.read(ARGV[0]))
destination = ARGV[1] || File.join(__dir__, '_data/release.yml')
tag = release.fetch('tag_name')
abort 'expected a published stable release' unless tag.match?(/\Av\d+\.\d+\.\d+\z/) &&
  release['draft'] == false && release['prerelease'] == false && release['published_at']
version = tag.delete_prefix('v')
repository = 'https://github.com/namJeongwan/duckpad'
abort 'unexpected release URL' unless release['html_url'] == "#{repository}/releases/tag/#{tag}"
assets = release.fetch('assets').to_h { |asset| [asset.fetch('name'), asset] }
data = YAML.safe_load(File.read(destination))
data['version'] = version
data['date'] = Time.iso8601(release.fetch('published_at')).utc.strftime('%B %-d, %Y')
data['url'] = release.fetch('html_url')
{'dmg' => "Duckpad-#{version}-universal.dmg", 'zip' => "Duckpad-#{version}-universal.zip",
 'checksums' => 'SHA256SUMS.txt'}.each do |kind, name|
  asset = assets.fetch(name)
  expected_url = "#{repository}/releases/download/#{tag}/#{name}"
  abort "unavailable or unexpected asset: #{name}" unless asset['state'] == 'uploaded' &&
    asset['browser_download_url'] == expected_url && asset.fetch('size').positive?
  data[kind] = expected_url
  data["#{kind}_size"] = format('%.1f MB', asset.fetch('size') / 1_000_000.0) unless kind == 'checksums'
end
# Failures above leave the source file intact and prevent deployment.
File.write(destination, YAML.dump(data))
puts "Website downloads: #{tag}"
