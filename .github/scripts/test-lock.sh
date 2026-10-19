#!/usr/bin/env bash
# guard-builder-Opus5.5-agent
# Guard 3 test lock (AC-9, AC-10). Usage: test-lock.sh <main-dir> <pr-dir>
# Plans and lock files are read from main; check files from the PR. Prints
# one line per problem and exits 1 if there are any.
set -u
main="$1"; pr="$2"; problems=0
say() { echo "$1"; problems=$((problems + 1)); }
sum() { if command -v sha256sum >/dev/null; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }

for plan in "$main"/plans/*.md; do
  [ -f "$plan" ] || continue
  name="$(basename "$plan" .md)"
  locked="$(grep -oE '^[[:space:]]*LOCKED: [^[:space:]]+' "$plan" | awk '{print $2}' | sort -u)"
  [ -n "$locked" ] || continue
  lock="$main/docs-public/guard-data/locks/$name.lock"
  if [ ! -f "$lock" ]; then say "NO LOCK FILE: plans/$name.md has locked checks but docs-public/guard-data/locks/$name.lock is missing on main"; continue; fi
  for c in $locked; do
    grep -qE "[[:space:]]$c\$" "$lock" || say "NOT IN LOCK: $c is locked in plans/$name.md but has no fingerprint"
  done
  while read -r want path; do
    [ -n "${want:-}" ] || continue
    printf '%s\n' "$locked" | grep -qxF "$path" || { say "UNKNOWN CHECK: docs-public/guard-data/locks/$name.lock names $path, which plans/$name.md does not lock"; continue; }
    if [ ! -f "$pr/$path" ]; then say "DELETED: $path (locked by plans/$name.md)"; continue; fi
    got="$(sum "$pr/$path")"
    [ "$got" = "$want" ] || say "CHANGED: $path (locked by plans/$name.md; fingerprint ${want:0:12}… is now ${got:0:12}…)"
  done < "$lock"
done

# A build PR may not touch plans or locks. Changing them is a re-plan: a plan
# PR the owner approves and merges with the admin bypass (AC-11, AC-12).
if [ -d "$pr/.git" ]; then
  changed="$(git -C "$pr" diff --name-only origin/main...HEAD -- plans docs-public/guard-data/locks 2>/dev/null || true)"
  for f in $changed; do say "PLAN CHANGE: $f. Re-plans need the owner's approval and merge with the admin bypass"; done
fi

[ "$problems" -eq 0 ] && echo "All locked checks match their fingerprints on main."
[ "$problems" -eq 0 ]
