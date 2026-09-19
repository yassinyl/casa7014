#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

ruby <<'RUBY'
require 'yaml'

readme_path = 'README.md'
start_marker = '<!-- apps:start -->'
end_marker = '<!-- apps:end -->'

apps = Dir.glob('Apps/*/docker-compose.yml').filter_map do |compose_path|
  begin
    data = YAML.load_file(compose_path, aliases: true) || {}
    casa = data['x-casaos'] || {}

    next unless casa['id']

    title = casa['title']
    title = title['en_US'] if title.is_a?(Hash)
    title = File.basename(File.dirname(compose_path)) if title.nil? || title.to_s.empty?

    description = casa['description']
    description = description['en_US'] if description.is_a?(Hash)
    description = description.to_s.gsub(/\s+/, ' ').strip

    version = casa['version'].to_s

    icon = casa['icon']
    if icon.nil? || icon.to_s.empty?
      app_dir = File.dirname(compose_path).sub(%r{^Apps/}, '')
      icon = "https://cdn.jsdelivr.net/gh/yassinyl/casa7014@main/Apps/#{app_dir.gsub(' ', '%20')}/icon.png"
    end

    {
      title: title.to_s,
      version: version,
      description: description,
      icon: icon.to_s
    }
  rescue StandardError => e
    warn "Skipping #{compose_path}: #{e.message}"
    nil
  end
end

apps.sort_by! { |app| app[:title].downcase }

rows = apps.map do |app|
  description = app[:description].gsub('|', '\|')

  "| <img src=\"#{app[:icon]}\" width=\"48\" height=\"48\"> | **#{app[:title]}** | `#{app[:version]}` | #{description} |"
end

table = <<~TABLE.chomp
  <!-- apps:start -->

  | Icon | Application | Version | Description |
  |:---:|---|:---:|---|
  #{rows.join("\n")}

  <!-- apps:end -->
TABLE

readme = File.read(readme_path)

abort "Missing #{start_marker}" unless readme.include?(start_marker)
abort "Missing #{end_marker}" unless readme.include?(end_marker)

readme = readme.sub(
  /\[!\[Apps\]\(https:\/\/img\.shields\.io\/badge\/Apps-[^-]+-orange\)\]/,
  "[![Apps](https://img.shields.io/badge/Apps-#{apps.length}-orange)]"
)

readme = readme.sub(
  /#{Regexp.escape(start_marker)}.*?#{Regexp.escape(end_marker)}/m,
  table
)

File.write(readme_path, readme)

puts "Updated README app table: #{apps.length} apps"
RUBY
