#!/usr/bin/env ruby
# frozen_string_literal: true

# The app-store builder does not retain every optional x-casaos key in its
# generated catalog. Preserve update_at explicitly so the published gh-pages
# metadata remains consistent with the source Compose manifests.

require 'date'
require 'json'
require 'yaml'

root = File.expand_path(ARGV.fetch(0, '.'))
dist = File.expand_path(ARGV.fetch(1, 'dist'), root)

def update_dates(root)
  Dir.glob(File.join(root, 'Apps', '*', 'docker-compose.yml')).sort.each_with_object({}) do |path, dates|
    metadata = YAML.load_file(path, aliases: true).fetch('x-casaos', {})
    next unless metadata.key?('update_at')

    id = metadata['id']
    value = metadata['update_at']
    begin
      valid_date = value.is_a?(String) && Date.iso8601(value).iso8601 == value
    rescue Date::Error
      valid_date = false
    end
    unless id.is_a?(String) && valid_date
      abort "#{path}: x-casaos.update_at must be an ISO 8601 date (YYYY-MM-DD)"
    end

    dates[id] = value
  end
end

def sync_dates!(value, dates, matched)
  case value
  when Hash
    app_id = value['id'] || value['store_app_id']
    if dates.key?(app_id)
      value['update_at'] = dates.fetch(app_id)
      matched << app_id
    end
    value.each_value { |child| sync_dates!(child, dates, matched) }
  when Array
    value.each { |child| sync_dates!(child, dates, matched) }
  end
end

dates = update_dates(root)
exit 0 if dates.empty?

matched = []
json_files = Dir.glob(File.join(dist, '**', '*.json')).sort
abort "No generated JSON metadata found in #{dist}" if json_files.empty?

json_files.each do |path|
  data = JSON.parse(File.read(path))
  before = matched.length
  sync_dates!(data, dates, matched)
  next if matched.length == before

  File.write(path, "#{JSON.pretty_generate(data)}\n")
end

missing = dates.keys - matched.uniq
abort "Generated metadata is missing update_at for: #{missing.join(', ')}" unless missing.empty?

puts "sync-update-at-metadata: synchronized #{matched.uniq.length} app(s) across #{json_files.length} JSON file(s)"
