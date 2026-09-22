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

categories = read_json(File.join(root, 'category-list.json'))
recommendations = read_json(File.join(root, 'recommend-list.json'))
supported_languages = read_json(File.join(root, 'supported-languages.json'))
store_config = read_json(File.join(root, 'store-config.json'))

unless categories.is_a?(Array) && categories.all? { |category| category.is_a?(Hash) }
  abort 'category-list.json must contain an array of category objects'
end

unless recommendations.is_a?(Array) && recommendations.all? { |app| app.is_a?(Hash) }
  abort 'recommend-list.json must contain an array of recommendation objects'
end

unless supported_languages.is_a?(Array) && supported_languages.all? { |language| language.is_a?(String) && !language.empty? }
  abort 'supported-languages.json must contain an array of non-empty language codes'
end

category_names = categories.map { |category| category['name'].to_s.strip }
errors = []
errors << 'category-list.json contains an empty category name' if category_names.any?(&:empty?)
errors << 'category-list.json contains duplicate category names' if category_names.uniq.length != category_names.length
errors << 'supported-languages.json contains duplicate language codes' if supported_languages.uniq.length != supported_languages.length

REQUIRED_APP_FIELDS = %w[
  id main architectures port_map index scheme title author developer category icon
  description tagline version
].freeze
VALID_ARCHITECTURES = %w[amd64 arm arm64 386 ppc64le riscv64 s390x].freeze

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
  category = metadata['category'].to_s.strip
  REQUIRED_APP_FIELDS.each do |field|
    value = metadata[field]
    errors << "#{path}: missing x-casaos.#{field}" if value.nil? || value == ''
  end
  errors << "#{path}: missing x-casaos.id" if id.empty?
  errors << "#{path}: category #{category.inspect} is not listed in category-list.json" unless category_names.include?(category)
  errors << "#{path}: x-casaos.id must use reverse-domain syntax" unless id.match?(/\A[a-z0-9]+(?:[._-][a-z0-9]+)+\z/)
  errors << "#{path}: x-casaos.scheme must be http or https" unless %w[http https].include?(metadata['scheme'])
  errors << "#{path}: x-casaos.index must start with /" unless metadata['index'].is_a?(String) && metadata['index'].start_with?('/')
  errors << "#{path}: x-casaos.port_map must be a numeric port" unless metadata['port_map'].to_s.match?(/\A[1-9]\d{0,4}\z/)

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

recommended_ids = recommendations.map { |app| app['appid'].to_s.strip }
errors << 'recommend-list.json contains an empty appid' if recommended_ids.any?(&:empty?)
errors << 'recommend-list.json contains duplicate app IDs' if recommended_ids.uniq.length != recommended_ids.length

unknown_recommendations = recommended_ids - app_ids
unless unknown_recommendations.empty?
  errors << "recommend-list.json references unknown app IDs: #{unknown_recommendations.join(', ')}"
end

unless errors.empty?
  warn errors.join("\n")
  exit 1
end

puts "validate-store-catalog: #{apps.length} app(s), #{category_names.length} category(ies), #{recommended_ids.length} recommendation(s) valid"
