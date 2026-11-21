#!/usr/bin/env bash
#
# remote-review.sh: prepare a branch of another GitHub repository for review and correction, in a
# local worktree, without installing the skills into that repository.
#
#   bash remote-review.sh owner/repo feature-branch [--base main] [--test "npm test"] [--push] [--open-pr]
#
# What it does, in order:
#   1. Clones owner/repo into a cache (once) and fetches the branch and its base.
#   2. Creates a local worktree on a NEW branch, review/<branch>, that starts at the branch's head.
#      The target branch is never checked out, moved or pushed to.
#   3. Runs the mechanical checks the review uses, from THIS repository's copy of the skills:
#      secret screen and hidden-text scan over the branch's diff, and the path floor. Nothing is
#      written into the worktree.
#   4. Runs --test in the worktree, if given, and records its exit code.
#   5. Prints the worktree path and the review and fix steps the agent runs next (the skills are
#      read from this copy, not from the worktree).
#   6. With --push: pushes review/<branch> to origin (the target repository).
#      With --open-pr: opens a draft pull request from review/<branch> into <branch>, after --push.
#
# The reviewer and the fixer run as agents, following this repository's skills, with the worktree
# as the repository they work on. The fixes are committed on review/<branch>; the branch the author
# pushed is not changed. Nothing here merges, approves or releases.
#
# OPTIONS
#   --base BRANCH   the branch the pull request targets (default: the target repository's default)
#   --test CMD      command run in the worktree; its exit code is recorded in the summary
#   --url URL       clone from this URL instead of https://github.com/owner/repo.git (tests, mirrors)
#   --cache DIR     cache folder (default: ${PR_REVIEW_CACHE:-$HOME/.cache/pr-reviewer-fixer/remote})
#   --push          push review/<branch> to origin after the checks
#   --open-pr       with --push, open a draft pull request from review/<branch> into the base
#
# EXIT CODES. 0 = prepared (and pushed or opened, if asked). 1 = refused or a step failed.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REVIEW_CYCLE="$HERE/.agents/skills/pr-reviewer/scripts/review-cycle.sh"
SCAN="$HERE/.agents/skills/pr-reviewer/scripts/scan-hidden.py"
FLOOR="$HERE/.agents/skills/pr-reviewer/scripts/path-floor.sh"
die() { echo "remote-review: $*" >&2; exit 1; }

REPO="" BRANCH="" BASE="" TEST_CMD="" URL="" CACHE="${PR_REVIEW_CACHE:-$HOME/.cache/pr-reviewer-fixer/remote}" PUSH=0 OPEN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --base)    [ $# -ge 2 ] || die "--base needs a branch"; BASE="$2"; shift 2 ;;
    --test)    [ $# -ge 2 ] || die "--test needs a command"; TEST_CMD="$2"; shift 2 ;;
    --url)     [ $# -ge 2 ] || die "--url needs a URL"; URL="$2"; shift 2 ;;
    --cache)   [ $# -ge 2 ] || die "--cache needs a folder"; CACHE="$2"; shift 2 ;;
    --push)    PUSH=1; shift ;;
    --open-pr) OPEN=1; shift ;;
    -h|--help) sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)        die "unknown option '$1'" ;;
    *)         if [ -z "$REPO" ]; then REPO="$1"; elif [ -z "$BRANCH" ]; then BRANCH="$1"; else die "one repository and one branch"; fi; shift ;;
  esac
done
[ -n "$REPO" ] && [ -n "$BRANCH" ] || die "usage: remote-review.sh owner/repo branch [options]"
case "$REPO" in */*) ;; *) die "the repository must be owner/repo" ;; esac
[ "$OPEN" = 0 ] || [ "$PUSH" = 1 ] || die "--open-pr needs --push"
for tool in git; do command -v "$tool" >/dev/null 2>&1 || die "$tool is needed"; done
[ -f "$REVIEW_CYCLE" ] && [ -f "$SCAN" ] && [ -f "$FLOOR" ] || die "this checkout lacks the review scripts"
case "$BRANCH" in review/*) die "refusing a branch that is already a review branch: $BRANCH" ;; esac

OWNER="${REPO%%/*}"; NAME="${REPO#*/}"
[ -n "$URL" ] || URL="https://github.com/$OWNER/$NAME.git"
DIR="$CACHE/$OWNER/$NAME"
mkdir -p "$CACHE/$OWNER" || die "cannot create $CACHE"
if [ ! -d "$DIR/.git" ] && [ ! -e "$DIR/.git" ]; then
  git clone -q "$URL" "$DIR" 2>&1 || die "clone of $URL failed; nothing prepared"
fi
git -C "$DIR" fetch -q origin "$BRANCH" 2>/dev/null || git -C "$DIR" fetch -q origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH" || die "branch $BRANCH not found in $REPO"
if [ -z "$BASE" ]; then
  BASE="$(git -C "$DIR" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
  [ -n "$BASE" ] || BASE="main"
fi
git -C "$DIR" fetch -q origin "+refs/heads/$BASE:refs/remotes/origin/$BASE" 2>/dev/null || die "base branch $BASE not found in $REPO"

HEAD_SHA="$(git -C "$DIR" rev-parse "origin/$BRANCH")"
BASE_SHA="$(git -C "$DIR" rev-parse "origin/$BASE")"
SHORT="${HEAD_SHA:0:7}"
REVIEW_BRANCH="review/$BRANCH"
WT="$DIR/worktrees/$BRANCH"
if [ -e "$WT" ]; then
  git -C "$DIR" worktree remove --force "$WT" 2>/dev/null || rm -rf "$WT"
fi
git -C "$DIR" branch -D "$REVIEW_BRANCH" >/dev/null 2>&1 || true
mkdir -p "$(dirname "$WT")"
git -C "$DIR" worktree add -q -B "$REVIEW_BRANCH" "$WT" "$HEAD_SHA" || die "could not create the worktree at $WT"
echo "remote-review: worktree $WT on $REVIEW_BRANCH (from $BRANCH at $SHORT, base $BASE)"

# 3. Mechanical checks, from this repository's copy of the scripts. They read git only.
FILES="$(git -C "$DIR" diff --name-only "$BASE_SHA" "$HEAD_SHA" | wc -l | tr -d ' ')"
echo "remote-review: diff $BASE..$BRANCH touches $FILES file(s)"
SCREEN="ok"
if (cd "$WT" && "$REVIEW_CYCLE" screen --diff "$BASE_SHA" "$HEAD_SHA") >/dev/null 2>&1; then SCREEN="ok"; else SCREEN="HITS (run review-cycle.sh screen --diff by hand; values are never printed)"; fi
echo "remote-review: secret screen: $SCREEN"
HIDDEN="$(cd "$WT" && python3 "$SCAN" --diff "$BASE_SHA" "$HEAD_SHA" --commits "$BASE_SHA" "$HEAD_SHA" 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("hits",[])))' 2>/dev/null || echo "?")"
echo "remote-review: hidden-text hits in the diff and commit messages: $HIDDEN"
FLOOR_OUT="$(cd "$WT" && "$FLOOR" "$BASE_SHA" "$HEAD_SHA" 2>/dev/null | awk '{print $1}' | sort | uniq -c | tr -s ' ' | tr '\n' ';')"
echo "remote-review: path floor units: ${FLOOR_OUT:-none}"

# 4. The project's own tests, in the worktree.
TEST_RESULT="not run"
if [ -n "$TEST_CMD" ]; then
  (cd "$WT" && bash -c "$TEST_CMD") >"$WT/../$BRANCH.test.log" 2>&1; rc=$?
  TEST_RESULT="exit $rc (log: $WT/../$BRANCH.test.log)"
  echo "remote-review: tests: $TEST_RESULT"
fi

# 5. What the agents do next.
echo "remote-review: next, the review and fix run on $WT with this repository's skills:"
echo "  reviewer: read $HERE/.agents/skills/pr-reviewer/SKILL.md; target = the worktree's branch diff $BASE_SHA..$HEAD_SHA (no PR)"
echo "  fixer:    read $HERE/.agents/skills/pr-fixer/SKILL.md; commits go on $REVIEW_BRANCH in $WT"

# 6. Publish only the review branch, never the author's branch.
if [ "$PUSH" = 1 ]; then
  git -C "$WT" push -q -u origin "$REVIEW_BRANCH" 2>&1 || die "push of $REVIEW_BRANCH failed"
  echo "remote-review: pushed $REVIEW_BRANCH to $REPO"
fi
if [ "$OPEN" = 1 ]; then
  command -v gh >/dev/null 2>&1 || die "gh is needed to open the pull request"
  URL_PR="$(cd "$WT" && gh pr create --repo "$REPO" --draft --base "$BASE" --head "$REVIEW_BRANCH" \
    --title "Review fixes for $BRANCH" \
    --body "Fixes from a review of \`$BRANCH\` at \`$SHORT\`, prepared with pr-reviewer and pr-fixer.

- Secret screen: $SCREEN
- Hidden-text hits: $HIDDEN
- Tests: $TEST_RESULT

Nothing merges from this pull request without a person.")" || die "could not open the pull request"
  echo "remote-review: draft pull request: $URL_PR"
fi
echo "remote-review: done. Worktree: $WT"
