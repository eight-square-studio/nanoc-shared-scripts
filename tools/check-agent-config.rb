#!/usr/bin/env ruby
# frozen_string_literal: true

# Stdlib-only. Called by lib/claude_templates.sh (validate.sh). Prints one line per problem found
# in the `agents:` block of <project>/nanoc.yaml — missing paths in dated_pages / copy_review.sources
# and malformed dated_pages entries. Prints nothing when all is well. Never raises on bad config.

require 'yaml'

dir  = ARGV[0] || Dir.pwd
file = File.join(dir, 'nanoc.yaml')
exit 0 unless File.exist?(file)

cfg = begin
  YAML.safe_load(File.read(file), permitted_classes: [Symbol], aliases: true)
rescue Psych::Exception
  nil
end
exit 0 unless cfg.is_a?(Hash) && cfg['agents'].is_a?(Hash)
agents = cfg['agents']

def exists?(dir, path)
  path = path.to_s
  if path.match?(/[*?\[{]/)
    !Dir.glob(File.join(dir, path)).empty?
  else
    File.exist?(File.join(dir, path))
  end
end

def list(value) = value.is_a?(Array) ? value : []

problems = []

copy = agents['copy_review']
if copy.is_a?(Hash)
  sources = list(copy['sources'])
  sources.each do |s|
    problems << "agents.copy_review.sources: #{s} matches nothing" unless exists?(dir, s)
  end
end

pages = agents['dated_pages']
unless pages.nil?
  if pages.is_a?(Array)
    pages.each_with_index do |entry, i|
      unless entry.is_a?(Hash)
        problems << "agents.dated_pages[#{i}]: must be a mapping (page, date_in or date_line, content)"
        next
      end
      name = entry['page'] || "##{i}"
      problems << "agents.dated_pages (#{name}): missing `page`" unless entry['page']
      if entry['date_in'].nil? == entry['date_line'].nil?
        problems << "agents.dated_pages (#{name}): needs exactly one of `date_in` or `date_line`"
      end
      problems << "agents.dated_pages (#{name}): `content` must be a non-empty list" if list(entry['content']).empty?
      %w[date_in date_line].each do |k|
        problems << "agents.dated_pages (#{name}): #{k} #{entry[k]} does not exist" if entry[k] && !exists?(dir, entry[k])
      end
      list(entry['content']).each do |c|
        problems << "agents.dated_pages (#{name}): content #{c} does not exist" unless exists?(dir, c)
      end
    end
  else
    problems << 'agents.dated_pages must be a list'
  end
end

list(agents['never_touch_dates']).each do |f|
  problems << "agents.never_touch_dates: #{f} does not exist" unless exists?(dir, f)
end

puts problems
