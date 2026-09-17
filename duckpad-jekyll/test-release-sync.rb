require 'minitest/autorun'
require 'tmpdir'
require 'json'
require 'yaml'
require 'open3'
require 'rbconfig'

class ReleaseSyncTest < Minitest::Test
  def published_release
    base = 'https://github.com/namJeongwan/duckpad/releases'
    { 'tag_name' => 'v0.6.4', 'draft' => false, 'prerelease' => false,
      'published_at' => '2026-09-17T03:56:43Z', 'html_url' => "#{base}/tag/v0.6.4",
      'assets' => ['Duckpad-0.6.4-universal.dmg', 'Duckpad-0.6.4-universal.zip', 'SHA256SUMS.txt'].map do |name|
        { 'name' => name, 'state' => 'uploaded', 'size' => 25_000_000,
          'browser_download_url' => "#{base}/download/v0.6.4/#{name}" }
      end }
  end

  def run_sync(release)
    Dir.mktmpdir('duckpad-release-sync-') do |root|
      input = File.join(root, 'release.json')
      output = File.join(root, 'release.yml')
      original = File.read(File.join(__dir__, '_data/release.yml'))
      File.write(input, JSON.dump(release))
      File.write(output, original)
      _, _, status = Open3.capture3(RbConfig.ruby, File.join(__dir__, 'sync-release.rb'), input, output)
      yield status, YAML.safe_load(File.read(output)), File.read(output), original
    end
  end

  def test_unpublished_source_version_uses_published_assets_consistently
    run_sync(published_release) do |status, data, _, _|
      assert status.success?
      assert_equal '0.6.4', data.fetch('version')
      assert_equal '13', data.fetch('minimum_macos')
      assert_equal 'September 17, 2026', data.fetch('date')
      assert_equal '25.0 MB', data.fetch('dmg_size')
      %w[url dmg zip checksums].each { |key| assert_includes data.fetch(key), '/v0.6.4' }
    end
  end

  def test_missing_unpublished_or_unexpected_assets_never_replace_download_data
    variants = []
    variants << published_release.tap { |r| r['assets'].pop }
    variants << published_release.tap { |r| r['draft'] = true }
    variants << published_release.tap { |r| r['prerelease'] = true }
    variants << published_release.tap { |r| r['assets'][0]['state'] = 'new' }
    variants << published_release.tap { |r| r['assets'][0]['browser_download_url'] = 'https://example.com/not-duckpad.dmg' }
    variants.each do |release|
      run_sync(release) do |status, _, bytes, original|
        refute status.success?
        assert_equal original, bytes
      end
    end
  end
end
