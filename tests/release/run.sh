#!/usr/bin/env bash
# Drives .github/scripts/release.sh (what release.yml runs) against the fake gh, in a scratch git
# repository. No network, no GitHub.
# Usage: run.sh [<release.sh>] [<release.yml>]   (defaults: this repository's copies)
set -u
unset REVIEW_BLOCK_AT PUSH_GUARD_ALLOW_SENSITIVE
T="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$T/../.." && pwd)"
SCRIPT="$(cd "$(dirname "${1:-$ROOT/.github/scripts/release.sh}")" && pwd)/$(basename "${1:-release.sh}")"
WF="${2:-$ROOT/.github/workflows/release.yml}"
W="$T/work-${TEST_TAG:-main}"; rm -rf "$W"; mkdir -p "$W"
export FAKE_DIR="$W/state" PATH="$ROOT/tests/fake-gh/bin:$PATH"
PASS=0; FAIL=0; ROWS=()
row() { if [ "$2" = ok ]; then PASS=$((PASS + 1)); ROWS+=("ok   | $1"); else FAIL=$((FAIL + 1)); ROWS+=("FAIL | $1 :: $(tail -c 400 "$W/out" | tr '\n' ' ')"); fi; }
check() { local name="$1"; shift; if "$@"; then row "$name" ok; else row "$name" bad; fi; }

# A repository at version 1.2.3 with a CHANGELOG entry; SHA is its head, OTHER an older commit.
R="$W/repo"; mkdir -p "$R"
(
  cd "$R" && git init -q && git config user.email t@t && git config user.name t
  echo base >f && git add -A && git commit -qm base
  printf '1.2.3\n' >VERSION
  for s in pr-reviewer pr-fixer; do
    mkdir -p ".agents/skills/$s"; printf -- '---\nname: %s\nmetadata:\n  version: 1.2.3\n---\n' "$s" >".agents/skills/$s/SKILL.md"
  done
  printf '# Changelog\n\n## 1.2.3\n\n- the notes of 1.2.3\n\n## 1.2.2\n\n- older\n' >CHANGELOG.md
  git add -A && git commit -qm release
) >/dev/null 2>&1
SHA="$(git -C "$R" rev-parse HEAD)"; OTHER="$(git -C "$R" rev-parse HEAD~1)"
ARC="pr-reviewer-fixer-1.2.3.tar.gz"

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
sums() { printf '%s  %s\n' "$(printf '%s' "$1" | sha256sum | cut -d' ' -f1)" "$ARC"; }
# rel <tag> <draft> <target> [<asset name>=<content> ...]: one release as JSON.
rel() {
  local tag="$1" draft="$2" target="$3" a out=""; shift 3
  for a in "$@"; do out="$out${out:+,}{\"name\":\"${a%%=*}\",\"b64\":\"$(b64 "${a#*=}")\"}"; done
  printf '{"tag_name":"%s","draft":%s,"target_commitish":"%s","title":"old title","notes":"old notes","assets":[%s]}' "$tag" "$draft" "$target" "$out"
}
reftag() { printf '{"ref":"refs/tags/%s","object":{"type":"%s","sha":"%s"}}' "$1" "$2" "$3"; }
# reset <releases json list> <refs json list> [flag files...]
reset() {
  rm -rf "$FAKE_DIR" "$W/tmp"; mkdir -p "$FAKE_DIR" "$W/tmp"; : >"$FAKE_DIR/calls.log"
  printf '%s' "$1" >"$FAKE_DIR/releases.json"; printf '%s' "$2" >"$FAKE_DIR/refs.json"
  local f; shift 2; for f in "$@"; do printf '%s' "${f#*=}" >"$FAKE_DIR/${f%%=*}"; done
}
run() { (cd "$R" && env GITHUB_SHA="${GSHA:-$SHA}" GITHUB_REPOSITORY=o/r RUNNER_TEMP="$W/tmp" GH_TOKEN=x bash "$SCRIPT") >"$W/out" 2>&1; r=$?; }
calls() { grep -c -- "$1" "$FAKE_DIR/calls.log"; }
relq() { jq -r --arg t "${2:-v1.2.3}" ".[] | select(.tag_name == \$t) | $1" "$FAKE_DIR/releases.json"; }
out_has() { grep -qF -- "$1" "$W/out"; }
remedy() { grep -qE 'then rerun|in a pull request' "$W/out"; }

# ---- states ------------------------------------------------------------------------------------
reset '[]' '[]'; run
check "no release -> created on GITHUB_SHA with both files, title and notes from CHANGELOG" \
  eval '[ $r = 0 ] && [ "$(relq .target_commitish)" = "$SHA" ] && [ "$(relq "[.assets[].name]|sort|join(\",\")")" = "SHA256SUMS,$ARC" ] && [ "$(relq .title)" = v1.2.3 ] && relq .notes | grep -q "the notes of 1.2.3" && ! relq .notes | grep -q older'
check "no release, no other release -> --latest (#19 N3)" eval '[ "$(relq .latest)" = --latest ]'

reset "[$(rel v1.2.3 false "$SHA" "$ARC=good" "SHA256SUMS=$(sums good)")]" "[$(reftag v1.2.3 commit "$SHA")]"; run
check "published, both files, checksum matches -> green, nothing written (#19 N17)" \
  eval '[ $r = 0 ] && out_has "already released from $SHA" && [ $(calls "release upload") = 0 ] && [ $(calls "release edit") = 0 ] && [ $(calls "release create") = 0 ]'

reset "[$(rel v1.2.3 false main "$ARC=good" "SHA256SUMS=$(sums good)")]" "[$(reftag v1.2.3 commit "$OTHER")]"; run
check "published from an older commit (a revert to a released VERSION) -> green, prints the tag's commit, not target_commitish (#19 N34)" \
  eval '[ $r = 0 ] && out_has "from $OTHER" && out_has "not checked" && ! out_has "from main" && [ $(calls "release upload") = 0 ]'

reset "[$(rel v1.2.3 false "$SHA" "SHA256SUMS=$(sums good)")]" "[$(reftag v1.2.3 commit "$SHA")]"; run
check "published with SHA256SUMS but no archive -> not complete, both files attached (#19 N17)" \
  eval '[ $r = 0 ] && [ $(calls "release upload") = 1 ] && [ "$(relq "[.assets[].name]|sort|join(\",\")")" = "SHA256SUMS,$ARC" ]'

reset "[$(rel v1.2.3 false "$SHA" "$ARC=tampered" "SHA256SUMS=$(sums good)")]" "[$(reftag v1.2.3 commit "$SHA")]"; run
check "published, the archive does not match SHA256SUMS -> not complete, both files attached again (#19 N17)" \
  eval '[ $r = 0 ] && out_has "does not match" && [ $(calls "release upload") = 1 ]'

reset "[$(rel v1.2.3 false "$SHA" "SHA256SUMS=$(sums good)")]" "[$(reftag v1.2.3 commit "$OTHER")]"; run
check "published, a file missing, tag on another commit -> refused, names the tag's commit and the remedy" \
  eval '[ $r = 1 ] && out_has "tag v1.2.3 is on $OTHER, not $SHA" && remedy && [ $(calls "release upload") = 0 ]'

reset "[$(rel v1.2.3 false "$SHA" "SHA256SUMS=$(sums good)")]" '[]'; run
check "published, no tag -> its own refusal, not the wrong-target one (#19 N31)" \
  eval '[ $r = 1 ] && out_has "is published but has no tag; delete the release, then rerun" && ! out_has targets'

reset "[$(rel v1.2.3 true "$SHA" "$ARC=partial")]" '[]'; run
check "draft of this commit -> both files attached, published with the CHANGELOG title and notes (#19 N5)" \
  eval '[ $r = 0 ] && [ "$(relq .draft)" = false ] && [ "$(relq .title)" = v1.2.3 ] && relq .notes | grep -q "the notes of 1.2.3" && [ $(calls "release upload") = 1 ]'
check "draft of this commit, no other release -> --latest on the edit (#19 N3)" eval '[ "$(relq .latest)" = --latest ]'

reset "[$(rel v1.2.3 true "$SHA" "$ARC=partial" "notes.txt=extra")]" '[]'; run
check "draft that carries another file -> refused, names it and the remedy (#19 N5)" \
  eval '[ $r = 1 ] && out_has "carries other files (notes.txt)" && remedy && [ "$(relq .draft)" = true ]'

reset "[$(rel v1.2.3 true "$OTHER")]" '[]'; run
check "draft of another commit -> refused with the draft message, not the tag one (#19 N31)" \
  eval '[ $r = 1 ] && out_has "draft v1.2.3 targets $OTHER, not $SHA; delete the draft, then rerun" && ! out_has "tag v1.2.3"'

# ---- latest (#19 N3) -----------------------------------------------------------------------------
reset "[$(rel v1.10.0 false "$OTHER" "$ARC=x"),$(rel v9.0.0 true "$OTHER")]" '[]'; run
check "a published v1.10.0 is higher than 1.2.3 (numeric, not text) -> created with --latest=false (#19 N3)" \
  eval '[ $r = 0 ] && [ "$(relq .latest)" = --latest=false ]'
reset "[$(rel v1.2.2 false "$OTHER" "$ARC=x"),$(rel v9.0.0 true "$OTHER"),$(rel nightly false "$OTHER")]" '[]'; run
check "only lower releases published (a higher draft and a non-semver tag do not count) -> --latest (#19 N3)" \
  eval '[ $r = 0 ] && [ "$(relq .latest)" = --latest ]'
reset "[$(rel v2.0.0 false "$OTHER" "$ARC=x"),$(rel v1.2.3 true "$SHA")]" '[]'; run
check "an old draft published after a newer release -> --latest=false on the edit (#19 N3)" \
  eval '[ $r = 0 ] && [ "$(relq .latest)" = --latest=false ]'

# ---- lookups fail closed (#19 N15, N35) ------------------------------------------------------------
reset '[]' '[]' rel-fail-list= rel-fail-view=; run
check "the release lookup fails with an HTTP error -> exit 1, nothing created (#19 N15)" \
  eval '[ $r = 1 ] && [ $(calls "release create") = 0 ]'
reset '[]' '[]' rel-fail-refs=; run
check "the tag lookup fails -> exit 1, nothing created" eval '[ $r = 1 ] && [ $(calls "release create") = 0 ]'
reset "[$(rel v0.1.0 false "$OTHER" "$ARC=x"),$(rel v0.2.0 false "$OTHER" "$ARC=x"),$(rel v1.2.3 false "$SHA" "$ARC=good" "SHA256SUMS=$(sums good)")]" \
  "[$(reftag v0.1.0 commit "$OTHER"),$(reftag v1.2.3.9 commit "$OTHER"),$(reftag v1.2.3 commit "$SHA")]" rel-page-size=1; run
check "one release and one ref per page -> every page read, the release found complete (#19 N35)" \
  eval '[ $r = 0 ] && out_has "already released from $SHA" && [ $(calls "release create") = 0 ]'
reset "[$(rel v1.2.3 true "$SHA"),$(rel v1.2.3 true "$SHA")]" '[]'; run
check "two releases named v1.2.3 (two drafts) -> refused, names the remedy (#19 N15)" \
  eval '[ $r = 1 ] && out_has "2 releases are named v1.2.3" && remedy'

# ---- tags ------------------------------------------------------------------------------------------
reset '[]' "[$(reftag v1.2.30 commit "$OTHER")]"; run
check "only v1.2.30 exists (matching-refs matches by prefix) -> no tag, created" eval '[ $r = 0 ] && [ "$(relq .target_commitish)" = "$SHA" ]'
reset '[]' "[$(reftag v1.2.3 commit "$OTHER")]"; run
check "tag on another commit, no release -> refused with the tag message (#19 N31)" \
  eval '[ $r = 1 ] && out_has "tag v1.2.3 is on $OTHER, not $SHA; delete or move the tag" && [ $(calls "release create") = 0 ]'
reset '[]' "[$(reftag v1.2.3 tag aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)]"
printf '{"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa":{"object":{"type":"commit","sha":"%s"}}}' "$SHA" >"$FAKE_DIR/tags.json"; run
check "an annotated tag on this commit is followed to it -> created" eval '[ $r = 0 ] && [ $(calls "release create") = 1 ]'
reset '[]' "[$(reftag v1.2.3 tree "$SHA")]"; run
check "a tag on a tree -> refused, names the remedy (#19 N29)" \
  eval '[ $r = 1 ] && out_has "not a commit; delete the tag, then rerun"'

# ---- inputs ----------------------------------------------------------------------------------------
cp "$R/VERSION" "$W/V.bak"; printf '1.2.3.4\n' >"$R/VERSION"; reset '[]' '[]'; run
check "VERSION 1.2.3.4 -> refused before any call" eval '[ $r = 1 ] && out_has "VERSION is not x.y.z" && remedy && [ ! -s "$FAKE_DIR/calls.log" ]'
cp "$W/V.bak" "$R/VERSION"; cp "$R/CHANGELOG.md" "$W/C.bak"; printf '# Changelog\n\n## 1.2.2\n' >"$R/CHANGELOG.md"; reset '[]' '[]'; run
check "no CHANGELOG entry -> refused before any call" eval '[ $r = 1 ] && out_has "no entry for 1.2.3" && remedy && [ ! -s "$FAKE_DIR/calls.log" ]'
cp "$W/C.bak" "$R/CHANGELOG.md"

# ---- the workflow ---------------------------------------------------------------------------------
check "release.yml: one concurrency group, a queued run waits (#19 N33)" \
  eval 'grep -qE "^  group: release$" "$WF" && grep -qE "^  cancel-in-progress: false$" "$WF"'
check "release.yml: the step is named for what it does (#19 N32)" grep -q "name: Create, complete or publish the release for VERSION" "$WF"
check "release.yml: runs .github/scripts/release.sh, the script these rows test (#19 N16)" grep -q "run: bash .github/scripts/release.sh" "$WF"
check "release.yml: every action is pinned to a full commit SHA" \
  eval '! grep -E "uses:" "$WF" | grep -vqE "uses: [^@]+@[0-9a-f]{40}( |$)"'
check "release.sh: no comment says a push that leaves VERSION unchanged runs it (#19 N30)" eval '! grep -q "leaves VERSION unchanged" "$SCRIPT"'

printf '%s\n' "${ROWS[@]}"
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
