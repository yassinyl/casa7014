#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'yaml'

root = ARGV.fetch(0, File.expand_path('../..', __dir__))

def read_json(path)
  JSON.parse(File.read(path))
rescue JSON::ParserError => e
  abort "#{path}: invalid JSON: #{e.message}"
end

supported_languages = read_json(File.join(root, 'supported-languages.json'))
store_config = read_json(File.join(root, 'store-config.json'))

unless supported_languages.is_a?(Array) && supported_languages.all? { |language| language.is_a?(String) && !language.empty? }
  abort 'supported-languages.json must contain an array of non-empty language codes'
end

errors = []
errors << 'supported-languages.json contains duplicate language codes' if supported_languages.uniq.length != supported_languages.length

REQUIRED_APP_FIELDS = %w[
  id main architectures port_map index scheme title author developer category icon
  description tagline version
].freeze
VALID_ARCHITECTURES = %w[amd64 arm arm64 386 ppc64le riscv64 s390x].freeze
UNPUBLISHED_APP_FIELDS = %w[update_at updated_at].freeze

def published_ports(service)
  Array(service['ports']).filter_map do |port|
    case port
    when Hash
      port['published'].to_s
    when String
      port.split(':').last.split('/').first
    end
  end
end

def valid_http_url?(value)
  value.is_a?(String) && value.match?(%r{\Ahttps?://[^\s]+\z})
end

# The V2 store generator omits versions that are not semantic versions. Validate
# them here so an otherwise valid compose file cannot publish incomplete metadata.
def semantic_version?(value)
  value.is_a?(String) && value.match?(
    /\A(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\z/
  )
end

%w[name description].each do |field|
  localized = store_config[field]
  unless localized.is_a?(Hash)
    errors << "store-config.json: #{field} must be a localized object"
    next
  end

  missing = supported_languages.reject { |language| localized[language].is_a?(String) && !localized[language].strip.empty? }
  errors << "store-config.json: #{field} is missing translations for #{missing.join(', ')}" unless missing.empty?
end

apps = Dir.glob(File.join(root, 'Apps', '*', 'docker-compose.yml')).sort.filter_map do |path|
  begin
    compose = YAML.load_file(path, aliases: true) || {}
    metadata = compose.fetch('x-casaos', {})
  rescue Psych::Exception => e
    errors << "#{path}: invalid YAML: #{e.message}"
    next
  end

  id = metadata['id'].to_s.strip
  REQUIRED_APP_FIELDS.each do |field|
    value = metadata[field]
    errors << "#{path}: missing x-casaos.#{field}" if value.nil? || value == ''
  end
  errors << "#{path}: missing x-casaos.id" if id.empty?
  errors << "#{path}: x-casaos.id must use reverse-domain syntax" unless id.match?(/\A[a-z0-9]+(?:[._-][a-z0-9]+)+\z/)
  errors << "#{path}: x-casaos.scheme must be http or https" unless %w[http https].include?(metadata['scheme'])
  errors << "#{path}: x-casaos.index must start with /" unless metadata['index'].is_a?(String) && metadata['index'].start_with?('/')
  errors << "#{path}: x-casaos.port_map must be a numeric port" unless metadata['port_map'].to_s.match?(/\A[1-9]\d{0,4}\z/)
  errors << "#{path}: x-casaos.version must be a semantic version" unless semantic_version?(metadata['version'])
  UNPUBLISHED_APP_FIELDS.each do |field|
    errors << "#{path}: x-casaos.#{field} is not published per app; the V2 catalog only has a store-level updated_at" if metadata.key?(field)
  end

  architectures = metadata['architectures']
  unless architectures.is_a?(Array) && !architectures.empty? && architectures.all? { |architecture| VALID_ARCHITECTURES.include?(architecture.to_s) }
    errors << "#{path}: x-casaos.architectures contains an unsupported value"
  end

  services = compose['services']
  main_service = services.is_a?(Hash) ? services[metadata['main']] : nil
  unless main_service.is_a?(Hash) && main_service['image'].is_a?(String) && !main_service['image'].empty?
    errors << "#{path}: x-casaos.main must reference a service with an image"
  end

  if main_service.is_a?(Hash) && main_service['network_mode'] != 'host' && !published_ports(main_service).include?(metadata['port_map'].to_s)
    errors << "#{path}: x-casaos.port_map must be published by the main service"
  end

  %w[icon thumbnail website repo docs support].each do |field|
    next if metadata[field].nil?

    errors << "#{path}: x-casaos.#{field} must be an HTTP(S) URL" unless valid_http_url?(metadata[field])
  end

  if metadata.key?('screenshot_link') && (!metadata['screenshot_link'].is_a?(Array) || metadata['screenshot_link'].empty? || !metadata['screenshot_link'].all? { |url| valid_http_url?(url) })
    errors << "#{path}: x-casaos.screenshot_link must contain HTTP(S) URLs"
  end
  %w[title description tagline].each do |field|
    localized = metadata[field]
    unless localized.is_a?(Hash)
      errors << "#{path}: x-casaos.#{field} must be a localized object"
      next
    end

    missing = supported_languages.reject { |language| localized[language].is_a?(String) && !localized[language].strip.empty? }
    errors << "#{path}: x-casaos.#{field} is missing translations for #{missing.join(', ')}" unless missing.empty?
  end
  { path: path, id: id }
end

app_ids = apps.map { |app| app[:id] }
errors << 'App IDs must be unique' if app_ids.uniq.length != app_ids.length

unless errors.empty?
  warn errors.join("\n")
  exit 1
end

puts "validate-store-catalog: #{apps.length} app(s) valid"
