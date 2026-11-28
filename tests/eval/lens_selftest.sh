#!/usr/bin/env bash
# Tests lens_score.py with canned reports made from the lens cases themselves. No model is run.
# Prints a pass/fail table.
set -u
unset REVIEW_BLOCK_AT PUSH_GUARD_ALLOW_SENSITIVE
T="$(cd "$(dirname "$0")" && pwd)"
CASES="$T/lens/cases"
LS="$T/lens_score.py"
W="$(mktemp -d "${TMPDIR:-/tmp}/lens-selftest.XXXXXX")"
trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0; ROWS=()
row() { if [ "$2" = ok ]; then PASS=$((PASS+1)); ROWS+=("PASS | $1"); else FAIL=$((FAIL+1)); ROWS+=("FAIL | $1 ($3)"); fi; }
check() { local name="$1"; shift; if "$@"; then row "$name" ok; else row "$name" bad "assert failed"; fi; }

# mk <dir> <mode>: one report per lens case. Modes:
#   perfect  each defect case names its defect at its own line and severity; each twin is empty
#   empty    every report has no finding
#   noisy    perfect, plus a WARNING on every correctness twin
#   weak     every defect is named as a NOTE (a hit only for the NOTE-level lenses, docs and readability)
#   dropped  perfect, except the performance lens has no finding at all
mk() {
  python3 -I - "$CASES" "$W/$1" "$2" <<'PY'
import json, os, sys
cases, out, mode = sys.argv[1:4]
os.makedirs(out, exist_ok=True)
for name in sorted(os.listdir(cases)):
    p = os.path.join(cases, name, "expected.json")
    if not os.path.isfile(p):
        continue
    exp = json.load(open(p))
    twin = name.endswith("-twin")
    rows = []
    if not twin and mode in ("perfect", "noisy", "weak", "dropped") and not (mode == "dropped" and name.startswith("lens-performance-")):
        for d in exp["defects"]:
            sev = d["min_severity"]
            if mode == "weak":
                sev = "NOTE"
            rows.append((d["file"], d["line"], sev))
    if twin and mode == "noisy" and name.startswith("lens-correctness-"):
        rows.append(("anywhere.py", 1, "WARNING"))
    lines = ["## Review: " + name, "", "```findings", "version: 1", "findings:" if rows else "findings: []"]
    for i, (f, l, s) in enumerate(rows, 1):
        lines += ["  - id: F%d" % i, "    severity: %s" % s, "    file: %s" % f, "    line: %d" % l]
    lines.append("```")
    open(os.path.join(out, name + ".md"), "w").write("\n".join(lines) + "\n")
PY
}
sc() { python3 -I "$LS" --cases "$CASES" "$@"; }
jq_() { python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(eval(sys.argv[1])))' "$1"; }

mk perfect perfect; mk empty empty; mk noisy noisy; mk weak weak; mk dropped dropped

check "a perfect run: recall 1 and no twin false positive, in every lens" \
  eval '[ "$(sc --reports "$W/perfect" --json | jq_ "d[\"overall\"][\"recall\"], d[\"overall\"][\"twin_fp_rate\"], len(d[\"lenses\"])")" = "[1.0, 0.0, 18]" ]'
check "an empty run: recall 0" \
  eval '[ "$(sc --reports "$W/empty" --json | jq_ "d[\"overall\"][\"recall\"]")" = "0.0" ]'
check "a WARNING on a twin counts as a false positive for its lens only" \
  eval '[ "$(sc --reports "$W/noisy" --json | jq_ "d[\"lenses\"][\"correctness\"][\"twin_fp\"], d[\"lenses\"][\"design\"][\"twin_fp\"]")" = "[10, 0]" ]'
check "a NOTE where a WARNING is required is not a hit" \
  eval '[ "$(sc --reports "$W/weak" --json | jq_ "d[\"lenses\"][\"performance\"][\"hit\"]")" = "0" ]'
check "--lens scores only the named lenses" \
  eval '[ "$(sc --reports "$W/perfect" --lens docs --lens privacy --json | jq_ "sorted(d[\"lenses\"])")" = "[\"docs\", \"privacy\"]" ]'
check "--min-recall above the recall exits 1" eval 'sc --reports "$W/empty" --min-recall 0.5 >/dev/null 2>&1; [ $? = 1 ]'
check "--min-recall is checked per lens: one lens with no recall fails a run that is otherwise perfect" \
  eval 'sc --reports "$W/dropped" --min-recall 0.5 >/dev/null 2>&1; [ $? = 1 ]'
check "an unknown lens beside a known one exits 2" eval 'sc --reports "$W/perfect" --lens docs --lens nonsens >/dev/null 2>&1; [ $? = 2 ]'
check "a missing cases directory exits 2, not 1" eval 'python3 -I "$LS" --cases "$W/none" --reports "$W/perfect" >/dev/null 2>&1; [ $? = 2 ]'
check "--min-recall met exits 0" eval 'sc --reports "$W/perfect" --min-recall 0.9 >/dev/null 2>&1'
check "--max-twin-fp exceeded exits 1" eval 'sc --reports "$W/noisy" --max-twin-fp 0.01 >/dev/null 2>&1; [ $? = 1 ]'

# A missing report exits 2 and is named.
mkdir -p "$W/partial"; cp "$W/perfect/lens-docs-01.md" "$W/partial/"
out="$(sc --reports "$W/partial" --lens docs 2>&1)"; r=$?
check "a missing report exits 2 and names a case" eval '[ "$r" = 2 ] && grep -q "report(s) missing" <<<"$out"'

# A report with no findings block exits 2.
mkdir -p "$W/bad"; for f in "$W"/perfect/lens-docs-*.md; do cp "$f" "$W/bad/"; done
echo "no block here" >"$W/bad/lens-docs-01.md"
out="$(sc --reports "$W/bad" --lens docs 2>&1)"; r=$?
check "a report with no findings block exits 2" eval '[ "$r" = 2 ] && grep -q "no findings block" <<<"$out"'

# An unknown lens matches nothing and exits 2.
check "an unknown lens exits 2" eval 'sc --reports "$W/perfect" --lens nonsense >/dev/null 2>&1; [ $? = 2 ]'

printf '%s\n' "${ROWS[@]}"
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
