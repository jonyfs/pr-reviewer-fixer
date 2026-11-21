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

for entry in "${MUTANTS[@]}"; do
  IFS='|' read -r name file expr suite <<<"$entry"
  rm -rf "$W/copy"; mkdir -p "$W/copy"
  (cd "$ROOT" && cp -R .agents install.sh install-remote.sh remote-review.sh VERSION tests "$W/copy/" 2>/dev/null)
  before="$(cmp -s "$W/copy/$file" "$ROOT/$file" && echo same)"
  # A mutant counts only when its file exists in the copy, perl succeeds, and the text changed.
  if [ ! -f "$W/copy/$file" ]; then
    ROWS+=("ERR  | $name (the file is not in the copy)"); FAIL=$((FAIL+1)); continue
  fi
  if ! perl -0pi -e "$expr" "$W/copy/$file"; then
    ROWS+=("ERR  | $name (perl could not apply the substitution)"); FAIL=$((FAIL+1)); continue
  fi
  if cmp -s "$W/copy/$file" "$ROOT/$file"; then
    ROWS+=("ERR  | $name (mutant did not apply)"); FAIL=$((FAIL+1)); continue
  fi
  # The unmutated copy must pass first: a suite that already fails proves nothing about the guard.
  rm -rf "$W/base"; mkdir -p "$W/base"
  (cd "$ROOT" && cp -R .agents install.sh install-remote.sh remote-review.sh VERSION tests "$W/base/" 2>/dev/null)
  if ! (cd "$W/base" && bash "$suite" >/dev/null 2>&1); then
    ROWS+=("ERR  | $name (the suite fails before any mutation: no baseline)"); FAIL=$((FAIL+1)); continue
  fi
  if (cd "$W/copy" && bash "$suite" >/dev/null 2>&1); then
    ROWS+=("MISS | $name (the suite still passes: no test protects it)"); FAIL=$((FAIL+1))
  else
    ROWS+=("OK   | $name (the suite fails when it is undone)"); PASS=$((PASS+1))
  fi
done
printf '%s\n' "${ROWS[@]}"
echo "TOTAL: $PASS guarded, $FAIL not guarded"
[ "$FAIL" = 0 ]
