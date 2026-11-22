#!/bin/bash
# End-to-end tests for deploy.sh (production + staging paths) against a fake
# `aws` CLI (test/deploy/fake-aws) and a throwaway git repo + bare remote.
# Run from anywhere:  bash test/deploy/run.sh
#
# Needs: bash, git, ruby. No AWS credentials or network access.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PROJ="$WORK/proj"
mkdir -p "$WORK/bin" "$WORK/bucket" "$PROJ/output"
cp "$REPO/test/deploy/fake-aws" "$WORK/bin/aws"
chmod +x "$WORK/bin/aws"

export PATH="$WORK/bin:$PATH"
export FAKE_BUCKET="$WORK/bucket" FAKE_LOG="$WORK/aws.log" FAKE_CF="$WORK/cf.log"
export CI=1 AWS_REGION=eu-west-2 AWS_PAGER=""
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
unset FAIL_MATCH FAIL_DELETE

TODAY="$(date +%Y-%m-%d)"
PASSES=0
FAILS=0
OUT=""
RC=0

# --- helpers -----------------------------------------------------------------

pass() { PASSES=$((PASSES + 1)); echo "  ok   - $1"; }
fail() {
    FAILS=$((FAILS + 1)); echo "  FAIL - $1"
    echo "         last deploy output (tail):"; printf '%s\n' "$OUT" | tail -12 | sed 's/^/         | /'
}
assert_eq()       { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1 (missing '$3')"; fi; }
assert_missing()  { if [[ "$2" != *"$3"* ]]; then pass "$1"; else fail "$1 (unexpected '$3')"; fi; }

run_deploy() {
    RC=0
    OUT=$(cd "$PROJ" && bash "$REPO/deploy.sh" "$@" 2>&1) || RC=$?
}

tag_count()   { git -C "$PROJ" tag | wc -l | tr -d ' '; }
bucket_list() { (cd "$FAKE_BUCKET" && find . -type f | sed 's|^\./||' | LC_ALL=C sort | tr '\n' ' '); }
cf_requests() { if [[ -s "$FAKE_CF" ]]; then wc -l < "$FAKE_CF" | tr -d ' '; else echo 0; fi; }
# All invalidated paths across every request, bytewise sorted, space separated
cf_paths() {
    [[ -s "$FAKE_CF" ]] || return 0
    ruby -rjson -e 'File.foreach(ARGV[0]) { |l| puts JSON.parse(l)["Paths"]["Items"] }' "$FAKE_CF" | LC_ALL=C sort | tr '\n' ' '
}
cf_quantities() {
    [[ -s "$FAKE_CF" ]] || return 0
    ruby -rjson -e 'File.foreach(ARGV[0]) { |l| puts JSON.parse(l)["Paths"]["Quantity"] }' "$FAKE_CF" | tr '\n' ' '
}
aws_calls() { grep -c "^$1" "$FAKE_LOG" 2>/dev/null || true; }
reset_logs() { : > "$FAKE_LOG"; : > "$FAKE_CF"; }
deployed_entry() { grep "  $1\$" "$PROJ/.deployed" | cut -c1-8; }

if command -v sha256sum >/dev/null 2>&1; then SHA=(sha256sum); else SHA=(shasum -a 256); fi
legacy_manifest() {
    (cd "$PROJ/output" && find . -type f ! -name '.*' -print0 | while IFS= read -r -d '' f; do "${SHA[@]}" "$f"; done \
        | sed 's|  \./|  |' | LC_ALL=C sort)
}

# --- fixture -----------------------------------------------------------------

cd "$PROJ"
git init -q -b main . && git init -q --bare "$WORK/remote.git" && git remote add origin "$WORK/remote.git"
cat > nanoc.yaml <<'YAML'
s3_bucket: "b"
cloudfront_distribution_id: "E1"
aws_region: "eu-west-2"
staging:
  s3_bucket: "b-staging"
  cloudfront_distribution_id: "E2"
  aws_region: "eu-west-2"
YAML
mkdir -p output/foo output/img "output/sp ace"
for f in index.html foo/index.html foo/x.css img/a.png "sp ace/é page.html" about.html; do echo "v1 $f" > "output/$f"; done
echo "build junk" > output/.hidden
git add -A . && git commit -qm init && git push -q -u origin main

# --- scenarios ---------------------------------------------------------------

echo "== dry-run on a first deploy"
reset_logs
run_deploy --deploy-only --dry-run
assert_eq "exit 0" 0 "$RC"
assert_contains "reports counts" "$OUT" "would upload 6, delete 0"
assert_contains "lists grouped path" "$OUT" "/foo/*"
assert_eq "no s3 cp calls" 0 "$(aws_calls 's3 cp')"
assert_eq "no invalidations" 0 "$(cf_requests)"
[[ ! -e "$PROJ/.deployed" ]] && pass ".deployed not written" || fail ".deployed not written"
assert_eq "no tag" 0 "$(tag_count)"

echo "== first production deploy"
reset_logs
run_deploy --deploy-only
assert_eq "exit 0" 0 "$RC"
assert_eq "bucket contents" "about.html foo/index.html foo/x.css img/a.png index.html sp ace/é page.html " "$(bucket_list)"
assert_eq "dotfile not uploaded" "" "$(bucket_list | tr ' ' '\n' | grep '^\.' || true)"
assert_eq "one s3 cp per phase (assets, pages)" 2 "$(aws_calls 's3 cp')"
assert_contains "announces hashing" "$OUT" "Hashing output/ (6 files)"
assert_contains "announces asset batch" "$OUT" "Uploading 2 assets (0/6 done so far)"
assert_contains "announces page batch" "$OUT" "Uploading 4 pages (2/6 done so far)"
assert_contains "reports each file (few files)" "$OUT" "uploaded foo/x.css (1/6)"
assert_contains "reports last file" "$OUT" "uploaded sp ace/é page.html (6/6)"
assert_contains "reports invalidation request" "$OUT" "creating invalidation request 1/1"
assert_eq "no per-file rm" 0 "$(aws_calls 's3 rm')"
assert_eq "one invalidation request" 1 "$(cf_requests)"
assert_eq "grouped + encoded paths" "/ /about.html /foo /foo/* /img/a.png /index.html /sp%20ace/%C3%A9%20page.html " "$(cf_paths)"
assert_eq ".deployed identical to legacy format" "$(legacy_manifest)" "$(cat "$PROJ/.deployed")"
assert_eq "release tag created" "${TODAY}-01" "$(git -C "$PROJ" tag | tail -1)"
assert_eq "tag pushed" "${TODAY}-01" "$(git -C "$WORK/remote.git" tag | tail -1)"
assert_eq "release commit made" "*** Release ${TODAY} ***" "$(git -C "$PROJ" log -1 --format=%s)"
assert_eq "scratch dir removed" "" "$(ls -A "$PROJ" | grep '^\.deploy-tmp' || true)"

echo "== no changes"
reset_logs
run_deploy --deploy-only
assert_eq "exit 0" 0 "$RC"
assert_contains "says nothing to deploy" "$OUT" "nothing to deploy"
assert_eq "no s3 calls" 0 "$(aws_calls 's3 ')"
assert_eq "no invalidations" 0 "$(cf_requests)"
assert_eq "no new tag" 1 "$(tag_count)"

echo "== change + add + delete"
reset_logs
echo "v2" > output/foo/x.css; echo "v2" > output/about.html; echo "new" > output/new.js; rm output/img/a.png
run_deploy --deploy-only
assert_eq "exit 0" 0 "$RC"
assert_eq "bucket updated" "about.html foo/index.html foo/x.css index.html new.js sp ace/é page.html " "$(bucket_list)"
assert_eq "content replaced" "v2" "$(cat "$FAKE_BUCKET/foo/x.css")"
assert_eq "one delete-objects call" 1 "$(aws_calls 's3api delete-objects')"
assert_contains "reports delete batch" "$OUT" "deleting batch 1/1"
assert_eq "invalidated changed + deleted only" "/about.html /foo/x.css /img/a.png /new.js " "$(cf_paths)"
assert_eq ".deployed matches legacy format" "$(legacy_manifest)" "$(cat "$PROJ/.deployed")"
assert_eq "second tag" 2 "$(tag_count)"

echo "== asset upload fails: HTML skipped, nothing tagged, retry works"
reset_logs
echo "v3" > output/foo/x.css; echo "v3" > output/about.html; echo "v3" > output/other.png
old_about=$(deployed_entry about.html)
FAIL_MATCH=x.css run_deploy --deploy-only
assert_eq "exit 1" 1 "$RC"
assert_contains "explains HTML skipped" "$OUT" "skipping HTML"
assert_contains "failure shown live, without temp path" "$OUT" "upload failed: stage-assets/foo/x.css"
assert_eq "HTML not uploaded" "v2" "$(cat "$FAKE_BUCKET/about.html")"
assert_eq "other asset still uploaded" "v3" "$(cat "$FAKE_BUCKET/other.png")"
assert_eq "only the succeeded file invalidated" "/other.png " "$(cf_paths)"
assert_eq "no new tag" 2 "$(tag_count)"
assert_eq "failed page keeps previous .deployed entry" "$old_about" "$(deployed_entry about.html)"
assert_eq "succeeded file recorded" "$(cd output && "${SHA[@]}" other.png | cut -c1-8)" "$(deployed_entry other.png)"
reset_logs
run_deploy --deploy-only
assert_eq "retry exit 0" 0 "$RC"
assert_eq "retry uploads only the leftovers" "/about.html /foo/x.css " "$(cf_paths)"
assert_eq "retry tags" 3 "$(tag_count)"
assert_eq "bucket now current" "v3" "$(cat "$FAKE_BUCKET/about.html")"

echo "== HTML upload fails: assets recorded, page retried"
reset_logs
echo "v4" > output/about.html; echo "v4" > output/extra.js
FAIL_MATCH=about.html run_deploy --deploy-only
assert_eq "exit 1" 1 "$RC"
assert_eq "asset uploaded" "v4" "$(cat "$FAKE_BUCKET/extra.js")"
assert_eq "page not uploaded" "v3" "$(cat "$FAKE_BUCKET/about.html")"
assert_eq "no new tag" 3 "$(tag_count)"
reset_logs
run_deploy --deploy-only
assert_eq "retry exit 0" 0 "$RC"
assert_eq "retry invalidates just the page" "/about.html " "$(cf_paths)"
assert_eq "retry tags" 4 "$(tag_count)"

echo "== delete fails: kept in .deployed, retried"
reset_logs
rm output/other.png
FAIL_DELETE=other run_deploy --deploy-only
assert_eq "exit 1" 1 "$RC"
assert_eq "still in bucket" "yes" "$([[ -f "$FAKE_BUCKET/other.png" ]] && echo yes || echo no)"
assert_contains "still tracked in .deployed" "$(cat "$PROJ/.deployed")" "  other.png"
assert_eq "no new tag" 4 "$(tag_count)"
reset_logs
run_deploy --deploy-only
assert_eq "retry exit 0" 0 "$RC"
assert_eq "deleted on retry" "no" "$([[ -f "$FAKE_BUCKET/other.png" ]] && echo yes || echo no)"
assert_missing "no longer tracked" "$(cat "$PROJ/.deployed")" "  other.png"
assert_eq "retry tags" 5 "$(tag_count)"

echo "== many files: grouping, then threshold overrides and the 3000-path split"
reset_logs
ruby -e '3100.times { |i| d = "output/gen/g#{i % 31}"; Dir.mkdir("output/gen") rescue nil; Dir.mkdir(d) rescue nil; File.write("#{d}/p#{i}.html", "page #{i}") }'
run_deploy --deploy-only
assert_eq "exit 0" 0 "$RC"
assert_contains "progress at 50%" "$OUT" "1550/3100 (50%) uploaded"
assert_contains "progress reaches 100%" "$OUT" "3100/3100 (100%) uploaded"
assert_missing "no per-file lines when many files" "$OUT" "uploaded gen/g0/"
assert_eq "grouped into one request" 1 "$(cf_requests)"
assert_eq "31 directory wildcards" "31" "$(cf_paths | tr ' ' '\n' | grep -c '^/gen/g[0-9]*/\*$')"
assert_eq "tagged" 6 "$(tag_count)"
reset_logs
ruby -e '3100.times { |i| File.write("output/gen/g#{i % 31}/p#{i}.html", "page v2 #{i}") }'
printf 'cloudfront_group_threshold: 100000\ncloudfront_invalidate_all_threshold: 100000\n' >> nanoc.yaml
run_deploy --deploy-only
assert_eq "exit 0" 0 "$RC"
assert_eq "split at CloudFront's 3000-path limit" "2" "$(cf_requests)"
assert_eq "request sizes" "3000 100 " "$(cf_quantities)"

echo "== invalid config is rejected"
cp nanoc.yaml "$WORK/nanoc.yaml.bak"
printf 's3_bucket: "b"\ncloudfront_distribution_id: "E1"\naws_region: "eu-west-2"\ncloudfront_group_threshold: abc\n' > nanoc.yaml
run_deploy --deploy-only --dry-run
[[ "$RC" -ne 0 ]] && pass "non-zero exit" || fail "non-zero exit"
assert_contains "explains" "$OUT" "must be a whole number"
cp "$WORK/nanoc.yaml.bak" nanoc.yaml

echo "== --dry-run is production only"
run_deploy --deploy-only --staging --dry-run
assert_eq "exit 1" 1 "$RC"

echo "== staging path unchanged: full sync + /*, no tracking"
reset_logs
before_tags=$(tag_count); before_deployed=$(cat "$PROJ/.deployed")
run_deploy --deploy-only --staging
assert_eq "exit 0" 0 "$RC"
assert_eq "one s3 sync" 1 "$(aws_calls 's3 sync')"
assert_eq "invalidates /*" "/* " "$(cf_paths)"
assert_eq "no tag" "$before_tags" "$(tag_count)"
assert_eq ".deployed untouched" "$before_deployed" "$(cat "$PROJ/.deployed")"

echo
echo "${PASSES} passed, ${FAILS} failed"
[[ "$FAILS" -eq 0 ]]
