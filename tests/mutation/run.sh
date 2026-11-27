#!/usr/bin/env bash
# Mutation check: undoes one guard at a time in a scratch copy and requires the suite that covers it
# to FAIL. A guard whose undoing still passes its suite is not protected by any test (N19 of PR 50,
# W8 and W9 of PR 51). Each mutant is one perl substitution; a mutant that does not apply is an error.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
W="$(mktemp -d "${TMPDIR:-/tmp}/mutation-XXXXXXXX")"; trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0; ROWS=()

# name | file (relative to ROOT) | perl substitution | suite (relative to ROOT)
MUTANTS=(
"remote-review: the second python3 loads the worktree (C1)|remote-review.sh|s/python3 -I -c/python3 -c/|tests/remote-review/run.sh"
"remote-review: reuse without the recorded head (W7)|remote-review.sh|s/if \\[ \"\\\$RECORDED\" != \"\\\$HEAD_SHA\" \\]; then/if false; then/|tests/remote-review/run.sh"
"install: the user-folder refusal in a comma list (W6)|install.sh|s/die \\\"\\\$h reads skills only from its user folder; use --scope user; nothing installed\\\"; fi/true; fi/|tests/install/run.sh"
"install: the empty-name check (N7)|install.sh|s/\\) die \"the harness list has an empty name/) true; echo \"the harness list has an empty name/|tests/install/run.sh"
)

# Copies the scripts and only the test folder the suite reads. tests/ holds ~300 MB of fixtures and scratch
# output that these suites never touch; copying all of it per mutant was most of the run time.
copy_tree() {
  local dest="$1" suite="$2" dir
  dir="$(dirname "$suite")"
  mkdir -p "$dest/$dir"
  (cd "$ROOT" && cp -R .agents install.sh install-remote.sh remote-review.sh VERSION "$dest/" 2>/dev/null \
    && cp -R "$dir/." "$dest/$dir/" 2>/dev/null)
}

# One mutant, in its own scratch folders so the mutants run at the same time. Its verdict goes to a file.
run_one() {
  local idx="$1" entry="$2" name file expr suite copy base out
  IFS='|' read -r name file expr suite <<<"$entry"
  copy="$W/m$idx/copy"; base="$W/m$idx/base"; out="$W/m$idx/row"
  mkdir -p "$copy" "$base"
  copy_tree "$copy" "$suite"
  # A mutant counts only when its file exists in the copy, perl succeeds, and the text changed.
  if [ ! -f "$copy/$file" ]; then echo "ERR  | $name (the file is not in the copy)" >"$out"; return; fi
  if ! perl -0pi -e "$expr" "$copy/$file"; then echo "ERR  | $name (perl could not apply the substitution)" >"$out"; return; fi
  if cmp -s "$copy/$file" "$ROOT/$file"; then echo "ERR  | $name (mutant did not apply)" >"$out"; return; fi
  # The unmutated copy must pass first: a suite that already fails proves nothing about the guard.
  copy_tree "$base" "$suite"
  if ! (cd "$base" && bash "$suite" >/dev/null 2>&1); then
    echo "ERR  | $name (the suite fails before any mutation: no baseline)" >"$out"; return
  fi
  if (cd "$copy" && bash "$suite" >/dev/null 2>&1); then
    echo "MISS | $name (the suite still passes: no test protects it)" >"$out"
  else
    echo "OK   | $name (the suite fails when it is undone)" >"$out"
  fi
}

i=0
for entry in "${MUTANTS[@]}"; do
  run_one "$i" "$entry" &
  i=$((i+1))
done
wait

PASS=0; FAIL=0
for j in $(seq 0 $((i-1))); do
  row="$(cat "$W/m$j/row")"
  printf '%s\n' "$row"
  case "$row" in OK*) PASS=$((PASS+1)) ;; *) FAIL=$((FAIL+1)) ;; esac
done
echo "TOTAL: $PASS guarded, $FAIL not guarded"
[ "$FAIL" = 0 ]
