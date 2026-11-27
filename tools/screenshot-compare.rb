#!/usr/bin/env ruby
# frozen_string_literal: true

require 'ferrum'
require 'fileutils'
require 'open3'
require 'socket'
require 'base64'
require 'yaml'
require 'timeout'

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

# ── Baseline worktree ─────────────────────────────────────────────────────────

def git_capture(*args, dir: PROJECT_DIR, timeout: 60)
  out = +''
  status = nil
  Timeout.timeout(timeout) do
    out, status = Open3.capture2e({ 'GIT_TERMINAL_PROMPT' => '0' }, 'git', *args, chdir: dir)
  end
  [out.strip, status.success?]
rescue Timeout::Error
  ['timed out', false]
end

# Picks the ref to check out. A `<remote>/<branch>` ref is fetched first so the baseline is
# what is really on the remote (deploys push to origin/release; the local branch is never
# updated). If the fetch fails (offline, no remote) falls back to the local branch of the
# same name with a warning. Returns [ref, stale_note_or_nil].
def resolve_baseline(ref)
  remotes = git_capture('remote').first.split
  remote, branch = ref.split('/', 2)
  return [ref, nil] unless branch && remotes.include?(remote)

  log "Fetching #{ref}"
  out, ok = git_capture('fetch', remote, "+refs/heads/#{branch}:refs/remotes/#{remote}/#{branch}")
  return [ref, nil] if ok

  reason = (out.lines.find { |l| l.start_with?('fatal:', 'error:') } || out.lines.first).to_s.strip
  _, local_ok = git_capture('rev-parse', '--verify', '--quiet', "refs/heads/#{branch}")
  if local_ok
    note = "could not fetch #{ref} (#{reason}) — using LOCAL branch '#{branch}', the baseline may be stale"
    log "⚠ #{note}"
    return [branch, note]
  end
  _, tracking_ok = git_capture('rev-parse', '--verify', '--quiet', "refs/remotes/#{ref}")
  abort "✗ could not fetch #{ref} (#{reason}) and there is no local '#{branch}' or cached #{ref} to fall back to" unless tracking_ok
  note = "could not fetch #{ref} (#{reason}) — using cached #{ref}, the baseline may be stale"
  log "⚠ #{note}"
  [ref, note]
end

# Detached checkout of the baseline, independent of any local branch. Returns a description.
def create_baseline_worktree(ref)
  checkout_ref, stale_note = resolve_baseline(ref)
  system("git worktree remove #{WORKTREE} --force 2>/dev/null", chdir: PROJECT_DIR)
  FileUtils.rm_rf(WORKTREE)
  system('git worktree prune', chdir: PROJECT_DIR)
  run! "git worktree add --detach #{WORKTREE} #{checkout_ref}"
  run! 'git submodule update --init --recursive', dir: WORKTREE
  commit = `git -C "#{WORKTREE}" log -1 --format='%h %s'`.strip
  desc = "#{checkout_ref == ref ? ref : "#{checkout_ref} (requested #{ref})"} @ #{commit}"
  desc += " — ⚠ #{stale_note}" if stale_note
  log "Baseline: #{desc}"
  desc
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

# ── Project config (nanoc.yaml) ───────────────────────────────────────────────
#   screenshot_baseline: origin/release    # ref to compare against (env SCREENSHOT_BASELINE overrides)
#   screenshot_threshold: 1.0              # % of changed pixels above which a page is `changed`
#   screenshot_expected_changes: [/, /privacy/]   # reported as `changed (expected)`, never trip --strict
#   screenshot_samples:                    # pages generated into output/ after compile
#     - path: some-dir                     # directory under output/ containing <slug>/index.html
#       count: 10
#   screenshot_viewports:                  # optional; absent = one 1440px viewport, as before
#     - width: 1440                        # 200..4000
#       height: 900                        # optional initial height (default 900)
#       label: desktop                     # optional (default: the width, `-dark` appended for dark)
#       scheme: dark                       # optional: light | dark (emulates prefers-color-scheme)
#       pages: [/, /premium/]              # optional: limit to these URLs (default: all non-sampled pages)
#       samples: true                      # optional: also capture screenshot_samples pages
#                                          #   (default: true for the first entry, false for the rest)

def load_project_config(project_dir)
  file = File.join(project_dir, 'nanoc.yaml')
  return {} unless File.exist?(file)
  cfg = YAML.safe_load(File.read(file), permitted_classes: [Symbol], aliases: true)
  cfg.is_a?(Hash) ? cfg : {}
end

PROJECT_CONFIG = load_project_config(PROJECT_DIR)

def threshold_config(cfg)
  raw = cfg['screenshot_threshold']
  return 1.0 if raw.nil?
  Float(raw)
rescue ArgumentError, TypeError
  log "⚠ screenshot_threshold #{raw.inspect} is not a number — using 1.0"
  1.0
end

def expected_changes_config(cfg)
  raw = cfg['screenshot_expected_changes']
  return [] if raw.nil?
  unless raw.is_a?(Array)
    log '⚠ screenshot_expected_changes must be a list — ignoring'
    return []
  end
  raw.map { |u| url_key(u) }
end

def sample_config(cfg)
  entries = cfg['screenshot_samples']
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

DEFAULT_WIDTH    = 1440
DEFAULT_HEIGHT   = 900
MIN_WIDTH        = 200
MAX_WIDTH        = 4000

def url_key(u) = "/#{u.to_s.strip.sub(%r{\A/+}, '')}"

def parse_viewport(e, first)
  return [nil, 'not a mapping'] unless e.is_a?(Hash)
  w = e['width']
  w = w.to_i if w.is_a?(String) && w.strip.match?(/\A\d+\z/)
  return [nil, "width #{e['width'].inspect} must be an integer from #{MIN_WIDTH} to #{MAX_WIDTH}"] unless w.is_a?(Integer) && w.between?(MIN_WIDTH, MAX_WIDTH)

  h = e.key?('height') ? e['height'] : DEFAULT_HEIGHT
  return [nil, "height #{h.inspect} must be an integer from #{MIN_WIDTH} to #{MAX_HEIGHT}"] unless h.is_a?(Integer) && h.between?(MIN_WIDTH, MAX_HEIGHT)

  scheme = e['scheme']&.to_s&.strip&.downcase
  return [nil, "scheme #{e['scheme'].inspect} must be light or dark"] unless [nil, 'light', 'dark'].include?(scheme)

  pages = e['pages']
  if e.key?('pages')
    return [nil, 'pages must be a non-empty list of URLs'] unless pages.is_a?(Array) && !pages.empty?
    pages = pages.map { |u| url_key(u) }
  end

  samples = e.key?('samples') ? e['samples'] : first
  return [nil, "samples #{samples.inspect} must be true or false"] unless [true, false].include?(samples)

  label = e['label'].to_s.strip
  label = "#{w}#{scheme == 'dark' ? '-dark' : ''}" if label.empty?
  [{ width: w, height: h, label: label, scheme: scheme, pages: pages, samples: samples }, nil]
end

def viewport_slug(label) = label.gsub(/[^\w.-]+/, '_')

# Returns [viewports, configured]. Without the key (or with no valid entry) this is the single
# legacy viewport: 1440px, no colour-scheme emulation, plain filenames, no overflow check.
def viewport_config(cfg)
  legacy = [{ width: DEFAULT_WIDTH, height: DEFAULT_HEIGHT, label: DEFAULT_WIDTH.to_s, scheme: nil,
              pages: nil, samples: true }]
  entries = cfg['screenshot_viewports']
  return [legacy, false] if entries.nil?
  unless entries.is_a?(Array)
    log '⚠ screenshot_viewports must be a list — ignoring'
    return [legacy, false]
  end
  seen = {}
  vps = entries.filter_map do |e|
    vp, err = parse_viewport(e, seen.empty?)
    if vp && seen[viewport_slug(vp[:label])]
      vp, err = nil, "duplicate label #{vp[:label].inspect}"
    end
    if vp.nil?
      log "⚠ screenshot_viewports: skipping entry #{e.inspect} (#{err})"
      next
    end
    seen[viewport_slug(vp[:label])] = true
    vp
  end
  if vps.empty?
    log '⚠ screenshot_viewports: no valid entries — using the default 1440px viewport'
    return [legacy, false]
  end
  [vps, true]
end

THRESHOLD        = threshold_config(PROJECT_CONFIG)
EXPECTED_CHANGES = expected_changes_config(PROJECT_CONFIG)
VIEWPORTS, VIEWPORTS_CONFIGURED = viewport_config(PROJECT_CONFIG)
MULTI_VIEWPORT   = VIEWPORTS.size > 1
# `/page/ @ 810` suffixes are omitted only for today's lone default viewport.
SHOW_VIEWPORT    = MULTI_VIEWPORT || VIEWPORTS.first[:width] != DEFAULT_WIDTH || VIEWPORTS.first[:scheme] ||
                   VIEWPORTS.first[:label] != DEFAULT_WIDTH.to_s
SCHEME_EMULATION = VIEWPORTS.any? { |v| v[:scheme] }
UNIT             = MULTI_VIEWPORT ? 'captures' : 'pages'
STRICT           = ENV['LAYOUT_STRICT'] == '1'
# Ref the current build is compared against (env wins over nanoc.yaml `screenshot_baseline`).
BASELINE_REF     = (ENV['SCREENSHOT_BASELINE'].to_s.strip.then { |v| v.empty? ? nil : v } ||
                    PROJECT_CONFIG['screenshot_baseline'] || 'origin/release').to_s

# ── Sampled generated pages ───────────────────────────────────────────────────
# Pages written into output/ after compile (not nanoc items) are invisible to
# `nanoc show-data`, so they are sampled from output/<path>/*/index.html instead.

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

# builds: { release: dir, current: dir } (or just { current: dir }). Slugs present in
# every build are sampled first, so each build screenshots identical pages. If there
# are no common slugs (one build lacks those pages — no baseline), sample each build's
# own slugs instead; those pages are then reported as new/removed rather than dropped.
# Returns pages tagged with the builds (:sides) they should be screenshotted in.
def sample_pages(config, builds)
  config.flat_map do |entry|
    slugs  = builds.transform_values { |dir| list_slugs(dir, entry[:path]) }
    common = slugs.values.reduce(:&)
    label  = "Sampling /#{entry[:path]}/:"
    counts = slugs.map { |side, list| "#{side} #{list.size}" }.join(', ')

    chosen =
      if common.any? || builds.size == 1
        picked  = evenly_spaced(common, entry[:count])
        skipped = slugs.values.flatten.uniq.size - common.size
        log "#{label} #{picked.size} of #{common.size} common pages" \
            "#{skipped > 0 ? " (#{skipped} skipped — only in one build)" : ''}: #{picked.join(', ')}"
        picked.map { |slug| [slug, builds.keys] }
      else
        per_side = slugs.transform_values { |list| evenly_spaced(list, entry[:count]) }
        if per_side.values.all?(&:empty?)
          log "#{label} no pages in any build (#{counts})"
        else
          log "#{label} no common pages (#{counts}) — no baseline, so sampling each build's own " \
              "pages (reported as new/removed): " \
              "#{per_side.map { |side, l| "#{side}: #{l.join(', ')}" }.reject { |x| x.end_with?(': ') }.join(' | ')}"
        end
        per_side.flat_map { |side, list| list.map { |slug| [slug, [side]] } }
      end

    chosen.map do |slug, sides|
      url = "/#{entry[:path]}/#{slug}/"
      { url: url, filename: url_to_filename(url), sides: sides, sample: true }
    end
  end
end

def with_samples(pages, samples, side)
  (pages + samples.select { |p| p[:sides].include?(side) }).uniq { |p| p[:url] }.sort_by { |p| p[:url] }
end

# ── Captures (page × viewport) ────────────────────────────────────────────────

# A capture is identified by url + viewport label. The first viewport keeps today's
# filename; the others get `<filename>__<label>.png`.
def capture_filename(page, vp, index)
  return page[:filename] if index.zero?
  "#{page[:filename].sub(/\.png\z/, '')}__#{viewport_slug(vp[:label])}.png"
end

def viewport_applies?(vp, page)
  return false if page[:sample] && !vp[:samples]
  vp[:pages].nil? || vp[:pages].include?(page[:url])
end

def build_captures(pages)
  VIEWPORTS.each_with_index.flat_map do |vp, i|
    pages.select { |p| viewport_applies?(vp, p) }.map do |page|
      { key: [page[:url], vp[:label]], url: page[:url], vp: vp, vp_index: i,
        filename: capture_filename(page, vp, i) }
    end
  end
end

def capture_name(url, vp) = SHOW_VIEWPORT ? "#{url} @ #{vp[:label]}" : url

# ── Screenshot ────────────────────────────────────────────────────────────────

class CaptureError < StandardError; end

OVERRIDES_PATH = File.join(PROJECT_DIR, 'screenshot-overrides.js')
FREEZE_SCRIPT  = File.exist?(OVERRIDES_PATH) ? File.read(OVERRIDES_PATH) : nil

# Returns { [url, label] => { status: :ok | :capped | :failed, doc_h:, overflow:, error: } }.
# A page that times out is logged and recorded as :failed instead of aborting the run.
def screenshot_pages(captures, base_url, out_dir, browser)
  FileUtils.mkdir_p(out_dir)
  captures.to_h do |cap|
    url = "#{base_url}#{cap[:url]}"
    out = File.join(out_dir, cap[:filename])
    log "  #{capture_name(url, cap[:vp])} → #{cap[:filename]}"
    outcome = begin
      capture_page(url, out, browser, cap[:vp])
    rescue Ferrum::Error, CaptureError => e
      FileUtils.rm_f(out)
      browser.restart if e.is_a?(Ferrum::DeadBrowserError)
      log "  ⚠ could not capture #{capture_name(cap[:url], cap[:vp])}: #{e.class}: #{e.message.lines.first&.strip}"
      { status: :failed, error: e.class.name }
    end
    [cap[:key], outcome]
  end
end

# Emulates (or, once any viewport uses a scheme, resets) prefers-color-scheme for the page.
def emulate_scheme(browser, scheme)
  features = scheme ? [{ name: 'prefers-color-scheme', value: scheme }] : []
  browser.page.command('Emulation.setEmulatedMedia', features: features)
end

def capture_page(url, out, browser, vp)
  browser.resize(width: vp[:width], height: vp[:height])
  emulate_scheme(browser, vp[:scheme]) if SCHEME_EMULATION
  browser.goto(url)
  status = browser.network.status
  raise CaptureError, "HTTP #{status}" if status && status >= 400
  browser.network.wait_for_idle(duration: 0.3, timeout: 30)
  browser.execute(FREEZE_SCRIPT) if FREEZE_SCRIPT
  browser.network.wait_for_idle(duration: 0.3, timeout: 10)
  50.times { break if browser.evaluate("window.__renderReady === true"); sleep 0.1 }
  doc_h = browser.evaluate('document.documentElement.scrollHeight')
  capped = doc_h > MAX_HEIGHT
  log "    doc_h=#{doc_h}px"
  log "    ⚠ capped at #{MAX_HEIGHT}px (page is #{doc_h}px tall)" if capped
  outcome = { status: capped ? :capped : :ok, doc_h: doc_h }
  # Absolute check, no baseline needed. Only with screenshot_viewports, so existing setups are unchanged.
  if VIEWPORTS_CONFIGURED
    scroll_w, inner_w = browser.evaluate('[document.documentElement.scrollWidth, window.innerWidth]')
    if scroll_w > inner_w
      log "    ⚠ horizontal overflow at #{vp[:label]} (scrollWidth #{scroll_w} > #{inner_w})"
      outcome.merge!(overflow: true, scroll_w: scroll_w, inner_w: inner_w)
    end
  end
  browser.resize(width: vp[:width], height: [doc_h, MAX_HEIGHT].min)
  sleep 0.5
  browser.screenshot(path: out, full: false)
  outcome
end

# ── ImageMagick compare ───────────────────────────────────────────────────────

def compare_images(current, release_img, diff, threshold)
  w, h = `identify -format "%w %h" "#{current}"`.strip.split.map(&:to_i)
  total = w * h

  # compare exits 1 when images differ — capture output, ignore exit code
  output, = Open3.capture2e("compare -metric AE -fuzz 3% \"#{current}\" \"#{release_img}\" \"#{diff}\"")
  ae = output.strip.to_f

  pct = total > 0 ? (ae / total * 100).round(2) : 0.0
  { ae: ae.to_i, total: total, pct: pct, status: pct > threshold ? :changed : :unchanged }
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

STATUS_ORDER = { failed: 0, removed: 1, changed: 2, new: 3, unchanged: 4 }.freeze

def status_label(r)
  r[:expected] && %i[changed removed].include?(r[:status]) ? "#{r[:status]} (expected)" : r[:status].to_s
end

def status_counts(results)
  by = results.group_by { |r| r[:status] }
  { failed: by.fetch(:failed, []).size, new: by.fetch(:new, []).size,
    removed: by.fetch(:removed, []).size, changed: by.fetch(:changed, []).size,
    expected: results.count { |r| r[:expected] && %i[changed removed].include?(r[:status]) },
    unchanged: by.fetch(:unchanged, []).size }
end

def summary_line(results)
  c = status_counts(results)
  parts = ["#{c[:failed]} failed", "#{c[:new]} new"]
  parts << "#{c[:removed]} removed" if c[:removed] > 0
  parts << "#{c[:changed]} changed#{c[:expected] > 0 ? " (#{c[:expected]} expected)" : ''}"
  parts << "#{c[:unchanged]} unchanged"
  "#{parts.join(', ')} of #{results.size} #{UNIT}"
end

def sort_results(results)
  results.sort_by { |r| [STATUS_ORDER[r[:status]], -(r[:pct] || 0), r[:url], r[:vp_index].to_i] }
end

def overflow_text(r) = "overflow (scrollWidth #{r[:overflow][:scroll_w]} > #{r[:overflow][:inner_w]})"

def pct_text(r) = r[:pct] ? "#{r[:pct]}%" : (r[:status] == :new ? 'new, no baseline' : '—')

BADGE_CSS = <<~CSS.gsub(/^/, '        ').prepend("\n").chomp
  .badge { display: inline-block; margin-left: 0.4rem; padding: 0 0.4rem; border-radius: 0.6rem; font-size: 0.75rem; font-weight: bold; vertical-align: middle; }
  .badge.vp { background: #333; color: #ddd; }
  .badge.overflow { background: #ff9800; color: #111; }
CSS

def generate_report(results, out_path, baseline_desc = nil)
  rows = sort_results(results)
  badge_css = VIEWPORTS_CONFIGURED ? BADGE_CSS : ''

  summary_rows = rows.map do |r|
    note = r[:notes].to_a.empty? ? '' : "<br><small>#{r[:notes].join('<br>')}</small>"
    badges = (SHOW_VIEWPORT ? "<span class=\"badge vp\">#{r[:vp][:label]}</span>" : '') +
             (r[:overflow] ? "<span class=\"badge overflow\" title=\"#{overflow_text(r)}\">overflow</span>" : '')
    "<tr><td>#{r[:url]}#{badges.empty? ? '' : " #{badges}"}#{note}</td><td>#{pct_text(r)}</td>" \
      "<td><span class=\"st st-#{r[:status]}#{r[:expected] ? ' st-expected' : ''}\">#{status_label(r)}</span></td></tr>"
  end.join("\n")

  detail_sections = rows.filter_map do |r|
    figures = case r[:status]
              when :changed
                [['Baseline', r[:release_path]], ['Current', r[:current_path]], ['Diff', r[:diff_path]]]
              when :new     then [['Current (new — no baseline)', r[:current_path]]]
              when :removed then [['Baseline (page no longer exists)', r[:release_path]]]
              when :unchanged then r[:overflow] ? [['Current (horizontal overflow)', r[:current_path]]] : nil
              end
    next unless figures
    name = capture_name(r[:url], r[:vp])
    heading = r[:status] == :changed ? "#{name} — #{r[:pct]}% changed" : "#{name} — #{r[:status]}"
    heading += " — #{overflow_text(r)}" if r[:overflow]
    imgs = figures.map { |cap, path| "<figure><figcaption>#{cap}</figcaption><img src=\"#{embed_image(path)}\"></figure>" }.join
    %(<section class="diff-section"><h2>#{heading}</h2><div class="images n#{figures.size}">#{imgs}</div></section>)
  end.join("\n")

  html = <<~HTML
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <title>Layout Comparison Report</title>
      <style>
        body { font-family: system-ui, sans-serif; margin: 2rem; background: #111; color: #eee; }
        h1 { margin-bottom: 0.5rem; }
        .summary { color: #aaa; margin-bottom: 1.5rem; }
        table { border-collapse: collapse; width: 100%; margin-bottom: 3rem; }
        th, td { padding: 0.5rem 1rem; border: 1px solid #333; text-align: left; }
        th { background: #222; }
        .st { font-weight: bold; }
        .st-failed { color: #f44336; }
        .st-removed { color: #ff9800; }
        .st-changed { color: #ffc107; }
        .st-new { color: #42a5f5; }
        .st-unchanged { color: #4caf50; }
        .st-expected { opacity: 0.6; }
        small { color: #aaa; }#{badge_css}
        .diff-section { margin-bottom: 4rem; }
        .images { display: grid; grid-template-columns: repeat(3, 1fr); gap: 1rem; }
        .images.n1 { grid-template-columns: 1fr; max-width: 50%; }
        .images img { width: 100%; border: 1px solid #333; }
        figcaption { font-size: 0.8rem; color: #aaa; margin-bottom: 0.25rem; }
      </style>
    </head>
    <body>
      <h1>Layout Comparison — #{Time.now.strftime('%Y-%m-%d %H:%M')}</h1>
      <p class="summary">#{summary_line(results)} · changed threshold #{THRESHOLD}%#{baseline_desc ? "<br>Baseline: #{baseline_desc}" : ''}</p>
      <table>
        <thead><tr><th>#{SHOW_VIEWPORT ? 'Page / viewport' : 'Page'}</th><th>Change</th><th>Status</th></tr></thead>
        <tbody>
          #{summary_rows}
        </tbody>
      </table>
      #{detail_sections}
    </body>
    </html>
  HTML

  File.write(out_path, html)
  log "Report written: #{out_path}"
end

# ── Screenshot-only report ────────────────────────────────────────────────────

def generate_screenshot_report(captures, screenshots_dir, out_path, outcomes = {})
  rows = captures.map do |cap|
    path = File.join(screenshots_dir, cap[:filename])
    src  = embed_image(path)
    o    = outcomes[cap[:key]]
    note = capture_notes(o).tap { |n| n << "horizontal overflow (scrollWidth #{o[:scroll_w]} > #{o[:inner_w]})" if o&.dig(:overflow) }.join(' · ')
    body = o&.dig(:status) == :failed ? '<p style="color:#f44336">Could not capture</p>' : %(<img src="#{src}">)
    <<~HTML
      <section class="page-section">
        <h2>#{capture_name(cap[:url], cap[:vp])}#{note.empty? ? '' : " — #{note}"}</h2>
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

def describe_viewports
  VIEWPORTS.map do |v|
    "#{v[:width]}#{v[:scheme] ? " #{v[:scheme]}" : ''}#{v[:label] == v[:width].to_s || v[:label] == "#{v[:width]}-dark" ? '' : " (#{v[:label]})"}" \
    "#{v[:pages] ? " [#{v[:pages].size} pages]" : ''}#{v[:samples] ? ' +samples' : ''}"
  end.join(', ')
end
log "Viewports: #{describe_viewports}" if VIEWPORTS_CONFIGURED

if SCREENSHOT_ONLY
  FileUtils.mkdir_p("#{TMP_BASE}/current")

  log 'Screenshot-only mode — skipping release comparison'
  log 'Compiling current branch'
  run! 'bundle exec nanoc compile'

  current_pages = discover_pages(PROJECT_DIR)
  log "Found #{current_pages.size} pages"
  current_pages = with_samples(current_pages, sample_pages(sample_config(PROJECT_CONFIG), { current: PROJECT_DIR }), :current)

  current_caps = build_captures(current_pages)
  log "#{current_caps.size} captures (#{current_pages.size} pages × #{VIEWPORTS.size} viewports, after filters)" if VIEWPORTS_CONFIGURED

  current_pid = start_server(3000, dir: PROJECT_DIR)
  browser = new_browser
  begin
    outcomes = screenshot_pages(current_caps, 'http://localhost:3000', "#{TMP_BASE}/current", browser)
  ensure
    browser.quit
    kill_server(current_pid)
  end

  report_path = "#{TMP_BASE}/report.html"
  generate_screenshot_report(current_caps, "#{TMP_BASE}/current", report_path, outcomes)
  open_report(report_path)
  failed = outcomes.count { |_, o| o[:status] == :failed }
  overflowed = outcomes.count { |_, o| o[:overflow] }
  log "Done — #{current_caps.size - failed}/#{current_caps.size} #{UNIT} screenshotted"
  exit(1) if failed > 0
  if STRICT && overflowed > 0
    log "Strict mode: #{overflowed} capture(s) with horizontal overflow — exit 2"
    exit 2
  end
  exit 0
end

FileUtils.mkdir_p(["#{TMP_BASE}/release", "#{TMP_BASE}/current", "#{TMP_BASE}/diffs"])

# -- Release worktree
log 'Setting up baseline worktree'
baseline_desc = create_baseline_worktree(BASELINE_REF)
ruby_version = File.read(File.join(WORKTREE, '.ruby-version')).strip
run! "rbenv local #{ruby_version}", dir: WORKTREE
run! 'bundle install', dir: WORKTREE
run! 'bundle exec nanoc compile', dir: WORKTREE

# Compile current too before screenshotting, so sampled detail pages can be
# chosen from the slugs present in both builds.
log 'Compiling current branch'
run! 'bundle exec nanoc compile'

release_pages = discover_pages(WORKTREE)
log "Found #{release_pages.size} pages in baseline"
current_pages = discover_pages(PROJECT_DIR)
log "Found #{current_pages.size} pages in current"

samples       = sample_pages(sample_config(PROJECT_CONFIG), { release: WORKTREE, current: PROJECT_DIR })
release_pages = with_samples(release_pages, samples, :release)
current_pages = with_samples(current_pages, samples, :current)

release_caps = build_captures(release_pages)
current_caps = build_captures(current_pages)
if VIEWPORTS_CONFIGURED
  log "Captures: #{release_caps.size} baseline + #{current_caps.size} current = #{release_caps.size + current_caps.size} " \
      "(#{release_pages.size}/#{current_pages.size} pages × #{VIEWPORTS.size} viewports, after filters)"
end

release_pid = start_server(3001, dir: WORKTREE)
browser = new_browser
begin
  release_outcomes = screenshot_pages(release_caps, 'http://localhost:3001', "#{TMP_BASE}/release", browser)
ensure
  browser.quit
  kill_server(release_pid)
  system("git worktree remove #{WORKTREE} --force 2>/dev/null")
end

# -- Current branch
current_pid = start_server(3000, dir: PROJECT_DIR)
browser = new_browser
begin
  current_outcomes = screenshot_pages(current_caps, 'http://localhost:3000', "#{TMP_BASE}/current", browser)
ensure
  browser.quit
  kill_server(current_pid)
end

# -- Compare
log 'Comparing screenshots'
release_by_key = release_caps.to_h { |c| [c[:key], c] }
current_by_key = current_caps.to_h { |c| [c[:key], c] }
all_caps = (release_caps + current_caps).uniq { |c| c[:key] }
           .sort_by { |c| [c[:url], c[:vp_index]] }

def expected_change?(url, label) = EXPECTED_CHANGES.include?(url) || EXPECTED_CHANGES.include?("#{url}@#{label}")

results = all_caps.map do |cap|
  key, url, filename = cap.values_at(:key, :url, :filename)
  paths = { current_path: "#{TMP_BASE}/current/#{filename}", release_path: "#{TMP_BASE}/release/#{filename}",
            diff_path: "#{TMP_BASE}/diffs/#{filename}" }
  in_release = release_by_key.key?(key)
  in_current = current_by_key.key?(key)
  outcomes   = { release: release_outcomes[key], current: current_outcomes[key] }
  notes      = outcomes.flat_map { |side, o| capture_notes(o).map { |n| "#{side}: #{n}" } }
  overflow   = current_outcomes[key]&.dig(:overflow) ? current_outcomes[key].slice(:scroll_w, :inner_w) : nil
  result     = { url: url, vp: cap[:vp], vp_index: cap[:vp_index], filename: filename, notes: notes, pct: nil, ae: 0,
                 total: 0, overflow: overflow, expected: expected_change?(url, cap[:vp][:label]), **paths }

  if outcomes.values.any? { |o| o&.dig(:status) == :failed }
    result.merge(status: :failed)
  elsif in_current && !in_release
    result.merge(status: :new)
  elsif in_release && !in_current
    result.merge(status: :removed)
  elsif !(File.exist?(paths[:current_path]) && File.exist?(paths[:release_path]))
    result.merge(status: :failed, notes: notes + ['screenshot missing'])
  else
    result.merge(compare_images(paths[:current_path], paths[:release_path], paths[:diff_path], THRESHOLD))
  end
end

report_path = "#{TMP_BASE}/report.html"
generate_report(results, report_path, baseline_desc)
open_report(report_path)

sort_results(results).each do |r|
  log format('  %-18s %-16s %s%s', status_label(r), pct_text(r), capture_name(r[:url], r[:vp]), r[:overflow] ? '  ⚠ overflow' : '')
end
log "Done — #{summary_line(results)}"

# Exit codes: 0 = completed (new/changed are informational); 1 = a page failed to
# capture (setup/compile errors also exit 1 via run!); 2 = --strict and unexpected
# changed/removed captures, or any horizontal overflow on a current capture. `new` never fails.
failed     = results.count { |r| r[:status] == :failed }
tripped    = results.count { |r| %i[changed removed].include?(r[:status]) && !r[:expected] }
overflowed = results.count { |r| r[:overflow] }
if failed > 0
  log "#{failed} #{MULTI_VIEWPORT ? 'capture' : 'page'}(s) failed — exit 1"
  exit 1
elsif STRICT && (tripped > 0 || overflowed > 0)
  log "Strict mode: #{tripped} changed/removed #{UNIT} above #{THRESHOLD}%, #{overflowed} with horizontal overflow — exit 2" if VIEWPORTS_CONFIGURED
  log "Strict mode: #{tripped} changed/removed page(s) above #{THRESHOLD}% — exit 2" unless VIEWPORTS_CONFIGURED
  exit 2
end
exit 0
