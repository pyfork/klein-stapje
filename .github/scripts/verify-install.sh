#!/usr/bin/env bash
# guard-builder-Opus5.5-agent, 2026-10-20
# Install check: reads the GitHub settings the guards depend on and prints
# one line per setting, OK or PROBLEM. Exits 1 on any PROBLEM.
#
# Usage: verify-install.sh [section ...]   (default: every section)
#   files codeowners rules bypass environment variables secrets
# Needs GH_REPO (owner/name) and a gh login. Run it as the agent login at
# install (checklist step 12): a collaborator can read every section. The
# daily sweep runs only the sections its own token can read
# (rules, environment).
#
# What it can't see: the ruleset's bypass list itself (GitHub returns it
# only to a token that can change the ruleset). "bypass" checks the next
# best thing: the login running this script can never bypass.
set -uo pipefail
repo="${GH_REPO:?Set GH_REPO to owner/name}"
sections="${*:-files codeowners rules bypass environment variables secrets}"
problems=0
ok()  { echo "OK       $1"; }
bad() { echo "PROBLEM  $1"; problems=$((problems + 1)); }
api() { gh api "repos/$repo/$1" 2>/dev/null; }
repo_var() { api "actions/variables/$1" | jq -r '.value // empty'; }

for s in $sections; do case "$s" in
files)
  for f in .github/workflows/slice-review.yml .github/workflows/test-lock.yml \
           .github/workflows/daily-sweep.yml .github/workflows/main-tripwire.yml \
           .github/scripts/test-lock.sh .github/scripts/daily-sweep.sh \
           docs-public/guard-data/expected-protection.json; do
    if api "contents/$f?ref=main" > /dev/null; then ok "on main: $f"; else bad "missing on main: $f"; fi
  done ;;

codeowners)
  owner="$(repo_var GUARD_OWNER_LOGIN)"
  body="$(api "contents/.github/CODEOWNERS?ref=main" | jq -r '.content // empty' | base64 --decode 2>/dev/null || true)"
  if [ -z "$body" ]; then bad "no .github/CODEOWNERS on main"
  elif [ -n "$owner" ] && printf '%s\n' "$body" | grep -qE "^\*[[:space:]]+@$owner([[:space:]]|$)"; then ok "CODEOWNERS: * @$owner"
  else bad "CODEOWNERS has no '* @${owner:-<GUARD_OWNER_LOGIN>}' line"; fi ;;

rules)
  app="$(repo_var REVIEWER_APP_ID)"; [ -n "$app" ] || app="${REVIEWER_APP_ID:-}"
  rules="$(api rules/branches/main)"
  if [ -z "$rules" ]; then bad "can't read the rules on main"; continue; fi
  for t in deletion non_fast_forward; do
    printf '%s' "$rules" | jq -e --arg t "$t" 'any(.[]; .type == $t)' > /dev/null && ok "rule on main: $t" || bad "rule missing on main: $t"
  done
  printf '%s' "$rules" | jq -e 'any(.[]; .type == "pull_request" and .parameters.require_code_owner_review and .parameters.required_approving_review_count >= 1)' > /dev/null \
    && ok "rule on main: pull request, 1 approval, code-owner review" || bad "rule on main: pull request with 1 approval and code-owner review is missing"
  printf '%s' "$rules" | jq -e 'any(.[]; .type == "required_status_checks" and .parameters.strict_required_status_checks_policy)' > /dev/null \
    && ok "rule on main: branches up to date" || bad "rule on main: 'require branches to be up to date' is off"
  for c in slice-review test-lock; do
    printf '%s' "$rules" | jq -e --arg c "$c" --argjson a "${app:-0}" \
      'any(.[]; .type == "required_status_checks" and any(.parameters.required_status_checks[]; .context == $c and .integration_id == $a))' > /dev/null \
      && ok "required check: $c from app ${app:-?}" || bad "required check $c from the reviewer app (${app:-REVIEWER_APP_ID unset}) is missing"
  done ;;

bypass)
  me="$(gh api user --jq .login 2>/dev/null || echo '?')"
  can="$(api rulesets | jq -r '.[].id' | while read -r id; do api "rulesets/$id" | jq -r '.current_user_can_bypass // "unknown"'; done | sort -u | tr '\n' ' ')"
  case "$can" in
    "never ") ok "bypass: $me can never bypass the rules on main" ;;
    "") bad "bypass: no ruleset found" ;;
    *) bad "bypass: $me can bypass ($can). Only the owner may; remove this login from the bypass list" ;;
  esac ;;

environment)
  env="$(api environments/reviewer)"
  if [ -z "$env" ]; then bad "no 'reviewer' environment"; continue; fi
  printf '%s' "$env" | jq -e '.deployment_branch_policy.custom_branch_policies == true and .deployment_branch_policy.protected_branches == false' > /dev/null \
    || { bad "environment 'reviewer' is open to every branch: limit it to 'Selected branches' with main only"; continue; }
  pol="$(api "environments/reviewer/deployment-branch-policies" | jq -c '[.branch_policies[] | {name, type}]')"
  [ "$pol" = '[{"name":"main","type":"branch"}]' ] && ok "environment 'reviewer': main only" \
    || bad "environment 'reviewer' branch rules are $pol, not main only" ;;

variables)
  for v in GUARD_OWNER_LOGIN GUARD_AGENT_LOGIN REVIEWER_APP_ID GUARD_KIT_OWNER GUARD_KIT_REPO GUARD_TEST_COMMAND; do
    [ -n "$(repo_var "$v")" ] && ok "repository variable: $v" || bad "repository variable $v is missing (a 'reviewer' environment variable doesn't count: two jobs run outside the environment)"
  done
  envvars="$(api "environments/reviewer/variables" | jq -r '.variables[].name')"
  printf '%s\n' "$envvars" | grep -qx REVIEWER_APP_CLIENT_ID && ok "environment variable: REVIEWER_APP_CLIENT_ID" \
    || bad "environment variable REVIEWER_APP_CLIENT_ID is missing from 'reviewer'" ;;

secrets)
  names="$(api "environments/reviewer/secrets" | jq -r '.secrets[].name')"
  for v in REVIEWER_APP_PRIVATE_KEY CLAUDE_CODE_OAUTH_TOKEN; do
    printf '%s\n' "$names" | grep -qx "$v" && ok "environment secret: $v" || bad "environment secret $v is missing from 'reviewer'"
  done
  printf '%s\n' "$names" | grep -qx REVIEWER_APP_CLIENT_ID \
    && bad "REVIEWER_APP_CLIENT_ID is saved as a secret: workflows read it as a variable, so it comes through empty" \
    || ok "REVIEWER_APP_CLIENT_ID is not a secret" ;;

*) bad "unknown section: $s" ;;
esac; done

[ "$problems" -eq 0 ] && echo "All guard settings OK." || echo "$problems problem(s)."
[ "$problems" -eq 0 ]
