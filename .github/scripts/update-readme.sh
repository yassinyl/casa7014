#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

ruby <<'RUBY'
require 'yaml'
require 'uri'

README_PATH = 'README.md'
START_MARKER = '<!-- apps:start -->'
END_MARKER = '<!-- apps:end -->'

def localized(value)
  return value['en_US'] if value.is_a?(Hash)

  value
end

def markdown_escape(value)
  value.to_s
       .gsub(/\s+/, ' ')
       .strip
       .gsub('|', '\|')
end

def fallback_icon(compose_path)
  app_dir = File.dirname(compose_path).sub(%r{\AApps/}, '')

  encoded_path = app_dir.split('/').map do |part|
    URI::DEFAULT_PARSER.escape(part)
  end.join('/')

  "https://cdn.jsdelivr.net/gh/yassinyl/casa7014@refs/heads/main/Apps/#{encoded_path}/icon.png"
end

apps = Dir.glob('Apps/*/docker-compose.yml').filter_map do |compose_path|
  begin
    data = YAML.load_file(compose_path, aliases: true) || {}
    casa = data['x-casaos'] || {}

    next unless casa['id']

    title = localized(casa['title'])
    title = File.basename(File.dirname(compose_path)) if title.nil? || title.to_s.strip.empty?

    description = localized(casa['description'])
    version = casa['version']

    icon = casa['icon']
    icon = fallback_icon(compose_path) if icon.nil? || icon.to_s.strip.empty?

    {
      title: markdown_escape(title),
      version: markdown_escape(version),
      description: markdown_escape(description),
      icon: icon.to_s.strip
    }
  rescue StandardError => e
    warn "Skipping #{compose_path}: #{e.message}"
    nil
  end
end

apps.sort_by! { |app| app[:title].downcase }

rows = apps.map do |app|
  "| <img src=\"#{app[:icon]}\" width=\"48\" height=\"48\"> | **#{app[:title]}** | `#{app[:version]}` | #{app[:description]} |"
end

table = [
  START_MARKER,
  '',
  '| Icon | Application | Version | Description |',
  '|:---:|---|:---:|---|',
  rows.join("\n"),
  '',
  END_MARKER
].join("\n")

readme = File.read(README_PATH)

abort "Missing #{START_MARKER}" unless readme.include?(START_MARKER)
abort "Missing #{END_MARKER}" unless readme.include?(END_MARKER)

unless readme.index(START_MARKER) < readme.index(END_MARKER)
  abort 'README app markers are in the wrong order.'
end

# Update the application count in the existing Shields.io badge.
readme.sub!(
  /Apps-\d+-orange/,
  "Apps-#{apps.length}-orange"
)

# Replace only the generated application table.
readme.sub!(
  /#{Regexp.escape(START_MARKER)}.*?#{Regexp.escape(END_MARKER)}/m,
  table
)

File.write(README_PATH, readme)

puts "Updated README app table: #{apps.length} apps"
RUBY
