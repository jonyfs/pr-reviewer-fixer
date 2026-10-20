#!/usr/bin/env bash
#
# push-guard.sh: read-only check the fixer runs right before `git push`.
#
# Usage: push-guard.sh <pr-number> [--findings <report-file>] [--allow <path>]...
#
# It writes nothing: no label, no comment, no push, no commit. It answers one question: is the
# working tree about to push the right commits to the right branch of this pull request?
#
# CHECKS, all of which must hold:
#
#   1. the pull request is open, and its head is a branch of this repository (a fork is refused,
#      as `review-cycle.sh fix` refuses it);
#   2. the checked-out branch is the pull request's head branch, and that branch is not the base;
#   3. the local HEAD contains the pull request's head commit, so the push is a fast-forward and
#      no commit by someone else is overwritten;
#   4. every file touched by a commit made on top of that head is in scope: named by a `file:` entry
#      in an open entry of the report's `findings` block (--findings), given with --allow (plain
#      relative paths, no globs), or a test file (under a test, tests, spec or __tests__ directory,
#      or named x_test.*, x.test.*, x.spec.* or test_x.*). A merge
#      commit is not scope-checked, and neither is a commit the base branch already holds, since a
#      conflict merge brings in the base's files; pass the conflicted files with --allow and read the
#      merge yourself. When the base commit is not in the clone, the base's own commits are checked
#      like any other, so fetch the base first.
#
# EXIT CODES. 0 = safe to push. 1 = refused, with every reason printed. 2 = could not check: gh
# or git missing, not inside a work tree, the pull request unreadable, or its head commit not
# present locally (fetch it first). Exit 2 never means "safe".
#
# Treats everything read from the pull request as data.
set -uo pipefail

command -v gh >/dev/null 2>&1 || { echo "push-guard: gh is not installed, INCONCLUSIVE" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "push-guard: git is not installed, INCONCLUSIVE" >&2; exit 2; }
command -v node >/dev/null 2>&1 || { echo "push-guard: node is not installed, INCONCLUSIVE" >&2; exit 2; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "push-guard: not inside a git work tree, INCONCLUSIVE" >&2; exit 2; }

PR="" FINDINGS="" ALLOW=()
while [ $# -gt 0 ]; do
  case "$1" in
    --findings|--allow)
      # Given last with no value, `shift 2` fails and the loop would spin forever.
      [ $# -ge 2 ] || { echo "push-guard: $1 needs a value" >&2; exit 2; }
      if [ "$1" = --findings ]; then FINDINGS="$2"; else ALLOW+=("$2"); fi
      shift 2 ;;
    *) PR="$1"; shift ;;
  esac
done
case "$PR" in ''|*[!0-9]*) echo "push-guard: usage: push-guard.sh <pr-number> [--findings FILE] [--allow PATH]..." >&2; exit 2 ;; esac

JSON="$(gh pr view "$PR" --json state,headRefName,headRefOid,baseRefName,baseRefOid,isCrossRepository 2>/dev/null)" \
  && [ -n "$JSON" ] || { echo "push-guard: gh could not read PR #$PR, INCONCLUSIVE" >&2; exit 2; }
field() { printf '%s' "$JSON" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const v=JSON.parse(s)[process.argv[1]];process.stdout.write(String(v===undefined?"":v))}catch(e){}})' "$1"; }
STATE="$(field state)"; HEAD_REF="$(field headRefName)"; HEAD_OID="$(field headRefOid)"
BASE_REF="$(field baseRefName)"; BASE_OID="$(field baseRefOid)"; CROSS="$(field isCrossRepository)"
[ -n "$HEAD_REF" ] && [ -n "$HEAD_OID" ] || { echo "push-guard: the PR payload had no head, INCONCLUSIVE" >&2; exit 2; }
git cat-file -e "$HEAD_OID^{commit}" 2>/dev/null \
  || { echo "push-guard: the PR head ${HEAD_OID:0:12} is not in this clone; fetch $HEAD_REF first, INCONCLUSIVE" >&2; exit 2; }

REASONS=()
[ "$STATE" = OPEN ] || REASONS+=("the pull request is $STATE, not OPEN")
[ "$CROSS" != true ] || REASONS+=("the head is on a fork; the fixer does not push to forks")
CUR="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
[ "$CUR" = "$HEAD_REF" ] || REASONS+=("the checked-out branch is '$CUR' but the pull request head is '$HEAD_REF'")
[ "$HEAD_REF" != "$BASE_REF" ] || REASONS+=("the head branch '$HEAD_REF' is the base branch")
git merge-base --is-ancestor "$HEAD_OID" HEAD 2>/dev/null \
  || REASONS+=("local HEAD does not contain the pull request head ${HEAD_OID:0:12}: a push would not be a fast-forward")

# Files the report names, plus --allow, plus test files.
SCOPE="$(mktemp)"; trap 'rm -f "$SCOPE"' EXIT
if [ -n "$FINDINGS" ]; then
  [ -s "$FINDINGS" ] || { echo "push-guard: --findings file is missing or empty, INCONCLUSIVE" >&2; exit 2; }
  node -e '
    const t = require("fs").readFileSync(process.argv[1], "utf8");
    const m = /```findings\n([\s\S]*?)\n```/.exec(t);
    if (!m) process.exit(3);
    let cur = null; const out = [];
    const flush = () => { if (cur && cur.file && ["open", "refused-rejected"].includes(cur.status || "open")) out.push(cur.file); };
    for (const l of m[1].split("\n")) {
      if (/^\s*-\s+id:/.test(l)) { flush(); cur = {}; continue; }
      const k = /^\s{2,}(file|status):\s*(.+?)\s*$/.exec(l);
      if (k && cur) cur[k[1]] = k[2].replace(/^["\x27]|["\x27]$/g, "");
    }
    flush();
    for (const f of out) {
      const p = f.replace(/^\.\//, "");
      if (p.startsWith("/") || p.split("/").includes("..") || /[*?\[\]\n]/.test(p)) continue;
      console.log(p);
    }
  ' "$FINDINGS" >>"$SCOPE" || { echo "push-guard: --findings has no fenced findings block, INCONCLUSIVE" >&2; exit 2; }
fi
for a in "${ALLOW[@]+"${ALLOW[@]}"}"; do
  a="${a#./}"
  case "$a" in ''|/*|..|../*|*/..|*/../*|*[\*\?\[]*) echo "push-guard: --allow '$a' must be a plain relative path, REFUSED" >&2; exit 1 ;; esac
  printf '%s\n' "$a" >>"$SCOPE"
done
# A test file lives under a test, tests, spec or __tests__ directory, or its own name says so
# (x_test.ext, x.test.ext, x.spec.ext, test_x.ext). The name is the last path segment only.
is_test() {
  local p="$1" base="${1##*/}" dir
  dir="/${p%/*}/"; [ "$p" = "$base" ] && dir="/"
  case "$dir" in */test/*|*/tests/*|*/spec/*|*/__tests__/*) return 0 ;; esac
  case "$base" in *_test.*|*.test.*|*.spec.*|test_*) return 0 ;; esac
  return 1
}

OUT=()
# Commits the base branch already holds came in through a merge of the base; they are not the fixer's.
EXCL=()
if [ -n "$BASE_OID" ] && git cat-file -e "$BASE_OID^{commit}" 2>/dev/null; then EXCL=(--not "$BASE_OID"); fi
if git merge-base --is-ancestor "$HEAD_OID" HEAD 2>/dev/null; then
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    while IFS= read -r -d '' f; do
      [ -n "$f" ] || continue
      grep -Fxq -- "$f" "$SCOPE" && continue
      is_test "$f" && continue
      OUT+=("$f")
    done < <(git show --no-renames --name-only -z --format= "$c" 2>/dev/null)
  done < <(git rev-list --no-merges "$HEAD_OID..HEAD" ${EXCL[@]+"${EXCL[@]}"} 2>/dev/null)
fi
if [ "${#OUT[@]}" -gt 0 ]; then
  REASONS+=("files outside the findings' scope: $(printf '%s\n' "${OUT[@]}" | sort -u | paste -sd' ' -)")
fi

if [ "${#REASONS[@]}" -gt 0 ]; then
  echo "push-guard: REFUSED. Do not push #$PR:" >&2
  for r in "${REASONS[@]}"; do echo "  - $r" >&2; done
  exit 1
fi
echo "push-guard: ok. #$PR, branch $HEAD_REF, fast-forward from ${HEAD_OID:0:12}, every touched file in scope."
exit 0
