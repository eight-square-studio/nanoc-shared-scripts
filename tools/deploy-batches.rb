#!/usr/bin/env ruby
# frozen_string_literal: true

# Batch helpers for deploy.sh. Pure stdlib — no bundler needed.
#
#   manifest        --dir DIR                 print "sha256  relpath" for every file, bytewise sorted
#   stage           --src DIR --dest DIR      (keys on stdin) hard-link/copy those files into DEST
#   invalidate      --group-threshold N --all-threshold N --ref REF [--list]
#                                             (keys on stdin) print CloudFront invalidation batches
#                                             as JSON lines, or with --list the planned paths
#   delete          (keys on stdin)           print S3 delete-objects payloads as JSON lines
#   delete-result   (delete-objects JSON on stdin)  print deleted keys; errors go to stderr

require 'digest'
require 'find'
require 'fileutils'
require 'json'
require 'optparse'

MAX_INVALIDATION_PATHS = 3000 # CloudFront hard limit per create-invalidation request
MAX_DELETE_KEYS = 1000        # S3 delete-objects hard limit per request

def read_keys
  $stdin.binmode
  $stdin.each_line.map { |l| l.chomp.force_encoding('UTF-8') }.reject(&:empty?).uniq
end

# Same file set as `find DIR -type f ! -name '.*'`: regular files (not symlinks)
# whose own name doesn't start with a dot.
def manifest(dir)
  root = File.expand_path(dir)
  prefix = "#{root}/"
  lines = []
  Find.find(root) do |path|
    st = File.lstat(path)
    next unless st.file?
    next if File.basename(path).start_with?('.')

    lines << [path.delete_prefix(prefix), Digest::SHA256.file(path).hexdigest]
  end
  lines.sort_by { |rel, hash| "#{hash}  #{rel}".b }.each { |rel, hash| puts "#{hash}  #{rel}" }
end

def stage(src, dest, keys)
  keys.each do |key|
    from = File.join(src, key)
    to = File.join(dest, key)
    FileUtils.mkdir_p(File.dirname(to))
    begin
      File.link(from, to)
    rescue SystemCallError
      FileUtils.cp(from, to)
    end
  end
end

def encode_path(path)
  path.b.gsub(%r{[^A-Za-z0-9\-._~/*]}n) { |c| format('%%%02X', c.ord) }.force_encoding('UTF-8')
end

# Turn changed/deleted S3 keys into the smallest sensible set of CloudFront paths:
#   foo/index.html        -> /foo and /foo/*   (the page, its URL forms and everything below)
#   index.html            -> / and /index.html
#   >= group_threshold files in one directory -> /dir/*
#   anything already covered by a wildcard is dropped
#   still more than all_threshold paths -> /*
def plan_invalidation(keys, group_threshold:, all_threshold:)
  wildcards = [] # directories ("" = root) invalidated with /dir/*
  exact = []     # url paths
  by_dir = Hash.new { |h, k| h[k] = [] }

  keys.each do |key|
    dir, base = File.split(key)
    dir = '' if dir == '.'
    if base == 'index.html' && !dir.empty?
      wildcards << dir
      exact << "/#{dir}"
    elsif base == 'index.html'
      exact << '/' << '/index.html'
    else
      by_dir[dir] << key
    end
  end

  covered = ->(dir_list, key) { dir_list.any? { |w| w.empty? || key.start_with?("#{w}/") } }

  by_dir.each do |dir, dir_keys|
    remaining = dir_keys.reject { |k| covered.call(wildcards, k) }
    if remaining.size >= group_threshold
      wildcards << dir
    else
      exact.concat(remaining.map { |k| "/#{k}" })
    end
  end

  wildcards = wildcards.uniq.reject { |w| wildcards.any? { |o| o != w && (o.empty? || w.start_with?("#{o}/")) } }
  exact = exact.uniq.reject { |p| covered.call(wildcards, p.delete_prefix('/')) }

  paths = wildcards.map { |w| w.empty? ? '/*' : "/#{w}/*" } + exact
  return ['/*'] if paths.size > all_threshold

  paths.map { |p| encode_path(p) }
end

def invalidation_batches(paths, ref)
  paths.each_slice(MAX_INVALIDATION_PATHS).with_index(1).map do |slice, i|
    { 'Paths' => { 'Quantity' => slice.size, 'Items' => slice }, 'CallerReference' => "#{ref}-#{i}" }
  end
end

def delete_batches(keys)
  keys.each_slice(MAX_DELETE_KEYS).map do |slice|
    { 'Objects' => slice.map { |k| { 'Key' => k } }, 'Quiet' => false }
  end
end

def delete_result(json)
  return if json.strip.empty?

  data = JSON.parse(json)
  (data['Deleted'] || []).each { |d| puts d['Key'] }
  (data['Errors'] || []).each { |e| warn "#{e['Key']}: #{e['Code']} #{e['Message']}" }
end

cmd = ARGV.shift
opts = { group_threshold: 10, all_threshold: 1000, ref: Time.now.to_i.to_s, list: false }
OptionParser.new do |o|
  o.on('--dir DIR') { |v| opts[:dir] = v }
  o.on('--src DIR') { |v| opts[:src] = v }
  o.on('--dest DIR') { |v| opts[:dest] = v }
  o.on('--group-threshold N', Integer) { |v| opts[:group_threshold] = v }
  o.on('--all-threshold N', Integer) { |v| opts[:all_threshold] = v }
  o.on('--ref REF') { |v| opts[:ref] = v }
  o.on('--list') { opts[:list] = true }
end.parse!

case cmd
when 'manifest'
  manifest(opts.fetch(:dir))
when 'stage'
  stage(opts.fetch(:src), opts.fetch(:dest), read_keys)
when 'invalidate'
  paths = plan_invalidation(read_keys, group_threshold: opts[:group_threshold], all_threshold: opts[:all_threshold])
  if opts[:list]
    puts paths
  else
    invalidation_batches(paths, opts[:ref]).each { |b| puts JSON.generate(b) }
  end
when 'delete'
  delete_batches(read_keys).each { |b| puts JSON.generate(b) }
when 'delete-result'
  delete_result($stdin.read)
else
  warn "usage: #{File.basename($PROGRAM_NAME)} manifest|stage|invalidate|delete|delete-result"
  exit 2
end
