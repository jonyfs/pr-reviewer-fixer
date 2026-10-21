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
#      Paths compare without case. A hit refuses with reason `sensitive-path`, and the change goes to
#      a person. A person who wants the fixer to edit one class (this repository's own release pull
#      requests edit .agents/skills/**) sets PUSH_GUARD_ALLOW_SENSITIVE to a comma list of class
#      names; a name it does not know refuses. The fixer never sets it itself. A class named there is
#      still subject to check 4: the file must be in scope. A symlink (mode 120000) added at a
#      sensitive directory or file, or at a parent of one (.github, .github/workflows,
#      .github/actions, .agents, .agents/skills, .claude, docs, a CODEOWNERS path, .mcp.json), is
#      refused the same way, since it moves the real files to a path no class covers; it passes only
#      when every class it covers is named (.github covers workflows, actions and codeowners). A
#      gitlink (mode 160000, a submodule) added or moved at one of those paths is refused the same
#      way. A symlink the pull request head or the local HEAD already holds at one of those paths
#      (`.claude/skills -> ../skills`) makes its target sensitive too: a touched path equal to the
#      target, or under it, is refused with the link's class, following a chain of links. A link
#      that sits at or under such a target (`skills/y -> ../other/y`) makes its own target sensitive
#      with the same class, repeated until no target is added. Paths are compared with the ASCII
#      letters A-Z folded and every other byte as it is. A link at one of those paths, or under such
#      a target, whose target leaves the repository (an absolute path, `..` above the root) or loops
#      cannot be followed, so the guard stops INCONCLUSIVE unless its class is allowed.
#   6. no commit adds a line that looks like a token or a private key: the added lines of each
#      commit's own changes (as in 4) go through `review-cycle.sh screen --patch`, the screen
#      `publish` uses. The patch is made with --text --no-textconv, so a file git treats as binary
#      (a NUL byte, a binary or -diff attribute) is read as the bytes it commits. A hit refuses with reason `secret`, naming the path, the line and the kind,
#      never the value. A value that was already on the base is not counted.
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
      if (p.startsWith("/") || p.split("/").includes("..") || /[*?\[\]\x00-\x1f\x7f]/.test(p)) continue;
      console.log(p);
    }
  ' "$FINDINGS" >>"$SCOPE" || { echo "push-guard: --findings has no fenced findings block, INCONCLUSIVE" >&2; exit 2; }
fi
# Sensitive paths (check 5). The class of a path, or nothing. Compared without case: on a
# case-insensitive checkout `.GitHub/Workflows/x.yml` is the same file. Only the ASCII letters A-Z are
# folded, byte for byte and whatever the locale, here and in tree_links, so a name with a non-ASCII
# letter compares the same on both sides.
fold_ascii() { LC_ALL=C tr 'A-Z' 'a-z'; }
sensitive_class() {
  local p; p="$(printf '%s' "$1" | fold_ascii)"
  case "$p" in
    .github/workflows/*) echo workflows ;;
    .github/actions/*) echo actions ;;
    codeowners|.github/codeowners|docs/codeowners) echo codeowners ;;
    .agents/skills/*) echo skills ;;
    .claude/*) echo claude ;;
    .mcp.json) echo mcp ;;
  esac
}
# A symlink at a sensitive directory or file, or at a parent of one (`.claude -> evil`, `.agents ->
# ag`), puts the real files under a path no class covers, so the symlink is itself the sensitive
# change. The classes such a path covers, space-separated, or nothing.
symlink_classes() {
  local p; p="$(printf '%s' "$1" | fold_ascii)"
  case "$p" in
    .github) echo "workflows actions codeowners" ;;
    .github/workflows) echo workflows ;;
    .github/actions) echo actions ;;
    .agents|.agents/skills) echo skills ;;
    .claude) echo claude ;;
    docs|codeowners|.github/codeowners|docs/codeowners) echo codeowners ;;
    .mcp.json) echo mcp ;;
  esac
}
SENS_OK=","
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
    git -c core.quotePath=false diff-tree -r --root --no-commit-id --no-renames "${fmt[@]}" "$c" 2>/dev/null; return 0
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
  git -c core.quotePath=false diff-tree -r --no-renames "${fmt[@]}" "$tree" "$c^{tree}" 2>/dev/null
}
# Links the trees already hold (check 5). Every symlink in the pull request head and in the local HEAD,
# each tree resolved on its own, NUL-delimited as: link path, ok|outside|loop, and the path its target
# resolves to inside the repository, ASCII letters folded, following a chain of links. A pushed
# commit records the real path, so an edit made through `.claude/skills -> ../skills` shows as
# skills/..., which no class names.
tree_links() {
  node -e '
    const { execFileSync } = require("child_process");
    const git = (a) => execFileSync("git", a, { maxBuffer: 1 << 30 });
    const fold = (s) => s.replace(/[A-Z]/g, (c) => c.toLowerCase());
    // Each tree on its own: a link the local HEAD retargets is resolved by both of its targets.
    for (const t of process.argv.slice(1)) {
      const links = new Map();
      for (const rec of git(["ls-tree", "-r", "-z", "--full-tree", t]).toString("latin1").split("\0")) {
        const m = /^120000 blob ([0-9a-f]+)\t([\s\S]+)$/.exec(rec);
        if (m) links.set(m[2], git(["cat-file", "blob", m[1]]).toString("latin1"));
      }
      const low = new Map([...links].map(([p, t]) => [fold(p), t]));
      const resolve = (p) => {
        let parts = p.split("/"), out = [], hops = 0;
        while (parts.length) {
          const c = parts.shift();
          if (c === "" || c === ".") continue;
          if (c === "..") { if (!out.length) return ["outside", ""]; out.pop(); continue; }
          out.push(fold(c));
          const t = low.get(out.join("/"));
          if (t === undefined) continue;
          if (++hops > 40) return ["loop", ""];
          if (t.startsWith("/") || t.includes("\0")) return ["outside", ""];
          out.pop(); parts = t.split("/").concat(parts);
        }
        return ["ok", out.join("/")];
      };
      for (const [p, t] of links) {
        const dir = p.includes("/") ? p.slice(0, p.lastIndexOf("/")) : "";
        const [st, r] = t.startsWith("/") || t.includes("\0") ? ["outside", ""] : resolve(dir + "/" + t);
        process.stdout.write(Buffer.from(p + "\0" + st + "\0" + r + "\0", "latin1"));
      }
    }
  ' "$@"
}
# A sensitive link's target, its classes not all allowed: LINK_PFX (ASCII letters folded, "" is the
# whole repository), LINK_CLS and LINK_SRC, index for index. A link at a sensitive path is taken first.
# Then a link that sits at or under a target already taken is taken with that target's classes (a
# nested link: skills/y -> ../other/y inside .claude/skills -> ../skills), until no target is added.
LINK_PFX=() LINK_CLS=() LINK_SRC=()
# Whether a touched path is a sensitive link's target or under it; sets LINK_HIT for the reason and
# LINK_IDX to the target's index.
through_link() {
  local p i n="${#LINK_PFX[@]}"
  p="$(printf '%s' "$1" | fold_ascii)"
  for ((i = 0; i < n; i++)); do
    if [ -z "${LINK_PFX[$i]}" ] || [ "$p" = "${LINK_PFX[$i]}" ] || case "$p" in "${LINK_PFX[$i]}"/*) true ;; *) false ;; esac; then
      LINK_HIT="${LINK_CLS[$i]} via the symlink ${LINK_SRC[$i]}"; LINK_IDX=$i; return 0
    fi
  done
  return 1
}
if git merge-base --is-ancestor "$HEAD_OID" HEAD 2>/dev/null; then
  LINKS="$(mktemp)"
  tree_links "$HEAD_OID" HEAD >"$LINKS" 2>/dev/null \
    || { rm -f "$LINKS"; echo "push-guard: could not list the symlinks in the trees, INCONCLUSIVE" >&2; exit 2; }
  TL_L=() TL_ST=() TL_R=() TL_DONE=()
  while IFS= read -r -d '' L && IFS= read -r -d '' st && IFS= read -r -d '' R; do
    TL_L+=("$L"); TL_ST+=("$st"); TL_R+=("$R"); TL_DONE+=("")
  done <"$LINKS"
  rm -f "$LINKS"
  added=1 first=1
  while [ -n "$added" ]; do
    added=""
    for ((j = 0; j < ${#TL_L[@]}; j++)); do
      [ -z "${TL_DONE[$j]}" ] || continue
      L="${TL_L[$j]}" src=""
      if [ -n "$first" ]; then
        cls="$(symlink_classes "$L")"; [ -n "$cls" ] || cls="$(sensitive_class "$L")"
      elif through_link "$L"; then
        cls="${LINK_CLS[$LINK_IDX]}" src=" inside ${LINK_SRC[$LINK_IDX]}"
      else
        cls=""
      fi
      [ -n "$cls" ] || continue
      TL_DONE[$j]=1
      need=""
      for k in $cls; do case "$SENS_OK" in *",$k,"*) ;; *) need=1 ;; esac; done
      [ -n "$need" ] || continue
      if [ "${TL_ST[$j]}" != ok ]; then
        echo "push-guard: the symlink $(printf '%q' "$L") leads outside the repository or loops (${TL_ST[$j]}), so what it makes sensitive is unknown, INCONCLUSIVE" >&2; exit 2
      fi
      LINK_PFX+=("${TL_R[$j]}"); LINK_CLS+=("$cls"); LINK_SRC+=("$L$src"); added=1
    done
    # The first round takes links at sensitive paths; every later one, links under a target taken.
    [ -z "$first" ] || added=1
    first=""
  done
fi
PATCH="$(mktemp)"; trap 'rm -f "$SCOPE" "$PATCH"' EXIT
if git merge-base --is-ancestor "$HEAD_OID" HEAD 2>/dev/null; then
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    PATHS="$(mktemp)"
    if ! commit_paths "$c" >"$PATHS"; then REASONS+=("$(cat "$PATHS")"); rm -f "$PATHS"; continue; fi
    commit_paths "$c" patch >>"$PATCH" || true
    # Symlinks and gitlinks this commit adds or changes, checked against symlink_classes (check 5).
    while IFS= read -r -d '' meta && IFS= read -r -d '' f; do
      set -- $meta
      case "${2:-}" in 120000) kind=symlink ;; 160000) kind=gitlink ;; *) continue ;; esac
      cls="$(symlink_classes "$f")"; [ -n "$cls" ] || cls="$(sensitive_class "$f")"; [ -n "$cls" ] || continue
      for k in $cls; do
        case "$SENS_OK" in *",$k,"*) ;; *) SENS+=("$f ($kind over $cls)"); break ;; esac
      done
    done < <(commit_paths "$c" raw 2>/dev/null)
    while IFS= read -r -d '' f; do
      [ -n "$f" ] || continue
      if (LC_ALL=C; case "$f" in *[$CTRL]*) exit 0 ;; *) exit 1 ;; esac); then BADNAME+=("$(printf '%q' "$f")"); continue; fi
      cls="$(sensitive_class "$f")"
      if [ -n "$cls" ]; then
        case "$SENS_OK" in *",$cls,"*) ;; *) SENS+=("$f ($cls)"); continue ;; esac
      fi
      if through_link "$f"; then SENS+=("$f ($LINK_HIT)"); continue; fi
      in_scope "$f" && continue
      is_test "$f" && continue
      OUT+=("$f")
    done <"$PATHS"
    rm -f "$PATHS"
  done < <(git rev-list "$HEAD_OID..HEAD" ${EXCL[@]+"${EXCL[@]}"} 2>/dev/null)
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
  REASONS+=("sensitive-path: $(printf '%s\n' "${SENS[@]}" | sort -u | paste -sd',' - | sed 's/,/, /g'). These files run or judge the automation, so the fixer does not push them even when a finding names them: escalate to a person (who may set PUSH_GUARD_ALLOW_SENSITIVE=<class>)")
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
