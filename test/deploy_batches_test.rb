# frozen_string_literal: true

# Unit tests for tools/deploy-batches.rb, driven through its CLI.
#   ruby test/deploy_batches_test.rb

require 'minitest/autorun'
require 'digest'
require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'

class DeployBatchesTest < Minitest::Test
  TOOL = File.expand_path('../tools/deploy-batches.rb', __dir__)

  def run_tool(*args, stdin: '')
    out, err, status = Open3.capture3('ruby', TOOL, *args, stdin_data: stdin)
    # capture3 tags output with the default external encoding, which is US-ASCII under LANG=C
    [out.force_encoding('UTF-8'), err.force_encoding('UTF-8'), status]
  end

  def paths_for(keys, group: 10, all: 1000)
    out, _err, status = run_tool('invalidate', '--group-threshold', group.to_s, '--all-threshold', all.to_s, '--list',
                                 stdin: keys.join("\n"))
    assert status.success?
    out.split("\n")
  end

  # --- invalidate ---------------------------------------------------------

  def test_plain_file_is_invalidated_by_exact_path
    assert_equal ['/img/a.png'], paths_for(['img/a.png'])
  end

  def test_directory_index_invalidates_wildcard_and_bare_path
    assert_equal ['/foo/*', '/foo'], paths_for(['foo/index.html'])
  end

  def test_root_index_invalidates_slash_and_index
    assert_equal ['/', '/index.html'], paths_for(['index.html'])
  end

  def test_files_below_a_directory_index_are_covered_by_its_wildcard
    assert_equal ['/foo/*', '/foo'], paths_for(['foo/index.html', 'foo/x.css', 'foo/bar/y.js'])
  end

  def test_busy_directory_collapses_to_wildcard
    keys = (1..3).map { |i| "img/#{i}.png" } + ['other.css']
    assert_equal ['/img/*', '/other.css'], paths_for(keys, group: 3)
  end

  def test_directory_under_group_threshold_stays_individual
    assert_equal ['/img/1.png', '/img/2.png'], paths_for(['img/1.png', 'img/2.png'], group: 3)
  end

  def test_root_wildcard_swallows_everything
    keys = %w[a.css b.css c.css foo/index.html]
    assert_equal ['/*'], paths_for(keys, group: 3)
  end

  def test_nested_wildcard_is_dropped_when_parent_is_wildcarded
    keys = ['a/index.html', 'a/b/index.html']
    # /a/b/* and /a/b are both covered by /a/*
    assert_equal ['/a/*', '/a'], paths_for(keys)
  end

  def test_over_all_threshold_falls_back_to_single_wildcard
    keys = (1..20).map { |i| "d#{i}/f.css" }
    assert_equal ['/*'], paths_for(keys, all: 10)
  end

  def test_paths_are_percent_encoded
    paths = paths_for(['sp ace/é page.html', 'q"uote.js', 'a+b.css', 'star*.css'])
    assert_includes paths, '/sp%20ace/%C3%A9%20page.html'
    assert_includes paths, '/q%22uote.js'
    assert_includes paths, '/a%2Bb.css'
    # a literal * in a key must not become a wildcard; the encoder leaves it for CloudFront to see
    assert(paths.any? { |p| p.start_with?('/star') })
  end

  def test_requests_are_split_at_3000_paths_with_unique_references
    keys = (1..3500).map { |i| "p/#{i}.css" }
    out, _err, status = run_tool('invalidate', '--group-threshold', '99999', '--all-threshold', '99999', '--ref', 'R',
                                 stdin: keys.join("\n"))
    assert status.success?
    batches = out.lines.map { |l| JSON.parse(l) }
    assert_equal [3000, 500], batches.map { |b| b['Paths']['Quantity'] }
    assert_equal %w[R-1 R-2], batches.map { |b| b['CallerReference'] }
    assert(batches.all? { |b| b['Paths']['Items'].size == b['Paths']['Quantity'] })
  end

  def test_no_keys_produces_no_requests
    out, _err, status = run_tool('invalidate', stdin: '')
    assert status.success?
    assert_equal '', out
  end

  # --- delete -------------------------------------------------------------

  def test_delete_payloads_are_split_at_1000_keys
    keys = (1..1500).map { |i| "k/#{i}" }
    out, _err, status = run_tool('delete', stdin: keys.join("\n"))
    assert status.success?
    payloads = out.lines.map { |l| JSON.parse(l) }
    assert_equal [1000, 500], payloads.map { |p| p['Objects'].size }
    assert_equal({ 'Key' => 'k/1' }, payloads.first['Objects'].first)
  end

  def test_delete_payload_keeps_awkward_keys_intact
    out, _err, = run_tool('delete', stdin: "a b/é.html\nq\"uote")
    assert_equal ['a b/é.html', 'q"uote'], JSON.parse(out)['Objects'].map { |o| o['Key'] }
  end

  def test_delete_result_prints_deleted_and_reports_errors_on_stderr
    json = JSON.generate('Deleted' => [{ 'Key' => 'a' }],
                         'Errors' => [{ 'Key' => 'b c', 'Code' => 'AccessDenied', 'Message' => 'no' }])
    out, err, status = run_tool('delete-result', stdin: json)
    assert status.success?
    assert_equal "a\n", out
    assert_match(/b c: AccessDenied no/, err)
  end

  def test_delete_result_tolerates_empty_input
    out, _err, status = run_tool('delete-result', stdin: '')
    assert status.success?
    assert_equal '', out
  end

  # --- manifest -----------------------------------------------------------

  def test_manifest_matches_find_semantics_and_sorting
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, 'b/sub'))
      FileUtils.mkdir_p(File.join(dir, '.hiddendir'))
      File.write(File.join(dir, 'z.txt'), 'z')
      File.write(File.join(dir, 'b/sub/a.txt'), 'a')
      File.write(File.join(dir, 'b/c d.txt'), 'c')
      File.write(File.join(dir, '.hidden'), 'skip me')
      File.write(File.join(dir, '.hiddendir/kept.txt'), 'kept') # only the file's own name counts, as with find
      File.symlink(File.join(dir, 'z.txt'), File.join(dir, 'link.txt'))

      out, _err, status = run_tool('manifest', '--dir', dir)
      assert status.success?
      lines = out.split("\n")
      expected = {
        'z.txt' => 'z', 'b/sub/a.txt' => 'a', 'b/c d.txt' => 'c', '.hiddendir/kept.txt' => 'kept'
      }.map { |rel, body| "#{Digest::SHA256.hexdigest(body)}  #{rel}" }
      assert_equal expected.sort, lines
      assert_equal lines.map(&:b).sort, lines.map(&:b), 'must be bytewise sorted (LC_ALL=C)'
    end
  end

  def test_manifest_of_empty_dir_is_empty
    Dir.mktmpdir do |dir|
      out, _err, status = run_tool('manifest', '--dir', dir)
      assert status.success?
      assert_equal '', out
    end
  end

  # --- stage --------------------------------------------------------------

  def test_stage_links_or_copies_only_listed_files
    Dir.mktmpdir do |dir|
      src = File.join(dir, 'src')
      dest = File.join(dir, 'dest')
      FileUtils.mkdir_p(File.join(src, 'a/b'))
      File.write(File.join(src, 'a/b/one.css'), '1')
      File.write(File.join(src, 'two.html'), '2')
      File.write(File.join(src, 'skipped.js'), '3')

      _out, _err, status = run_tool('stage', '--src', src, '--dest', dest, stdin: "a/b/one.css\ntwo.html\n")
      assert status.success?
      assert_equal '1', File.read(File.join(dest, 'a/b/one.css'))
      assert_equal '2', File.read(File.join(dest, 'two.html'))
      refute File.exist?(File.join(dest, 'skipped.js'))
    end
  end

  def test_unknown_command_exits_2
    _out, err, status = run_tool('bogus')
    assert_equal 2, status.exitstatus
    assert_match(/usage/, err)
  end
end
