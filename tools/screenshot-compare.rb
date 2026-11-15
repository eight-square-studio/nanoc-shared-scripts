#!/usr/bin/env ruby
# frozen_string_literal: true

require 'ferrum'
require 'fileutils'
require 'open3'
require 'socket'
require 'base64'
require 'yaml'

PROJECT_DIR     = ENV.fetch('PROJECT_DIR') { abort 'PROJECT_DIR env var not set — run via check-layouts.sh' }
TMP_BASE        = File.join(PROJECT_DIR, 'tmp', 'screenshots')
WORKTREE        = File.join(PROJECT_DIR, 'tmp', 'worktree-release')
SCREENSHOT_ONLY = ENV['SCREENSHOT_ONLY'] == '1'
CHROME_PATH     = ENV['CHROME_PATH']

# Chrome cannot paint a viewport taller than 16384px (GPU texture limit): resizing
# past it makes Page.captureScreenshot hang until the CDP timeout. Taller pages are
# captured at this height instead — the same cap applies to release and current, so
# the images stay comparable (only the top MAX_HEIGHT px of a very tall page is diffed).
MAX_HEIGHT      = Integer(ENV.fetch('SCREENSHOT_MAX_HEIGHT', 16_000))
# Per-command CDP timeout in seconds (Ferrum's own default is 5s).
TIMEOUT         = Integer(ENV.fetch('SCREENSHOT_TIMEOUT', 30))

# ── Helpers ───────────────────────────────────────────────────────────────────

def log(msg) = puts("▶ #{msg}")

def new_browser
  opts = { headless: true, window_size: [1440, 900], timeout: TIMEOUT }
  opts[:browser_path] = CHROME_PATH if CHROME_PATH && !CHROME_PATH.empty?
  # Chrome refuses to launch its sandbox as root (common in CI/containers).
  # Containers also typically cap /dev/shm at 64MB, which crashes Chrome's
  # renderer before it can print its websocket URL — disable shared-memory
  # usage too. Both only apply when running as root.
  if Process.uid.zero?
    opts[:browser_options] = { 'no-sandbox' => nil, 'disable-dev-shm-usage' => nil }
  end
  Ferrum::Browser.new(**opts)
end

def open_report(path)
  opener = if RUBY_PLATFORM =~ /darwin/
             'open'
           elsif system('command -v xdg-open > /dev/null 2>&1')
             'xdg-open'
           end
  if opener
    system("#{opener} \"#{path}\"")
  else
    log "Open the report manually: #{path}"
  end
end

def wait_for_port(port, timeout: 30)
  deadline = Time.now + timeout
  loop do
    TCPSocket.new('127.0.0.1', port).close
    return true
  rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH
    raise "Port #{port} not ready after #{timeout}s" if Time.now > deadline
    sleep 0.5
  end
end

def run!(cmd, dir: PROJECT_DIR)
  log "$ #{cmd}"
  system(cmd, chdir: dir) || raise("Command failed: #{cmd}")
end

def start_server(port, dir:)
  log "Starting nanoc view on :#{port}"
  pid = Process.spawn(
    "bundle exec nanoc view --port #{port}",
    chdir: dir, out: '/dev/null', err: '/dev/null'
  )
  wait_for_port(port)
  pid
end

def kill_server(pid)
  Process.kill('TERM', pid)
  Process.wait(pid)
rescue Errno::ESRCH, Errno::ECHILD
  # already gone
end

# ── Page discovery ────────────────────────────────────────────────────────────

def discover_pages(project_dir)
  output_prefix = File.join(project_dir, 'output') + '/'
  stdout, = Open3.capture2('bundle exec nanoc show-data', chdir: project_dir)
  stdout.lines.filter_map do |line|
    next unless line.include?('.html')
    path = line[%r{(#{Regexp.escape(output_prefix)}\S*\.html)}, 1]
    next unless path
    relative = path.sub(output_prefix, '')
    url = output_path_to_url(relative)
    { url: url, filename: url_to_filename(url) }
  end.uniq { |p| p[:url] }.sort_by { |p| p[:url] }
end

def output_path_to_url(relative)
  case relative
  when 'index.html'            then '/'
  when %r{\A(.+)/index\.html\z} then "/#{$1}/"
  else                              "/#{relative}"
  end
end

def url_to_filename(url)
  return 'index.png' if url == '/'
  url.gsub('/', '_').sub(/^_/, '').sub(/_$/, '') + '.png'
end

# ── Sampled generated pages ───────────────────────────────────────────────────
# Pages written into output/ after compile (not nanoc items) are invisible to
# `nanoc show-data`. Opt in via nanoc.yaml:
#   screenshot_samples:
#     - path: some-dir     # directory under output/ containing <slug>/index.html
#       count: 10

def sample_config(project_dir)
  file = File.join(project_dir, 'nanoc.yaml')
  return [] unless File.exist?(file)
  entries = YAML.safe_load(File.read(file), permitted_classes: [Symbol], aliases: true)&.dig('screenshot_samples')
  return [] if entries.nil?
  unless entries.is_a?(Array)
    log '⚠ screenshot_samples must be a list — ignoring'
    return []
  end
  entries.filter_map do |e|
    path  = e.is_a?(Hash) ? e['path'].to_s.gsub(%r{\A/+|/+\z}, '') : ''
    count = e.is_a?(Hash) ? e['count'].to_i : 0
    if path.empty? || count < 1
      log "⚠ screenshot_samples: skipping invalid entry #{e.inspect} (needs path and count >= 1)"
      next
    end
    { path: path, count: count }
  end
end

def list_slugs(build_dir, path)
  Dir.glob(File.join(build_dir, 'output', path, '*', 'index.html'))
     .map { |f| File.basename(File.dirname(f)) }.sort
end

# Deterministic: `count` evenly spaced items from a sorted list (first and last included).
def evenly_spaced(list, count)
  return list if count >= list.size
  return [list.first] if count == 1
  idx = (0...count).map { |i| (i * (list.size - 1).to_f / (count - 1)).round }.uniq
  list.values_at(*idx)
end

# build_dirs: every build that will be screenshotted. Only slugs present in all of
# them are eligible, so each build screenshots identical pages.
def sample_pages(config, build_dirs)
  config.flat_map do |entry|
    per_build = build_dirs.map { |d| list_slugs(d, entry[:path]) }
    common    = per_build.reduce(:&)
    skipped   = per_build.flatten.uniq.size - common.size
    picked    = evenly_spaced(common, entry[:count])
    log "Sampling /#{entry[:path]}/: #{picked.size} of #{common.size} common pages" \
        "#{skipped > 0 ? " (#{skipped} skipped — only in one build)" : ''}: #{picked.join(', ')}"
    picked.map do |slug|
      url = "/#{entry[:path]}/#{slug}/"
      { url: url, filename: url_to_filename(url) }
    end
  end
end

def with_samples(pages, samples) = (pages + samples).uniq { |p| p[:url] }.sort_by { |p| p[:url] }

# ── Screenshot ────────────────────────────────────────────────────────────────

OVERRIDES_PATH = File.join(PROJECT_DIR, 'screenshot-overrides.js')
FREEZE_SCRIPT  = File.exist?(OVERRIDES_PATH) ? File.read(OVERRIDES_PATH) : nil

# Returns { url => { status: :ok | :capped | :failed, doc_h:, error: } }.
# A page that times out is logged and recorded as :failed instead of aborting the run.
def screenshot_pages(pages, base_url, out_dir, browser)
  FileUtils.mkdir_p(out_dir)
  pages.to_h do |page|
    url = "#{base_url}#{page[:url]}"
    out = File.join(out_dir, page[:filename])
    log "  #{url} → #{page[:filename]}"
    outcome = begin
      capture_page(url, out, browser)
    rescue Ferrum::Error => e
      FileUtils.rm_f(out)
      browser.restart if e.is_a?(Ferrum::DeadBrowserError)
      log "  ⚠ could not capture #{page[:url]}: #{e.class}: #{e.message.lines.first&.strip}"
      { status: :failed, error: e.class.name }
    end
    [page[:url], outcome]
  end
end

def capture_page(url, out, browser)
  browser.resize(width: 1440, height: 900)
  browser.goto(url)
  browser.network.wait_for_idle(duration: 0.3, timeout: 30)
  browser.execute(FREEZE_SCRIPT) if FREEZE_SCRIPT
  browser.network.wait_for_idle(duration: 0.3, timeout: 10)
  50.times { break if browser.evaluate("window.__renderReady === true"); sleep 0.1 }
  doc_h = browser.evaluate('document.documentElement.scrollHeight')
  capped = doc_h > MAX_HEIGHT
  log "    doc_h=#{doc_h}px"
  log "    ⚠ capped at #{MAX_HEIGHT}px (page is #{doc_h}px tall)" if capped
  browser.resize(width: 1440, height: [doc_h, MAX_HEIGHT].min)
  sleep 0.5
  browser.screenshot(path: out, full: false)
  { status: capped ? :capped : :ok, doc_h: doc_h }
end

# ── ImageMagick compare ───────────────────────────────────────────────────────

def compare_images(current, release_img, diff)
  w, h = `identify -format "%w %h" "#{current}"`.strip.split.map(&:to_i)
  total = w * h

  # compare exits 1 when images differ — capture output, ignore exit code
  output, = Open3.capture2e("compare -metric AE -fuzz 3% \"#{current}\" \"#{release_img}\" \"#{diff}\"")
  ae = output.strip.to_f

  pct = total > 0 ? (ae / total * 100).round(2) : 0.0
  { ae: ae.to_i, total: total, pct: pct, flagged: pct > 1.0 }
end

# Human-readable notes for a screenshot outcome (capped / failed).
def capture_notes(outcome)
  return [] unless outcome
  case outcome[:status]
  when :capped then ["capped at #{MAX_HEIGHT}px (full page #{outcome[:doc_h]}px)"]
  when :failed then ["could not capture (#{outcome[:error]})"]
  else []
  end
end

# ── HTML report ───────────────────────────────────────────────────────────────

def embed_image(path)
  return '' unless File.exist?(path)
  "data:image/png;base64,#{Base64.strict_encode64(File.binread(path))}"
end

def generate_report(results, out_path)
  rows = results.sort_by { |r| [r[:failed] ? 0 : 1, -r[:pct]] }

  summary_rows = rows.map do |r|
    status = if r[:failed]
               '<span class="fail">COULD NOT CAPTURE</span>'
             elsif r[:flagged]
               '<span class="fail">FAIL</span>'
             else
               '<span class="pass">PASS</span>'
             end
    change = r[:failed] ? '—' : "#{r[:pct]}%"
    note = r[:notes].to_a.empty? ? '' : "<br><small>#{r[:notes].join('<br>')}</small>"
    "<tr><td>#{r[:url]}#{note}</td><td>#{change}</td><td>#{status}</td></tr>"
  end.join("\n")

  detail_sections = rows.select { |r| r[:flagged] && !r[:failed] }.map do |r|
    <<~HTML
      <section class="diff-section">
        <h2>#{r[:url]} — #{r[:pct]}% changed</h2>
        <div class="images">
          <figure><figcaption>Release (baseline)</figcaption><img src="#{embed_image(r[:release_path])}"></figure>
          <figure><figcaption>Current</figcaption><img src="#{embed_image(r[:current_path])}"></figure>
          <figure><figcaption>Diff</figcaption><img src="#{embed_image(r[:diff_path])}"></figure>
        </div>
      </section>
    HTML
  end.join("\n")

  html = <<~HTML
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <title>Layout Comparison Report</title>
      <style>
        body { font-family: system-ui, sans-serif; margin: 2rem; background: #111; color: #eee; }
        h1 { margin-bottom: 1rem; }
        table { border-collapse: collapse; width: 100%; margin-bottom: 3rem; }
        th, td { padding: 0.5rem 1rem; border: 1px solid #333; text-align: left; }
        th { background: #222; }
        .pass { color: #4caf50; font-weight: bold; }
        .fail { color: #f44336; font-weight: bold; }
        small { color: #aaa; }
        .diff-section { margin-bottom: 4rem; }
        .images { display: grid; grid-template-columns: repeat(3, 1fr); gap: 1rem; }
        .images img { width: 100%; border: 1px solid #333; }
        figcaption { font-size: 0.8rem; color: #aaa; margin-bottom: 0.25rem; }
      </style>
    </head>
    <body>
      <h1>Layout Comparison — #{Time.now.strftime('%Y-%m-%d %H:%M')}</h1>
      <table>
        <thead><tr><th>Page</th><th>Change</th><th>Status</th></tr></thead>
        <tbody>
          #{summary_rows}
        </tbody>
      </table>
      #{detail_sections.empty? && results.none? { |r| r[:failed] } ? '<p style="color:#4caf50">No regressions detected.</p>' : detail_sections}
    </body>
    </html>
  HTML

  File.write(out_path, html)
  log "Report written: #{out_path}"
end

# ── Screenshot-only report ────────────────────────────────────────────────────

def generate_screenshot_report(pages, screenshots_dir, out_path, outcomes = {})
  rows = pages.map do |page|
    path = File.join(screenshots_dir, page[:filename])
    src  = embed_image(path)
    note = capture_notes(outcomes[page[:url]]).join(' · ')
    body = outcomes.dig(page[:url], :status) == :failed ? '<p style="color:#f44336">Could not capture</p>' : %(<img src="#{src}">)
    <<~HTML
      <section class="page-section">
        <h2>#{page[:url]}#{note.empty? ? '' : " — #{note}"}</h2>
        #{body}
      </section>
    HTML
  end.join("\n")

  html = <<~HTML
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <title>Screenshots — #{Time.now.strftime('%Y-%m-%d %H:%M')}</title>
      <style>
        body { font-family: system-ui, sans-serif; margin: 2rem; background: #111; color: #eee; }
        h1 { margin-bottom: 2rem; }
        .page-section { margin-bottom: 4rem; }
        .page-section h2 { margin-bottom: 0.5rem; font-size: 1rem; color: #aaa; }
        .page-section img { width: 100%; border: 1px solid #333; }
      </style>
    </head>
    <body>
      <h1>Screenshots — #{Time.now.strftime('%Y-%m-%d %H:%M')}</h1>
      #{rows}
    </body>
    </html>
  HTML

  File.write(out_path, html)
  log "Report written: #{out_path}"
end

# ── Main ──────────────────────────────────────────────────────────────────────

FileUtils.rm_rf(TMP_BASE)

if SCREENSHOT_ONLY
  FileUtils.mkdir_p("#{TMP_BASE}/current")

  log 'Screenshot-only mode — skipping release comparison'
  log 'Compiling current branch'
  run! 'bundle exec nanoc compile'

  current_pages = discover_pages(PROJECT_DIR)
  log "Found #{current_pages.size} pages"
  current_pages = with_samples(current_pages, sample_pages(sample_config(PROJECT_DIR), [PROJECT_DIR]))

  current_pid = start_server(3000, dir: PROJECT_DIR)
  browser = new_browser
  begin
    outcomes = screenshot_pages(current_pages, 'http://localhost:3000', "#{TMP_BASE}/current", browser)
  ensure
    browser.quit
    kill_server(current_pid)
  end

  report_path = "#{TMP_BASE}/report.html"
  generate_screenshot_report(current_pages, "#{TMP_BASE}/current", report_path, outcomes)
  open_report(report_path)
  failed = outcomes.count { |_, o| o[:status] == :failed }
  log "Done — #{current_pages.size - failed}/#{current_pages.size} pages screenshotted"
  exit(failed > 0 ? 1 : 0)
end

FileUtils.mkdir_p(["#{TMP_BASE}/release", "#{TMP_BASE}/current", "#{TMP_BASE}/diffs"])

# -- Release worktree
log 'Setting up release worktree'
system("git worktree remove #{WORKTREE} --force 2>/dev/null")
run! "git worktree add #{WORKTREE} release"
run! 'git submodule update --init --recursive', dir: WORKTREE
ruby_version = File.read(File.join(WORKTREE, '.ruby-version')).strip
run! "rbenv local #{ruby_version}", dir: WORKTREE
run! 'bundle install', dir: WORKTREE
run! 'bundle exec nanoc compile', dir: WORKTREE

# Compile current too before screenshotting, so sampled detail pages can be
# chosen from the slugs present in both builds.
log 'Compiling current branch'
run! 'bundle exec nanoc compile'

release_pages = discover_pages(WORKTREE)
log "Found #{release_pages.size} pages in release"
current_pages = discover_pages(PROJECT_DIR)
log "Found #{current_pages.size} pages in current"

samples       = sample_pages(sample_config(PROJECT_DIR), [WORKTREE, PROJECT_DIR])
release_pages = with_samples(release_pages, samples)
current_pages = with_samples(current_pages, samples)

release_pid = start_server(3001, dir: WORKTREE)
browser = new_browser
begin
  release_outcomes = screenshot_pages(release_pages, 'http://localhost:3001', "#{TMP_BASE}/release", browser)
ensure
  browser.quit
  kill_server(release_pid)
  system("git worktree remove #{WORKTREE} --force 2>/dev/null")
end

# -- Current branch
current_pid = start_server(3000, dir: PROJECT_DIR)
browser = new_browser
begin
  current_outcomes = screenshot_pages(current_pages, 'http://localhost:3000', "#{TMP_BASE}/current", browser)
ensure
  browser.quit
  kill_server(current_pid)
end

# -- Compare
log 'Comparing screenshots'
all_filenames = (release_pages + current_pages).map { |p| p[:filename] }.uniq.sort

results = all_filenames.map do |filename|
  current_path = "#{TMP_BASE}/current/#{filename}"
  release_path = "#{TMP_BASE}/release/#{filename}"
  diff_path    = "#{TMP_BASE}/diffs/#{filename}"

  url = current_pages.find { |p| p[:filename] == filename }&.dig(:url) ||
        release_pages.find { |p| p[:filename] == filename }&.dig(:url) ||
        filename

  outcomes = { release: release_outcomes[url], current: current_outcomes[url] }
  notes = outcomes.flat_map { |side, o| capture_notes(o).map { |n| "#{side}: #{n}" } }
  paths = { current_path: current_path, release_path: release_path, diff_path: diff_path }

  if outcomes.values.any? { |o| o&.dig(:status) == :failed }
    next { url: url, filename: filename, pct: 0.0, flagged: true, failed: true,
           ae: 0, total: 0, notes: notes, **paths }
  end

  unless File.exist?(current_path) && File.exist?(release_path)
    next { url: url, filename: filename, pct: 100.0, flagged: true,
           ae: 0, total: 0, current_path: current_path,
           release_path: release_path, diff_path: diff_path }
  end

  compare_images(current_path, release_path, diff_path)
    .merge(url: url, filename: filename, notes: notes, **paths)
end

report_path = "#{TMP_BASE}/report.html"
generate_report(results, report_path)
open_report(report_path)

flagged = results.count { |r| r[:flagged] }
failed  = results.count { |r| r[:failed] }
log "Done — #{flagged}/#{results.size} pages flagged#{failed > 0 ? " (#{failed} could not be captured)" : ''}"
exit(flagged > 0 ? 1 : 0)
