#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'tmpdir'

ROOT = File.expand_path('../..', __dir__)
SCRIPT = File.join(ROOT, '.github/scripts/sync-update-at-metadata.rb')

Dir.mktmpdir('sync-update-at-metadata') do |dir|
  apps = File.join(dir, 'Apps')
  dist = File.join(dir, 'dist')
  Dir.mkdir(apps)
  Dir.mkdir(dist)

  app_dir = File.join(apps, 'WithDate')
  Dir.mkdir(app_dir)
  File.write(File.join(app_dir, 'docker-compose.yml'), <<~YAML)
    x-casaos:
      id: com.example.with-date
      update_at: "2026-09-24"
  YAML

  other_dir = File.join(apps, 'WithoutDate')
  Dir.mkdir(other_dir)
  File.write(File.join(other_dir, 'docker-compose.yml'), <<~YAML)
    x-casaos:
      id: com.example.without-date
  YAML

  catalog = {
    'apps' => [
      { 'id' => 'com.example.with-date', 'title' => 'With date' },
      { 'store_app_id' => 'com.example.with-date' },
      { 'id' => 'com.example.without-date', 'title' => 'Without date' }
    ]
  }
  File.write(File.join(dist, 'store.json'), JSON.generate(catalog))

  abort 'sync script failed' unless system('ruby', SCRIPT, dir, dist)

  apps_output = JSON.parse(File.read(File.join(dist, 'store.json'))).fetch('apps')
  abort 'id metadata was not synchronized' unless apps_output[0]['update_at'] == '2026-09-24'
  abort 'store_app_id metadata was not synchronized' unless apps_output[1]['update_at'] == '2026-09-24'
  abort 'unrelated metadata was modified' if apps_output[2].key?('update_at')
end

puts 'test-sync-update-at-metadata: PASS'
