#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'time'
require 'yaml'

root = File.expand_path(ARGV.fetch(0, '.'))
output = File.expand_path(ARGV.fetch(1, 'dist'), root)
index_path = File.join(output, 'index.json')

abort "#{index_path}: missing V2 build index" unless File.file?(index_path)

def read_json(path)
  JSON.parse(File.read(path))
rescue JSON::ParserError => e
  abort "#{path}: invalid JSON: #{e.message}"
end

def parse_timestamp(value)
  return false unless value.is_a?(String)

  Time.iso8601(value)
  true
rescue ArgumentError
  false
end

expected_versions = Dir.glob(File.join(root, 'Apps', '*', 'docker-compose.yml')).to_h do |path|
  compose = YAML.load_file(path, aliases: true) || {}
  metadata = compose.fetch('x-casaos')
  [metadata.fetch('id'), metadata.fetch('version')]
end

index = read_json(index_path)
abort "#{index_path}: apps must be an array" unless index['apps'].is_a?(Array)
abort "#{index_path}: updated_at must be an ISO 8601 timestamp" unless parse_timestamp(index['updated_at'])

published_apps = {}
index['apps'].each do |app|
  abort "#{index_path}: app entry must be an object" unless app.is_a?(Hash)

  id = app['id']
  abort "#{index_path}: app entry is missing id" unless id.is_a?(String) && !id.empty?
  abort "#{index_path}: duplicate app id #{id}" if published_apps.key?(id)

  published_apps[id] = app
end

missing_apps = expected_versions.keys - published_apps.keys
unexpected_apps = published_apps.keys - expected_versions.keys
abort "#{index_path}: missing apps: #{missing_apps.join(', ')}" unless missing_apps.empty?
abort "#{index_path}: unexpected apps: #{unexpected_apps.join(', ')}" unless unexpected_apps.empty?

expected_versions.each do |id, version|
  published_version = published_apps.fetch(id)['version']
  next if published_version == version

  abort "#{index_path}: #{id} version mismatch (expected #{version.inspect}, got #{published_version.inspect})"
end

puts "verify-v2-build: #{published_apps.length} app(s) with published versions and store updated_at"
