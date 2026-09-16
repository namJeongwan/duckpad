# Render the same Liquid templates for local review without installing Jekyll.
require 'liquid'
require 'yaml'
require 'json'
require 'fileutils'

ROOT = File.expand_path(__dir__)
PREVIEW_ROOT = File.expand_path('../build/website-preview', ROOT)

def read_yaml(path)
  YAML.safe_load(File.read(path))
end

module PreviewUrls
  def jsonify(value)
    JSON.generate(value)
  end

  def relative_url(path)
    site = @context['site']
    if @context.registers[:standalone]
      site['data']['languages'].each do |language|
        site['data']['pages'].each do |page|
          if path == language['prefix'] + page['route']
            suffix = language['code'] == 'en' ? '' : ".#{language['code']}"
            return "duckpad-site-#{page['key']}#{suffix}.html"
          end
        end
      end
      return path.sub(%r{\A/assets/}, 'duckpad-site-assets/')
    end
    site['baseurl'] + path
  end

  def absolute_url(path)
    site = @context['site']
    site['url'] + site['baseurl'] + path
  end
end

# The preview supports only the include forms used by this site. Production
# builds use Jekyll's own include tag and URL filters, without custom plugins.
class PreviewInclude < Liquid::Tag
  def initialize(name, markup, tokens)
    super
    @source = markup.strip
  end

  def render(context)
    relative = @source == '{{ page.body }}' ? context['page']['body'] : @source
    path = File.expand_path(relative, File.join(ROOT, '_includes'))
    raise 'Include outside site' unless path.start_with?(File.join(ROOT, '_includes') + '/')
    Liquid::Template.parse(File.read(path), error_mode: :strict).render!(context)
  end
end

Liquid::Template.register_filter(PreviewUrls)
Liquid::Template.register_tag('include', PreviewInclude)
site = read_yaml(File.join(ROOT, '_config.yml'))
site['data'] = { 'release' => read_yaml(File.join(ROOT, '_data/release.yml')) }
%w[languages pages].each { |name| site['data'][name] = JSON.parse(File.read(File.join(ROOT, '_data', name + '.json'))) }
site['data']['i18n'] = {}
site['data']['languages'].each do |language|
  site['data']['i18n'][language['code']] = JSON.parse(File.read(File.join(ROOT, '_data/i18n', language['code'] + '.json')))
end
layout = Liquid::Template.parse(File.read(File.join(ROOT, '_layouts/default.html')), error_mode: :strict)
output = File.join(PREVIEW_ROOT, site['baseurl'].sub(%r{\A/}, ''))
FileUtils.mkdir_p(output)
FileUtils.cp(File.join(ROOT, 'googled90414a55ce3575a.html'), output)
FileUtils.cp_r(File.join(ROOT, 'assets'), output)
standalone_assets = File.expand_path('../duckpad-site-assets', ROOT)
FileUtils.mkdir_p(standalone_assets)
FileUtils.cp_r(File.join(ROOT, 'assets', '.'), standalone_assets)
site['data']['languages'].each do |language|
  site['data']['pages'].each do |entry|
    folder = language['code'] == 'en' ? ROOT : File.join(ROOT, language['code'])
    source = File.read(File.join(folder, entry['filename']))
    _, front, = source.split(/^---\s*$\n?/, 3)
    page = YAML.safe_load(front)
    page['url'] = page['permalink']
    context = { 'site' => site, 'page' => page }
    [false, true].each do |standalone|
      html = layout.render!(context, strict_variables: true, strict_filters: true, registers: { standalone: standalone })
      raise 'Unrendered Liquid' if html.match?(/\{[{%]/)
      html = html.lines.map(&:rstrip).join("\n") + "\n"
      if standalone
        suffix = language['code'] == 'en' ? '' : ".#{language['code']}"
        destination = File.join(ROOT, '..', "duckpad-site-#{entry['key']}#{suffix}.html")
      else
        destination = File.join(output, page['url'].sub(%r{\A/}, ''), 'index.html')
      end
      FileUtils.mkdir_p(File.dirname(destination))
      File.write(destination, html)
    end
  end
end
%w[sitemap.xml robots.txt].each do |filename|
  _, _, body = File.read(File.join(ROOT, filename)).split(/^---\s*$\n?/, 3)
  html = Liquid::Template.parse(body, error_mode: :strict).render!({ 'site' => site }, strict_variables: true, strict_filters: true)
  File.write(File.join(output, filename), html)
end
FileUtils.cp(File.join(ROOT, '..', 'duckpad-site-home.html'), File.join(ROOT, '..', 'duckpad-website.html'))
puts "Rendered 32 localized routes and 32 standalone previews."
puts "Serve #{PREVIEW_ROOT}; site path #{site['baseurl']}/"
