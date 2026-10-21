#!/usr/bin/env bash
# Drives check-version.sh against release answers served from local files. No network needed.
# Usage: run.sh <skill scripts dir>
set -u
# A caller's REVIEW_BLOCK_AT or PUSH_GUARD_ALLOW_SENSITIVE would change what is refused; a row that
# needs one sets it itself.
unset REVIEW_BLOCK_AT PUSH_GUARD_ALLOW_SENSITIVE
T="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:?scripts dir}"
S="$SRC/check-version.sh"
# A directory per run so two runs can go at the same time (TEST_TAG names it).
W="$T/state-${TEST_TAG:-main}"; rm -rf "$W"; mkdir -p "$W"
PASS=0; FAIL=0
check() { local name="$1"; shift; if "$@"; then PASS=$((PASS+1)); echo "PASS | $name"; else FAIL=$((FAIL+1)); echo "FAIL | $name"; fi; }

INSTALLED="$("$S" --installed)"
rel() { printf '{"tag_name":"%s","html_url":"https://example.test/releases/%s"}' "$1" "$1" >"$W/release.json"; }
run() { # env assignments are passed through "$@"
  env -i PATH="$PATH" HOME="$W/home" PR_SKILLS_CACHE_DIR="$W/cache" PR_SKILLS_RELEASE_URL="file://$W/release.json" "$@" bash "$S"; }
fresh() { rm -rf "$W/cache"; }

check "installed version is read from SKILL.md" eval '[ -n "$INSTALLED" ] && printf %s "$INSTALLED" | grep -Eq "^[0-9]+\.[0-9]+\.[0-9]+$"'

rel "v$INSTALLED"; fresh
out="$(run)"; rc=$?
check "same version: silent, exit 0" eval '[ $rc = 0 ] && [ -z "$out" ]'

rel "v99.0.0"; fresh
out="$(run)"; rc=$?
check "newer release: one notice naming both versions, exit 0" eval '[ $rc = 0 ] && printf %s "$out" | grep -q "99.0.0 is available" && printf %s "$out" | grep -q "installed is $INSTALLED"'
check "notice links the release page" eval 'printf %s "$out" | grep -q "https://example.test/releases/v99.0.0"'
check "notice says a person decides and does not install" eval 'printf %s "$out" | grep -q "a person decides"'

rel "v0.0.1"; fresh
out="$(run)"
check "older release: silent" eval '[ -z "$out" ]'

rel "v99.0.0"; fresh
out="$(run PR_SKILLS_NO_UPDATE_CHECK=1)"
check "opt-out variable: silent, no cache written" eval '[ -z "$out" ] && [ ! -e "$W/cache/latest" ]'
out="$(run CI=true)"
check "CI=true: silent" eval '[ -z "$out" ]'
out="$(run GITHUB_ACTIONS=true)"
check "GITHUB_ACTIONS=true: silent" eval '[ -z "$out" ]'

fresh; run >/dev/null
rm -f "$W/release.json"
out="$(run)"; rc=$?
check "answer is cached for 24 h: notice survives an unreachable release URL" eval '[ $rc = 0 ] && printf %s "$out" | grep -q "99.0.0 is available"'

fresh
out="$(run)"; rc=$?
check "unreachable release URL, no cache: silent, exit 0" eval '[ $rc = 0 ] && [ -z "$out" ]'

printf 'not json' >"$W/release.json"; fresh
out="$(run)"; rc=$?
check "malformed answer: silent, exit 0" eval '[ $rc = 0 ] && [ -z "$out" ]'

printf '{"tag_name":"nightly","html_url":"x"}' >"$W/release.json"; fresh
out="$(run)"; rc=$?
check "non-semver tag: silent, exit 0" eval '[ $rc = 0 ] && [ -z "$out" ]'

out="$(env -i PATH="$PATH" PR_SKILLS_RELEASE_URL="file://$W/release.json" bash "$S" 2>&1)"; rc=$?
check "no HOME and no XDG_CACHE_HOME: silent, exit 0, no stderr" eval '[ $rc = 0 ] && [ -z "$out" ]'
rel "v99.0.0"
out="$(env -i PATH="$PATH" PR_SKILLS_RELEASE_URL="file://$W/release.json" bash "$S" 2>&1)"; rc=$?
check "no HOME: notice still printed, exit 0" eval '[ $rc = 0 ] && printf %s "$out" | grep -q "99.0.0 is available"'

echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
