# Proposal: Claude agent and skill templates in nanoc-shared-scripts

Status: proposal. Written in fontasso.com for the `nanoc-shared-scripts` (nss) repo.

## Goal

Ship the reusable Claude Code agents and the promotion skill from nss, so a new Nanoc site gets them from
`validate.sh` instead of writing its own. Each project keeps its own facts in `nanoc.yaml`. fontasso.com is
the first consumer and the source of the first versions.

Templates to ship:

| Template | Kind | Source in fontasso.com |
|---|---|---|
| `copy-reviewer` | agent | `.claude/agents/copy-reviewer.md` |
| `page-dates` | agent | `.claude/agents/page-dates.md` |
| `promote` | skill | `.claude/skills/promote/SKILL.md` |

Not included: `release-notes`. It depends on the iOS app repo and `fontasso-releases.yaml`, so it stays a
fontasso.com skill.

## What nss already does (use these patterns, do not invent new ones)

- `templates/` holds files that `validate.sh` copies into a project (`Gemfile`, `deploy.yml`,
  `screenshot-overrides.js`, `nanoc.yaml`, `Rules`).
- `deploy.yml` has an accepted-diff flow in `validate.sh` (around lines 232-260): copy if missing, "up to date"
  if identical, otherwise print the diff and ask `Overwrite with template? [y/N]`. Answering no records a hash
  of the diff in `.validated` (`deploy-yml-diff-ok: <sha256>`) so the question is not asked again until the diff
  changes.
- Optional `nanoc.yaml` keys are documented in the README and validated with a warning, not a crash (for example
  `screenshot_viewports`, `screenshot_threshold`). `validate.sh` appends a commented-out example when a key is
  absent.
- Every change adds a `CHANGELOG.md` entry (today's date); user-facing changes also update `README.md`, and
  behaviour described in `CLAUDE.md` internals is kept in sync.

## Design

### Layout and install flow

- Templates live in `templates/claude/agents/copy-reviewer.md`, `templates/claude/agents/page-dates.md` and
  `templates/claude/skills/promote/SKILL.md`.
- `validate.sh` copies them to the project's `.claude/agents/` and `.claude/skills/promote/`. The project commits
  them as ordinary files, so fresh clones, CI and cloud sessions all have them. Do not use symlinks: a symlink
  into the submodule breaks when the submodule is not initialised, and it is not certain Claude Code discovers
  symlinked agent files.
- Outcomes per file: missing becomes "copied from template"; identical becomes "up to date"; different runs the
  accepted-diff flow above, with one `.validated` key per file (for example `agent-page-dates-diff-ok: <sha256>`).
  In a non-interactive run (no TTY, `CI=true`) report a difference as a warning and never prompt.
- Each template starts with a version comment, for example `<!-- template: page-dates@1 -->`, so a diff shows
  which version a project is on.
- A newly installed agent or skill is only discovered by a new Claude session. Say so in the `validate.sh`
  output.

### What is generic and what is project config

| Template | Generic, in the template | Project-specific, in `nanoc.yaml` |
|---|---|---|
| `copy-reviewer` | Read-only. Checks typos, grammar, doubled words, wording consistency across files, tone, sentences over about 30 words. Output grouped by file with `path:line`, quoted text, issue and a suggested replacement. | Spelling variant, product name and tagline, canonical terms, which files to review |
| `page-dates` | Bump a date only when visible text on that page changed, quote the changed line as evidence, typo-only fixes do not bump, CSS/layouts/`Rules`/`nanoc.yaml`/scripts/the submodule pointer never count, never touch other dates, never commit. Reports a table. | Which page shows which date, where the date lives, which files count as that page's content |
| `promote` | The whole flow: preflight, content review, local merge, build checks in an isolated copy, release gates, show the plan, explicit yes, push, after-notes. Never force-push, never resolve conflicts, never create tags (CI does). Layout-check handling: exit 1 blocks, overflow on the current build blocks, narrow-width and dark changes are listed for review, sampled-page noise is ignored. | Branch names, extra check commands, release-gate greps, which agents to run, project notes |

Anything that does not fit a schema goes in an optional free-text notes file that the agent or skill reads:
`.claude/copy-review-notes.md` and `.claude/promote-notes.md`. For fontasso.com the release-note rules and the
privacy-page rule go in the first, and the releases-YAML gate, the "do not touch the iOS repo" rule and the
CloudFront reminder go in the second.

### Config schema (`nanoc.yaml`)

```yaml
agents:
  copy_review:
    locale: en-GB                      # en-GB or en-US
    product: Fontasso
    tagline: "Tame your Typography"
    terms: [Favourites, Premium]       # canonical wording checked for consistency
    sources: [content/pages/*.haml, content/pages/*.md, layouts/*.haml]
    notes: .claude/copy-review-notes.md   # optional free text
  dated_pages:
    - page: /help/
      date_in: content/data/fontasso-faqs.yaml     # key date_key, default last_updated
      content: [content/data/fontasso-faqs.yaml, content/pages/help.haml]
    - page: /privacy-policy/
      date_line: content/pages/privacy-policy.md   # inline "> **Last updated:**" line
      content: [content/pages/privacy-policy.md]
      changelog_table: true
  never_touch_dates: [content/data/fontasso-releases.yaml]   # dates the agent reports but never edits
  date_format: "%-d %B %Y"             # optional strftime format

promote:
  branches: { source: main, staging: staging, release: release }
  review_agents: [copy-reviewer, page-dates]
  checks:                              # run in the isolated copy; a non-zero exit blocks
    - ruby scripts/check-favourites-build.rb
  release_blockers: ["coming soon", "not yet released"]   # grep -rniE over content/ and layouts/
  hidden_page_flag: publish            # flag any page whose `publish: false` changes in a release
  notes: .claude/promote-notes.md      # optional free text
```

Behaviour when config is missing or wrong:
- The agents and the skill read these keys at run time with their `Read` tool. A missing required key means the
  agent stops and says exactly which key to add. It does not guess.
- `validate.sh` checks that every path under `dated_pages` and `copy_review.sources` exists and warns if not, and
  appends a commented-out example `agents:`/`promote:` block when the keys are absent (same as
  `screenshot_viewports`).

### `promote` details worth keeping exactly

These came from real runs and should be kept in the generic skill text:
- Run the build checks in an isolated copy of the merged result (`rsync` excluding `output`, `tmp`,
  `node_modules`, `crash.log`, keeping `.git`; then `git submodule update --init`). A running dev watcher writes
  development output into `output/` and breaks guards that scan it. Read the temp directory path first, then
  remove the literal path (a removal through `$(...)` is blocked by Claude Code's safety check).
- Run `./check-layouts.sh` without `--strict`, redirect to a log, run it in the background and wait for it.
  Read the log: exit 1 blocks; `⚠ horizontal overflow` under a `localhost:3000` capture is the current build and
  blocks, under `localhost:3001` it is the baseline and is informational; list `new`/`changed` captures by
  viewport and ignore sampled detail pages.
- `release` promotions skip the content review and the layout check; the compile and project checks still run.
- Every promotion ends with an explicit yes before the push, and approval of an earlier step is not approval
  to push.

## fontasso.com migration (after the nss change merges)

1. Bump the submodule pointer and run `validate.sh`.
2. Move the page table from `.claude/agents/page-dates.md` into `agents.dated_pages`, and the spelling, tagline
   and terms from `copy-reviewer.md` into `agents.copy_review`.
3. Move the release-note and privacy rules into `.claude/copy-review-notes.md`, and the releases-YAML gate,
   iOS-repo rule and CloudFront reminder into `.claude/promote-notes.md`.
4. Replace the three project files with the template copies.
5. Rerun `/promote staging` on a past range and both agents on a known commit, and compare the reports to
   today's.

## Risks and open questions

- Agent frontmatter cannot be parameterised, so the template `description` says "this site", not "Fontasso".
- Drift is deliberate: an improved template only reaches a project when it re-runs `validate.sh` and accepts the
  diff.
- A wrong path in the config fails quietly unless `validate.sh` checks it, so it must.
- The `promote` template assumes the staging/release branch model that `deploy.yml` already implies. Projects
  that do not use it should skip the skill (an opt-out flag, for example `promote: false`, is worth having).
- `.validated` is local and gitignored, so an accepted diff is asked again on another machine. That is how
  `deploy.yml` behaves today and is acceptable.

## Acceptance criteria

- `validate.sh` on an empty project installs the three templates and prints the new-session note.
- Re-running it prints "up to date" for each.
- A modified copy triggers the diff prompt, and answering no is remembered in `.validated` per file.
- In a non-interactive run a difference is a warning with no prompt.
- Both agents and the skill stop with a clear message when their config key is missing.
- `validate.sh` warns about a `dated_pages` or `sources` path that does not exist.
- `CHANGELOG.md` (today's date), `README.md` and `CLAUDE.md` are updated, and a test in `test/` covers the three
  install outcomes.

## Implementation notes (differences from this proposal)

Recorded when the proposal was implemented; the README section "Claude agents and the promote skill" is
the reference.

- **`never_touch` moved.** As drawn above (a mapping key after a list item at the same indent) it was not valid
  YAML. It is now `agents.never_touch_dates`, a sibling of `dated_pages`. Dates in it are reported, never edited
  (this also covers fontasso.com's `fontasso-features.yaml` / `font-pages.yaml` `last_updated` fields that no
  page renders).
- **Extra optional keys** needed to remove fontasso.com facts from the templates: `dated_pages[].date_key`
  (default `last_updated`) and `note` (free text, for example "only the `title` / `description` fields of
  `font-pages.yaml` entries count for `/other-sources/`"), and `agents.date_format` (default `%-d %B %Y`).
- **Version comment placement.** The `<!-- template: name@N -->` comment is the first line after the front
  matter, not the first line of the file: front matter has to open the file for Claude Code to read it.
- **`promote: false`** (the suggested opt-out) is implemented: `validate.sh` skips installing the skill.
- **Release promotions** still review commits that exist only on `staging` (and run the layout check in that
  case), as in the fontasso.com skill; otherwise they skip the content review and the layout check, and the
  compile and project `checks` always run.
- `validate.sh` also warns about `never_touch_dates` paths and malformed `dated_pages` entries.
