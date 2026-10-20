#!/usr/bin/env bash
# guard-builder-Opus5.5-agent
# Guard 4 daily sweep (AC-13 to AC-19). Writes a plain-words report to
# stdout, worst item first. Needs GH_TOKEN and GH_REPO. Optional:
# SINCE (ISO time, default 24 hours ago). Needs REVIEWER_APP_ID.
set -euo pipefail
repo="$GH_REPO"
since="${SINCE:-}"; [ -n "$since" ] || since="$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-24H +%Y-%m-%dT%H:%M:%SZ)"
app="${REVIEWER_APP_ID:?Set the REVIEWER_APP_ID repository variable}"
guard_paths='^(\.github/|docs-public/|plans/|CODEOWNERS)'
# kit-keeper-Opus5.5-agent, 2026-10-13 (KIT-002 OQ-4): a bypass merge that
# changed only these paths is a plan approval (feature, slice-plan, re-plan
# or closing retro PR), listed on its own line with its files
plan_paths='^(plans/|specs/|acceptance/|docs-public/retro-log\.md$|docs-public/guard-data/locks/)'
out="$(mktemp)"
section() { printf '\n### %s\n\n' "$1" >> "$out"; }
found=0

# 1. Guard settings changed (AC-18): live rules on main vs the recorded copy
live="$(gh api "repos/$repo/rules/branches/main" --jq '[.[] | {type, parameters}] | sort_by(.type)')"
if [ ! -f docs-public/guard-data/expected-protection.json ]; then
  found=1; section "⚠️ The protection on main is not recorded yet"
  echo "\`docs-public/guard-data/expected-protection.json\` is missing, so changes to the rules on main can't be spotted. Finish the setup checklist (step 11)." >> "$out"
elif ! diff <(printf '%s' "$live" | jq -S .) <(jq -S . docs-public/guard-data/expected-protection.json) > /dev/null; then
  found=1; section "⚠️ The protection on main has changed"
  echo "The rules GitHub applies to \`main\` no longer match the saved copy. Someone switched a guard off or changed it:" >> "$out"
  echo >> "$out"
  plain() { case "$1" in
    deletion) echo "Block deleting main" ;;
    non_fast_forward) echo "Block force pushes" ;;
    pull_request) echo "Require a pull request (with approval and code-owner review)" ;;
    required_status_checks) echo "Require the signed checks (slice-review, test-lock)" ;;
    *) echo "$1" ;;
  esac; }
  saved="$(jq -S . docs-public/guard-data/expected-protection.json)"; now="$(printf '%s' "$live" | jq -S .)"
  for t in $(printf '%s\n%s' "$saved" "$now" | jq -rs 'map(.[].type) | unique | .[]'); do
    was="$(printf '%s' "$saved" | jq -c --arg t "$t" '.[] | select(.type == $t)')"
    is="$(printf '%s' "$now" | jq -c --arg t "$t" '.[] | select(.type == $t)')"
    if [ -n "$was" ] && [ -z "$is" ]; then echo "- **Switched off:** $(plain "$t")" >> "$out"
    elif [ -z "$was" ] && [ -n "$is" ]; then echo "- **Added:** $(plain "$t")" >> "$out"
    elif [ "$was" != "$is" ]; then echo "- **Changed:** $(plain "$t")" >> "$out"; fi
  done
  { echo; echo "<details><summary>Technical detail</summary>"; echo; echo '```diff'
    diff <(printf '%s' "$saved") <(printf '%s' "$now") | head -60 || true
    echo '```'; echo "</details>"; } >> "$out"
fi

# guard-builder-Opus5.5-agent, 2026-10-20: the reviewer's secrets are safe
# only while the `reviewer` environment is limited to main. Widening it is a
# setting change no file shows, so check it here (AC-18).
if ! envcheck="$(bash .github/scripts/verify-install.sh environment 2>&1)"; then
  found=1; section "⚠️ The reviewer's environment has changed"
  echo "The \`reviewer\` environment holds the reviewer app's key and the Claude token. Only \`main\` may use it:" >> "$out"
  echo >> "$out"; printf '%s\n' "$envcheck" | grep '^PROBLEM' | sed 's/^PROBLEM  /- /' >> "$out"
fi

# kit-keeper-Opus5.5-agent, 2026-09-28: the kit is private. Any kit file
# (docs/, CLAUDE*.md) tracked on main is public, and stays in history.
leaked="$(git ls-files -- docs ':(glob)**/CLAUDE*.md' | head -20)"
if [ -n "$leaked" ]; then
  found=1; section "⚠️ Private kit files are public on main"
  echo "These files belong to the private kit but are saved in this public repository. Deleting them is not enough: they stay in the history. Ask the agent for a history clean-up plan." >> "$out"
  echo >> "$out"; printf '%s\n' "$leaked" | sed 's/^/- `/; s/$/`/' >> "$out"
fi

# 2. Anything merged without a PASS (AC-14), and guard files changed (AC-18)
nopass=""; approvals=""; guardchg=""
for pr in $(gh api "repos/$repo/pulls?state=closed&sort=updated&direction=desc&per_page=50" \
    --jq ".[] | select(.merged_at != null and .merged_at >= \"$since\") | .number"); do
  sha="$(gh api "repos/$repo/pulls/$pr" --jq .head.sha)"
  title="$(gh api "repos/$repo/pulls/$pr" --jq .title)"
  # kit-keeper-Opus5.5-agent, 2026-10-15 (Proof 10, #61): a PASS counts only
  # if it finished before the merge; a PASS posted after it is a bypass.
  merged="$(gh api "repos/$repo/pulls/$pr" --jq .merged_at)"
  missing=""
  for chk in slice-review test-lock; do
    ok="$(gh api "repos/$repo/commits/$sha/check-runs?check_name=$chk" \
      --jq "[.check_runs[] | select(.app.id == $app and .conclusion == \"success\" and .completed_at <= \"$merged\")] | length")"
    [ "$ok" -gt 0 ] || missing="$missing $chk"
  done
  all="$(gh api "repos/$repo/pulls/$pr/files?per_page=100" --paginate --jq '.[].filename')"
  if [ -n "$missing" ] && [ -n "$all" ] && ! printf '%s\n' "$all" | grep -qvE "$plan_paths"; then
    approvals="$approvals- #$pr $title: $(printf '%s' "$all" | tr '\n' ' ')"$'\n'
    continue
  fi
  [ -z "$missing" ] || nopass="$nopass- #$pr $title (no PASS from:$missing)"$'\n'
  files="$(printf '%s\n' "$all" | grep -E "$guard_paths" || true)"
  [ -z "$files" ] || guardchg="$guardchg- #$pr $title: $(printf '%s' "$files" | tr '\n' ' ')"$'\n'
done
# Commits that reached main without a PR at all
direct=""
for sha in $(gh api "repos/$repo/commits?sha=main&since=$since&per_page=100" --jq '.[].sha'); do
  n="$(gh api "repos/$repo/commits/$sha/pulls" --jq '[.[] | select(.merged_at != null)] | length')"
  [ "$n" -gt 0 ] || direct="$direct- \`${sha:0:7}\` $(gh api "repos/$repo/commits/$sha" --jq '.commit.message | split("\n")[0]')"$'\n'
done
if [ -n "$direct" ]; then found=1; section "⚠️ Changes that reached main without a pull request"; printf '%s' "$direct" >> "$out"; fi
if [ -n "$nopass" ]; then found=1; section "Merged without a PASS"; echo "These were merged although the reviewer or the test lock did not pass. Usually an owner bypass (guard, setup, proof or re-plan PRs). Check each one was meant." >> "$out"; echo >> "$out"; printf '%s' "$nopass" >> "$out"; fi
if [ -n "$guardchg" ]; then found=1; section "Guard files changed"; printf '%s' "$guardchg" >> "$out"; fi
if [ -n "$approvals" ]; then found=1; section "Plans you approved (bypass merges that changed only plan files)"; echo "Expected: each feature, slice plan, re-plan and closing retro is approved this way. Check each is one you meant." >> "$out"; echo >> "$out"; printf '%s' "$approvals" >> "$out"; fi

# Open guard-breach issues from the tripwire
breach="$(gh api "repos/$repo/issues?labels=guard-breach&state=open&per_page=50" --jq '.[] | "- #\(.number) \(.title)"')"
if [ -n "$breach" ]; then found=1; section "Open guard-breach alerts"; printf '%s\n' "$breach" >> "$out"; fi

# Open PRs older than three days (KIT-002 flow rule 5: keep the pile small)
cutoff="$(date -u -d '3 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-3d +%Y-%m-%dT%H:%M:%SZ)"
stale="$(gh api "repos/$repo/pulls?state=open&sort=created&direction=asc&per_page=100" \
  --jq ".[] | select(.created_at < \"$cutoff\") | \"- #\\(.number) \\(.title) (open since \\(.created_at[:10]))\"")"
if [ -n "$stale" ]; then found=1; section "Pull requests open more than three days (oldest first)"; printf '%s\n' "$stale" >> "$out"; fi

# 3. Questions waiting on the owner, oldest first (AC-15)
waiting="$(gh api "repos/$repo/issues?labels=waiting-on-owner&state=open&sort=created&direction=asc&per_page=50" \
  --jq '.[] | "- #\(.number) \(.title) (waiting since \(.created_at[:10]))"')"
if [ -n "$waiting" ]; then found=1; section "Questions waiting on you (oldest first)"; printf '%s\n' "$waiting" >> "$out"; fi

# 4. Off-switches (flags) whose removal isn't confirmed (AC-16)
flags=""
for plan in plans/*.md; do
  [ -f "$plan" ] || continue
  while IFS= read -r line; do
    val="$(printf '%s' "$line" | sed -E 's/.*\*\*Flags:\*\*[[:space:]]*//')"
    case "$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')" in none|none.|"none "*|"none,"*|"none("*|"") ;; *) flags="$flags- $plan: $val"$'\n' ;; esac
  done < <(grep -E '\*\*Flags:\*\*' "$plan" || true)
done
if [ -n "$flags" ]; then found=1; section "Off-switches still in plans"; echo "Each needs its removal slice merged." >> "$out"; echo >> "$out"; printf '%s' "$flags" >> "$out"; fi

# 5. Costly machines (AC-17): not set up yet
machines_note="Costly machine check: not set up yet (deferred; see Known limits in the kit README)."

if [ "$found" -eq 0 ]; then
  echo "Nothing to report since $since. $machines_note"
else
  echo "Daily sweep since $since, worst first."
  cat "$out"
  printf '\n---\n%s\n' "$machines_note"
fi
