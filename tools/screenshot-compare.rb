#!/usr/bin/env ruby
# frozen_string_literal: true

require 'ferrum'
require 'fileutils'
require 'open3'
require 'socket'
require 'base64'

PROJECT_DIR = ENV.fetch('PROJECT_DIR') { abort 'PROJECT_DIR env var not set — run via check-layouts.sh' }
TMP_BASE    = File.join(PROJECT_DIR, 'tmp', 'screenshots')
WORKTREE    = File.join(PROJECT_DIR, 'tmp', 'worktree-release')

# ── Helpers ───────────────────────────────────────────────────────────────────

def log(msg) = puts("▶ #{msg}")

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

# ── Screenshot ────────────────────────────────────────────────────────────────

FREEZE_SCRIPT = <<~JS
  const style = document.createElement('style');
  style.textContent = '*, *::before, *::after { animation: none !important; transition: none !important; scroll-behavior: auto !important; }';
  document.head.appendChild(style);
  document.querySelectorAll('[data-animate], [data-animate-stagger] > *, [data-animate-chips] > *').forEach(el => el.classList.add('is-visible'));
  const hero = document.querySelector('.hero__content');
  if (hero) hero.style.setProperty('--hero-opacity', '1');
JS

def screenshot_pages(pages, base_url, out_dir, browser)
  FileUtils.mkdir_p(out_dir)
  pages.each do |page|
    url = "#{base_url}#{page[:url]}"
    out = File.join(out_dir, page[:filename])
    log "  #{url} → #{page[:filename]}"
    browser.goto(url)
    browser.network.wait_for_idle
    browser.execute(FREEZE_SCRIPT)
    sleep 0.5
    browser.screenshot(path: out, full: true)
  end
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

# ── HTML report ───────────────────────────────────────────────────────────────

def embed_image(path)
  return '' unless File.exist?(path)
  "data:image/png;base64,#{Base64.strict_encode64(File.binread(path))}"
end

def generate_report(results, out_path)
  rows = results.sort_by { |r| -r[:pct] }

  summary_rows = rows.map do |r|
    status = r[:flagged] ? '<span class="fail">FAIL</span>' : '<span class="pass">PASS</span>'
    "<tr><td>#{r[:url]}</td><td>#{r[:pct]}%</td><td>#{status}</td></tr>"
  end.join("\n")

  detail_sections = rows.select { |r| r[:flagged] }.map do |r|
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
      #{detail_sections.empty? ? '<p style="color:#4caf50">No regressions detected.</p>' : detail_sections}
    </body>
    </html>
  HTML

  File.write(out_path, html)
  log "Report written: #{out_path}"
end

# ── Main ──────────────────────────────────────────────────────────────────────

FileUtils.rm_rf(TMP_BASE)
FileUtils.mkdir_p(["#{TMP_BASE}/release", "#{TMP_BASE}/current", "#{TMP_BASE}/diffs"])

# -- Release worktree
log 'Setting up release worktree'
system("git worktree remove #{WORKTREE} --force 2>/dev/null")
run! "git worktree add #{WORKTREE} release"
run! 'bundle exec nanoc compile', dir: WORKTREE

release_pages = discover_pages(WORKTREE)
log "Found #{release_pages.size} pages in release"

release_pid = start_server(3001, dir: WORKTREE)
browser = Ferrum::Browser.new(headless: true, window_size: [1440, 900])
begin
  screenshot_pages(release_pages, 'http://localhost:3001', "#{TMP_BASE}/release", browser)
ensure
  browser.quit
  kill_server(release_pid)
  system("git worktree remove #{WORKTREE} --force 2>/dev/null")
end

# -- Current branch
log 'Compiling current branch'
run! 'bundle exec nanoc compile'

current_pages = discover_pages(PROJECT_DIR)
log "Found #{current_pages.size} pages in current"

current_pid = start_server(3000, dir: PROJECT_DIR)
browser = Ferrum::Browser.new(headless: true, window_size: [1440, 900])
begin
  screenshot_pages(current_pages, 'http://localhost:3000', "#{TMP_BASE}/current", browser)
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

  unless File.exist?(current_path) && File.exist?(release_path)
    next { url: url, filename: filename, pct: 100.0, flagged: true,
           ae: 0, total: 0, current_path: current_path,
           release_path: release_path, diff_path: diff_path }
  end

  compare_images(current_path, release_path, diff_path)
    .merge(url: url, filename: filename, current_path: current_path,
           release_path: release_path, diff_path: diff_path)
end

report_path = "#{TMP_BASE}/report.html"
generate_report(results, report_path)
`open "#{report_path}"`

flagged = results.count { |r| r[:flagged] }
log "Done — #{flagged}/#{results.size} pages flagged"
exit(flagged > 0 ? 1 : 0)
