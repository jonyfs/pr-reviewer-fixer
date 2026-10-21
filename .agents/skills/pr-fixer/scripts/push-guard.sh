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
#      or named x_test.*, x.test.*, x.spec.* or test_x.*). A path matches a scope entry only when the
#      two are equal byte for byte, and a touched path holding a control character (a newline, a tab)
#      is refused outright. A merge commit is checked by its own changes: git recomputes the merge
#      of its two parents (`git merge-tree --write-tree`, git 2.38 or later), and every path where
#      the commit differs from that automatic result must be in scope. That is a file changed by hand
#      inside the merge (an "evil merge") and the resolution of every conflicted file, so pass the
#      conflicted files with --allow. What the merge brought in unchanged from either side is not
#      counted. A merge with more than two parents, a merge git cannot recompute, and any merge when
#      git is older than 2.38 are refused. A commit the base branch already holds is not checked,
#      since a merge of the base brings it in. When the base commit is not in the clone, the base's
#      own commits are checked like any other, so fetch the base first.
#   5. no commit touches a sensitive path, even one a finding names or --allow passes: the files
#      that run or judge the automation itself. Each belongs to a class:
#        workflows   .github/workflows/**        actions  .github/actions/**
#        codeowners  CODEOWNERS, .github/CODEOWNERS, docs/CODEOWNERS
#        skills      .agents/skills/**           claude   .claude/**
#        mcp         .mcp.json
#      A hit refuses with reason `sensitive-path`, and the change goes to a person. A person who wants
#      the fixer to edit one class (this repository's own release pull requests edit
#      .agents/skills/**) sets PUSH_GUARD_ALLOW_SENSITIVE to a comma list of class names; a name it
#      does not know refuses, and so does any character other than a lower-case letter, a comma, a
#      space or a tab (a class after a newline is refused, not skipped). The fixer never sets it
#      itself. A class named there is still subject to check 4: the file must be in scope.
#      Names are compared after a Unicode fold broader than any filesystem's: NFKD, combining marks
#      and default-ignorable code points dropped, case folded. APFS ignores case and normalization
#      and NTFS ignores case, so `.CLAUDE/x`, `.agents/ſkills/x` (a long s) and an NFD spelling all
#      reach their class. Folding too much refuses more, never less.
#      Links are refused, not followed. Every symlink (mode 120000) and gitlink (mode 160000) that the
#      pull request head or the local HEAD holds, or that a pushed commit adds, refuses the whole push
#      with reason `sensitive-path`, naming the link, when it sits at a sensitive path or at a parent
#      of one (.github, .github/workflows, .github/actions, .agents, .agents/skills, .claude, docs, a
#      CODEOWNERS path, .mcp.json), or when its target, resolved lexically against the link's own
#      directory, points at, into or above one (`src/x -> ../.claude`, `src/x -> ..`). A target that
#      holds a non-ASCII byte, that leaves the repository (an absolute path, `..` above the root), or
#      that steps back with `..` out of a component that is itself a link (`x -> a/../skills` with
#      `a -> .agents/q` really reaches .agents/skills), cannot be judged lexically, so it involves
#      every class. A link passes only when every class it involves is named in
#      PUSH_GUARD_ALLOW_SENSITIVE (.github involves workflows, actions and codeowners). A link name
#      or target that holds a control character is printed quoted (`printf %q`), so text the pull
#      request author chose cannot pose as a line of this script's output.
#   6. no commit adds a line that looks like a token or a private key: the added lines of each
#      commit's own changes (as in 4) go through `review-cycle.sh screen --patch`, the screen
#      `publish` uses. The patch is made with --text --no-textconv, so a file git treats as binary
#      (a NUL byte, a binary or -diff attribute) is read as the bytes it commits. A hit refuses with reason `secret`, naming the path, the line and the kind,
#      never the value. A value that was already on the base is not counted.
#
# EXIT CODES. 0 = safe to push. 1 = refused, with every reason printed. 2 = could not check: gh
# or git missing, not inside a work tree, the pull request unreadable, its head commit not
# present locally (fetch it first), or git failing to show a commit's changes or file modes, which
# would leave that commit out of check 5 or 6. Exit 2 never means "safe".
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
      if (p.startsWith("/") || p.split("/").includes("..") || /[*?\[\]\x00-\x1f\x7f]/.test(p)) continue;
      console.log(p);
    }
  ' "$FINDINGS" >>"$SCOPE" || { echo "push-guard: --findings has no fenced findings block, INCONCLUSIVE" >&2; exit 2; }
fi
# Sensitive paths and links (check 5), in one node pass. Arguments: a file of touched paths and a file
# of `diff-tree --raw -z` records from the pushed commits, both NUL-delimited, two output files, then
# the trees to scan. It writes every touched path once as `path\0class\0` (class empty when none), and
# every symlink or gitlink in the trees or the records that involves a class as
# `path\0symlink|gitlink\0classes\0why\0`. Names are folded with Unicode before they are compared,
# broader than APFS or NTFS fold them (see the header), so over-folding refuses more and never less.
CHECK5_JS='
const fs = require("fs"), { execFileSync } = require("child_process");
const [touchedF, rawF, outP, outL, ...trees] = process.argv.slice(1);
const git = (a, input) => execFileSync("git", a, { maxBuffer: 1 << 30, input, stdio: ["pipe", "pipe", "ignore"] });
const ALL = ["workflows", "actions", "codeowners", "skills", "claude", "mcp"];
const drop = /[\p{M}\p{Default_Ignorable_Code_Point}]/gu;
const nfkd = (s) => s.normalize("NFKD").replace(drop, "");
// Raw bytes (a latin1 string) to a folded name: UTF-8, NFKD, marks and ignorables dropped, case folded.
const fold = (b) => nfkd(nfkd(Buffer.from(b, "latin1").toString("utf8")).toLowerCase().toUpperCase().toLowerCase());
const fileClass = (f) =>
  f.startsWith(".github/workflows/") ? "workflows" : f.startsWith(".github/actions/") ? "actions"
  : ["codeowners", ".github/codeowners", "docs/codeowners"].includes(f) ? "codeowners"
  : f.startsWith(".agents/skills/") ? "skills" : f.startsWith(".claude/") ? "claude" : f === ".mcp.json" ? "mcp" : "";
// A sensitive directory or file, or a parent of one: the classes a link there moves away.
const PARENT = { ".github": "workflows actions codeowners", ".github/workflows": "workflows",
  ".github/actions": "actions", ".agents": "skills", ".agents/skills": "skills", ".claude": "claude",
  "docs": "codeowners", "codeowners": "codeowners", ".github/codeowners": "codeowners",
  "docs/codeowners": "codeowners", ".mcp.json": "mcp" };
const classesAt = (b) => { const f = fold(b); return new Set([fileClass(f), ...(PARENT[f] || "").split(" ")]); };
const order = (s) => ALL.filter((c) => s.has(c));
const nul = (a) => Buffer.from(a.map((x) => x + "\0").join(""), "latin1");

const touched = [], seen = new Set();
for (const f of fs.readFileSync(touchedF).toString("latin1").split("\0")) {
  if (!f || seen.has(f)) continue;
  seen.add(f); touched.push(f, fileClass(fold(f)));
}
fs.writeFileSync(outP, nul(touched));

const links = new Map();
const add = (mode, sha, p) => { if (mode === "120000" || mode === "160000") links.set(mode + " " + sha + " " + p, [mode, sha, p]); };
for (const t of trees)
  for (const rec of git(["ls-tree", "-r", "-z", "--full-tree", t]).toString("latin1").split("\0")) {
    const m = /^(120000|160000) (?:blob|commit) ([0-9a-f]+)\t([\s\S]+)$/.exec(rec);
    if (m) add(m[1], m[2], m[3]);
  }
const raw = fs.readFileSync(rawF).toString("latin1").split("\0");
for (let i = 0; i + 1 < raw.length; i += 2) { const m = raw[i].split(" "); add(m[1], m[3], raw[i + 1]); }
// Every symlink target in one cat-file call.
const shas = [...new Set([...links.values()].filter((l) => l[0] === "120000").map((l) => l[1]))];
const blobs = new Map();
if (shas.length) {
  const out = git(["cat-file", "--batch"], shas.join("\n") + "\n");
  for (let o = 0; o < out.length;) {
    const nl = out.indexOf(10, o), h = out.subarray(o, nl).toString().split(" ");
    if (h[1] !== "blob") throw new Error("symlink target " + h[0] + " is not a blob");
    const n = Number(h[2]); blobs.set(h[0], out.subarray(nl + 1, nl + 1 + n)); o = nl + 2 + n;
  }
}
// Every link path, to see a target that walks through another link: `..` after a link component
// leaves for the parent of that link target, which a lexical walk cannot know. Folded like every other
// name here, since APFS and NTFS resolve `A/..` through a link named `a`.
const linkPaths = new Set([...links.values()].map((l) => fold(l[2])));
const res = [];
for (const [mode, sha, p] of links.values()) {
  const cls = classesAt(p); let why = "";
  if (mode === "120000") {
    const tb = blobs.get(sha), t = tb.toString("latin1");
    let unknown = "";
    if (tb.some((b) => b >= 0x80)) unknown = "holds a non-ASCII byte";
    else if (/^[\/\\]/.test(t) || /^[A-Za-z]:/.test(t) || t.includes("\0")) unknown = "leaves the repository";
    else {
      // Lexically, against the link s own directory; a backslash counts as a separator too.
      const out = [];
      for (const c of p.split("/").slice(0, -1).concat(t.split(/[\/\\]/))) {
        if (c === "" || c === ".") continue;
        if (c !== "..") { out.push(c); continue; }
        if (!out.length) { unknown = "leaves the repository"; break; }
        if (linkPaths.has(fold(out.join("/")))) { unknown = "steps back out of another link"; break; }
        out.pop();
      }
      if (!unknown) {
        const r = out.join("/"), tc = r === "" ? new Set(ALL) : classesAt(r);
        if (order(tc).length) { tc.forEach((c) => cls.add(c)); why = r === "" ? "\x01the repository root" : "\x02" + r; }
      }
    }
    if (unknown) { ALL.forEach((c) => cls.add(c)); why = "\x01" + unknown; }
  }
  const c = order(cls);
  if (c.length) res.push(p, mode === "120000" ? "symlink" : "gitlink", c.join(" "), why);
}
fs.writeFileSync(outL, nul(res));
'
SENS_OK=","
# Only class names, commas, spaces and tabs. `read` below takes the first line alone, so a class after a
# newline would otherwise never be looked at, and an unknown one never refused.
_allowed=$'a-z, \t'
if (LC_ALL=C; case "${PUSH_GUARD_ALLOW_SENSITIVE:-}" in *[!$_allowed]*) exit 0 ;; *) exit 1 ;; esac); then
  echo "push-guard: PUSH_GUARD_ALLOW_SENSITIVE is $(printf '%q' "$PUSH_GUARD_ALLOW_SENSITIVE"); it may hold only class names (workflows, actions, codeowners, skills, claude, mcp), commas, spaces and tabs, REFUSED" >&2; exit 1
fi
IFS=',' read -r -a _sens <<<"${PUSH_GUARD_ALLOW_SENSITIVE:-}"
for _c in "${_sens[@]+"${_sens[@]}"}"; do
  _c="$(printf '%s' "$_c" | tr -d ' \t')"
  [ -n "$_c" ] || continue
  case "$_c" in
    workflows|actions|codeowners|skills|claude|mcp) SENS_OK="$SENS_OK$_c," ;;
    *) echo "push-guard: PUSH_GUARD_ALLOW_SENSITIVE names '$_c', which is not a class (workflows, actions, codeowners, skills, claude, mcp), REFUSED" >&2; exit 1 ;;
  esac
done
# A control character (newline, tab, ...) is refused in every name: in a scope entry, and below in a
# touched path. The C locale makes the byte range below mean bytes 1-31 and 127 and nothing else.
CTRL=$'\001'-$'\037'$'\177'
for a in "${ALLOW[@]+"${ALLOW[@]}"}"; do
  a="${a#./}"
  case "$a" in ''|/*|..|../*|*/..|*/../*|*[\*\?\[]*) echo "push-guard: --allow '$a' must be a plain relative path, REFUSED" >&2; exit 1 ;; esac
  if (LC_ALL=C; case "$a" in *[$CTRL]*) exit 0 ;; *) exit 1 ;; esac); then
    echo "push-guard: --allow $(printf '%q' "$a") holds a control character, REFUSED" >&2; exit 1
  fi
  printf '%s\n' "$a" >>"$SCOPE"
done
# The scope as a list of exact names, one per line of $SCOPE (no entry can hold a newline). A touched
# path is in scope only when it equals one entry byte for byte: no pattern, no prefix, no splitting.
SCOPE_LIST=()
while IFS= read -r s; do [ -n "$s" ] && SCOPE_LIST+=("$s"); done <"$SCOPE"
in_scope() {
  local s
  for s in "${SCOPE_LIST[@]+"${SCOPE_LIST[@]}"}"; do [ "$s" = "$1" ] && return 0; done
  return 1
}
# A test file lives under a test, tests, spec or __tests__ directory, or its own name says so
# (x_test.ext, x.test.ext, x.spec.ext, test_x.ext). The name is the last path segment only.
is_test() {
  local p="$1" base="${1##*/}" dir
  dir="/${p%/*}/"; [ "$p" = "$base" ] && dir="/"
  case "$dir" in */test/*|*/tests/*|*/spec/*|*/__tests__/*) return 0 ;; esac
  case "$base" in *_test.*|*.test.*|*.spec.*|test_*) return 0 ;; esac
  return 1
}

OUT=() BADNAME=() SENS=()
# Commits the base branch already holds came in through a merge of the base; they are not the fixer's.
EXCL=()
if [ -n "$BASE_OID" ] && git cat-file -e "$BASE_OID^{commit}" 2>/dev/null; then EXCL=(--not "$BASE_OID"); fi
# git merge-tree --write-tree (git 2.38 and later) is what recomputes a merge without touching the
# work tree. Without it a merge commit cannot be checked, so it is refused.
merge_tree_ok() {
  local v maj min
  v="$(git version 2>/dev/null)"; v="${v#git version }"
  maj="${v%%.*}"; min="${v#*.}"; min="${min%%.*}"
  case "$maj$min" in ''|*[!0-9]*) return 1 ;; esac
  [ "$maj" -gt 2 ] || { [ "$maj" -eq 2 ] && [ "$min" -ge 38 ]; }
}
# The paths a commit itself changes, NUL-delimited (or, with `patch` as $2, its own changes as a
# unified diff with no context, which the secret screen reads). An ordinary commit: against its parent. A merge
# commit: against the tree git produces when it merges the two parents on its own, so what the merge
# brought in from either side is not counted, and what was written into the merge by hand is (an
# "evil merge", and the resolution of every conflicted file). Exit 1 when the commit cannot be read
# this way, with the reason on stdout.
commit_paths() {
  local c="$1" parents n tree rc fmt=(--name-only -z)
  # `raw`: one `:oldmode newmode oldsha newsha status` record and its path, NUL-delimited, so a
  # symlink (mode 120000) can be told from a file.
  [ "${2:-}" = raw ] && fmt=(--raw -z)
  # --text --no-textconv: a file git treats as binary (a NUL byte, a binary or -diff attribute from
  # any .gitattributes or .git/info/attributes) would show no added line, and the screen would pass it.
  [ "${2:-}" = patch ] && fmt=(-p -U0 --text --no-textconv --no-color --no-ext-diff)
  parents="$(git rev-list --parents -n 1 "$c" 2>/dev/null)" || { echo "commit ${c:0:12} could not be read"; return 1; }
  set -- $parents; shift; n=$#
  if [ "$n" -le 1 ]; then
    git -c core.quotePath=false diff-tree -r --root --no-commit-id --no-renames "${fmt[@]}" "$c" 2>/dev/null \
      || { echo "commit ${c:0:12} could not be read by git diff-tree"; return 1; }
    return 0
  fi
  [ "$n" -eq 2 ] || { echo "merge commit ${c:0:12} has $n parents; an octopus merge is not checked"; return 1; }
  merge_tree_ok || { echo "merge commit ${c:0:12} cannot be checked: git merge-tree --write-tree needs git 2.38 or later"; return 1; }
  # Exit 0 is a clean merge and 1 a merge with conflicts (the tree, with conflict markers, is still
  # the first line); anything else is an error. Conflicted files therefore differ from the commit,
  # and must be in scope: pass them with --allow.
  tree="$(git merge-tree --write-tree --no-messages "$1" "$2" 2>/dev/null)"; rc=$?
  tree="${tree%%$'\n'*}"
  if [ "$rc" -gt 1 ] || ! git cat-file -e "$tree^{tree}" 2>/dev/null; then
    echo "merge commit ${c:0:12} could not be recomputed with git merge-tree, so its own changes are unknown"; return 1
  fi
  git -c core.quotePath=false diff-tree -r --no-renames "${fmt[@]}" "$tree" "$c^{tree}" 2>/dev/null \
    || { echo "merge commit ${c:0:12} could not be compared with its recomputed merge"; return 1; }
}
PATCH="$(mktemp)" TOUCHED="$(mktemp)" XRAW="$(mktemp)" C5P="$(mktemp)" C5L="$(mktemp)"
trap 'rm -f "$SCOPE" "$PATCH" "$TOUCHED" "$XRAW" "$C5P" "$C5L"' EXIT
if git merge-base --is-ancestor "$HEAD_OID" HEAD 2>/dev/null; then
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    PATHS="$(mktemp)"
    if ! commit_paths "$c" >"$PATHS"; then REASONS+=("$(cat "$PATHS")"); rm -f "$PATHS"; continue; fi
    # A commit whose patch or link records cannot be read would drop out of the secret screen (6) or
    # the link check (5) unseen, so it makes the whole check INCONCLUSIVE instead. A commit that
    # touches a path always has a patch: at least its `diff --git` header.
    ONE="$(mktemp)"
    if ! commit_paths "$c" patch >"$ONE" || { [ -s "$PATHS" ] && [ ! -s "$ONE" ]; }; then
      rm -f "$PATHS" "$ONE"; echo "push-guard: the changes of commit ${c:0:12} could not be read for the secret screen, INCONCLUSIVE" >&2; exit 2
    fi
    cat "$ONE" >>"$PATCH"
    # The symlinks and gitlinks this commit adds or changes, for check 5 (a link added and removed
    # again before the head is in no tree).
    if ! commit_paths "$c" raw >"$ONE"; then
      rm -f "$PATHS" "$ONE"; echo "push-guard: the file modes of commit ${c:0:12} could not be read for the link check, INCONCLUSIVE" >&2; exit 2
    fi
    cat "$ONE" >>"$XRAW"; cat "$PATHS" >>"$TOUCHED"; rm -f "$PATHS" "$ONE"
  done < <(git rev-list "$HEAD_OID..HEAD" ${EXCL[@]+"${EXCL[@]}"} 2>/dev/null)
  # 5. One node pass: the class of every touched path, and every link that involves a class.
  node -e "$CHECK5_JS" "$TOUCHED" "$XRAW" "$C5P" "$C5L" "$HEAD_OID" HEAD 2>/dev/null \
    || { echo "push-guard: could not read the links or classify the touched paths, INCONCLUSIVE" >&2; exit 2; }
  while IFS= read -r -d '' L && IFS= read -r -d '' kind && IFS= read -r -d '' cls && IFS= read -r -d '' why; do
    # The link's name and its target are the pull request author's text. One that holds a control
    # character (a newline could forge a line of this output) is printed quoted, as `printf %q`
    # quotes it; the guard's own words (\x01) are printed as they are.
    case "$why" in
      $'\001'*) why=", its target ${why#?}" ;;
      $'\002'*) why="${why#?}"; if (LC_ALL=C; case "$why" in *[$CTRL]*) exit 0 ;; *) exit 1 ;; esac); then why="$(printf '%q' "$why")"; fi; why=", its target $why" ;;
    esac
    if (LC_ALL=C; case "$L" in *[$CTRL]*) exit 0 ;; *) exit 1 ;; esac); then L="$(printf '%q' "$L")"; fi
    for k in $cls; do
      case "$SENS_OK" in *",$k,"*) ;; *) SENS+=("$L ($kind over $cls$why)"); break ;; esac
    done
  done <"$C5L"
  while IFS= read -r -d '' f && IFS= read -r -d '' cls; do
    if (LC_ALL=C; case "$f" in *[$CTRL]*) exit 0 ;; *) exit 1 ;; esac); then BADNAME+=("$(printf '%q' "$f")"); continue; fi
    if [ -n "$cls" ]; then
      case "$SENS_OK" in *",$cls,"*) ;; *) SENS+=("$f ($cls)"); continue ;; esac
    fi
    in_scope "$f" && continue
    is_test "$f" && continue
    OUT+=("$f")
  done <"$C5P"
fi
# 6. The secret screen over what these commits add, the same one `publish` and the fixer's closure
# use. Only the commits' own changes are read, so a value already on the base does not refuse a
# merge of the base. The value is never printed: only the path, the line and the kind.
if [ -s "$PATCH" ]; then
  RCY="$(dirname "$0")/review-cycle.sh"
  [ -f "$RCY" ] || { echo "push-guard: review-cycle.sh is not beside push-guard.sh, so the secret screen cannot run, INCONCLUSIVE" >&2; exit 2; }
  HITS="$(bash "$RCY" screen --patch "$PATCH" 2>/dev/null)"; src=$?
  case "$src" in
    0) ;;
    1) REASONS+=("secret: the commits add what looks like a credential (value not shown): $(printf '%s' "$HITS" | paste -sd';' - | sed 's/;/; /g')") ;;
    *) echo "push-guard: the secret screen could not read the commits, INCONCLUSIVE" >&2; exit 2 ;;
  esac
fi
if [ "${#SENS[@]}" -gt 0 ]; then
  REASONS+=("sensitive-path: $(printf '%s\n' "${SENS[@]}" | sort -u | awk 'NR > 1 { printf ", " } { printf "%s", $0 }'). These files run or judge the automation, so the fixer does not push them even when a finding names them: escalate to a person (who may set PUSH_GUARD_ALLOW_SENSITIVE=<class>)")
fi
if [ "${#BADNAME[@]}" -gt 0 ]; then
  REASONS+=("touched paths with a control character in the name, never pushed: ${BADNAME[*]}")
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
