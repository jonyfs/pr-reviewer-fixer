#!/usr/bin/env bash
# Tests golden.py on fixture cases, reports and judge files. No model is run, and nothing reaches the
# network: gh and curl on PATH are stubs that record any call, and a row checks that none was made.
# Prints a pass/fail table.
set -u
unset REVIEW_BLOCK_AT PUSH_GUARD_ALLOW_SENSITIVE
T="$(cd "$(dirname "$0")" && pwd)"
W="$T/work-${TEST_TAG:-main}"; rm -rf "$W"; mkdir -p "$W/bin"
G="${GOLDEN_PY:-$T/golden.py}"
PASS=0; FAIL=0; ROWS=()
row() { if [ "$2" = ok ]; then PASS=$((PASS+1)); ROWS+=("PASS | $1"); else FAIL=$((FAIL+1)); ROWS+=("FAIL | $1 ($3)"); fi; }
check() { local name="$1"; shift; if "$@"; then row "$name" ok; else row "$name" bad "assert failed"; fi; }
# Network stubs: any call is recorded in $W/net.log.
for b in gh curl wget; do printf '#!/bin/sh\necho "%s $*" >>"%s/net.log"\nexit 99\n' "$b" "$W" >"$W/bin/$b"; chmod +x "$W/bin/$b"; done
export PATH="$W/bin:$PATH"
g() { python3 -I "$G" "$@"; }
H1=1111111111111111111111111111111111111111; H2=2222222222222222222222222222222222222222
B0=0000000000000000000000000000000000000000

# ---- fixture cases ---------------------------------------------------------------------------------
C="$W/cases"; mkdir -p "$C"
mkcase() { # name pr expected-json
  jq -n --arg h "$H1" --arg b "$B0" --argjson pr "$2" --argjson e "$3" \
    '{schema:1, repo:"example/repo", pr:$pr, base:$b, head:$h, pass:1, expected:$e,
      validated_by:"none", validated_at:null, validated_digest:null}' >"$C/$1.json"; }
ex() { # id file start end dimension severity
  jq -n --arg id "$1" --arg f "$2" --argjson s "$3" --argjson e "$4" --arg d "$5" --arg v "$6" \
    '{id:$id, source_id:("W"+($id|ltrimstr("E"))), file:$f, lines:[$s,$e], dimension:$d, severity:$v,
      description:"A defect the reviewer confirmed fixed."}'; }
mkcase alpha 1 "[$(ex E1 src/a.py 10 12 security CRITICAL),$(ex E2 src/a.py 30 30 reliability WARNING)]"
mkcase beta 2 "[$(ex E1 src/b.sh 5 5 security WARNING)]"
mkcase gamma 3 "[$(ex E1 docs/c.md 1 4 docs NOTE)]"
mkcase delta 4 "[$(ex E1 src/d.py 7 7 reliability WARNING)]"
g mark-validated alpha --login some-person --date 2026-11-01 --cases "$C" >/dev/null; r1=$?
g mark-validated delta --login some-person --cases "$C" >/dev/null; r2=$?
check "mark-validated writes the login, the date and the digest" eval \
  '[ "$r1$r2" = 00 ] && jq -e ".validated_by == \"some-person\" and .validated_at == \"2026-11-01\" and (.validated_digest|length) == 64" "$C/alpha.json" >/dev/null'
check "an unvalidated case keeps validated_by none" eval 'jq -e ".validated_by == \"none\"" "$C/beta.json" >/dev/null'
out="$(g validate --cases "$C")"; r=$?
check "validate accepts the fixture cases, two of them validated" eval '[ "$r" = 0 ] && grep -q "4 case(s), 2 validated by a person, ok" <<<"$out"'
g mark-validated beta --login 'not a login' --cases "$C" >/dev/null 2>&1; r=$?
check "mark-validated refuses a login that is not a GitHub login" eval '[ "$r" = 2 ] && jq -e ".validated_by == \"none\"" "$C/beta.json" >/dev/null'

# ---- malformed cases are refused -------------------------------------------------------------------
bad() { # row-name jq-filter expected-message
  local d="$W/bad-$RANDOM$RANDOM"; mkdir -p "$d"; jq "$2" "$C/beta.json" >"$d/beta.json"
  local msg="$3" o; o="$(g validate --cases "$d" 2>&1)"; local rc=$?
  check "$1" eval '[ "$rc" = 1 ] && grep -qF -- "$msg" <<<"$o"'
}
bad "validate refuses a case with a missing key" 'del(.base)' "missing key(s) base"
bad "validate refuses a short head sha" '.head="abc1234"' "head must be a full 40-digit"
bad "validate refuses a draft (draft_claim is an unknown key)" '.expected[0].draft_claim="x"' "must have exactly the keys"
bad "validate refuses a draft's top-level fields" '.draft_fix_head="x"' "unknown key(s) draft_fix_head"
bad "validate refuses an empty description" '.expected[0].description=""' "description must be one printable line"
bad "validate refuses lines out of order" '.expected[0].lines=[9,3]' "lines must be [start, end]"
bad "validate refuses a path that climbs out" '.expected[0].file="../etc/x"' "repository-relative path"
bad "validate refuses an unknown severity" '.expected[0].severity="HIGH"' "severity must be"
d="$W/esc"; mkdir -p "$d"; jq '.expected[0].description="ok \u001b[31m red"' "$C/beta.json" >"$d/beta.json"
o="$(g validate --cases "$d" 2>&1)"; r=$?
check "a description with an ESC is refused, and no ESC reaches the terminal" eval '[ "$r" = 1 ] && ! grep -q $'"'"'\x1b'"'"' <<<"$o"'
d="$W/edited"; mkdir -p "$d"; jq '.expected[0].severity="WARNING"' "$C/alpha.json" >"$d/alpha.json"
o="$(g validate --cases "$d" 2>&1)"; r=$?
check "a validated case edited after validation is refused" eval '[ "$r" = 1 ] && grep -q "changed after some-person validated it" <<<"$o"'
check "the shipped cases are well formed" eval 'python3 -I "$G" validate >/dev/null'

# ---- a run -------------------------------------------------------------------------------------------
# rep <run> <case> [id:SEVERITY[:status]]...
rep() {
  local run="$1" c="$2"; shift 2
  local t; t="$(jq -r --arg c "$c" '.cases[$c]' "$W/$run/map.json")"
  { echo "## Review"; echo; echo '```findings'; echo "version: 1"; echo "findings:"
    local spec id s st
    for spec in "$@"; do IFS=: read -r id s st <<<"$spec"
      echo "  - id: $id"; echo "    severity: $s"; echo "    file: src/x.py"; echo "    line: 3"
      [ -z "${st:-}" ] || echo "    status: $st"; done
    echo '```'; } >"$W/$run/reports/$t.md"
}
# jud <run> <a|b> <case> <E:match>...
jud() {
  local run="$1" w="$2" c="$3"; shift 3
  local pr; pr="$(jq .pr "$C/$c.json")"
  local ms="[]" spec
  for spec in "$@"; do ms="$(jq --arg e "${spec%%:*}" --arg m "${spec#*:}" '. + [{expected:$e, matched:$m, reason:"same file and same defect"}]' <<<"$ms")"; done
  jq -n --arg c "$c" --argjson pr "$pr" --arg h "$H1" --arg w "$w" --argjson ms "$ms" \
    '{schema:1, case:$c, pr:$pr, head:$h, judge:$w, matches:$ms}' >"$W/$run/judge-$w/$c.json"
}
mkrun() {
  mkdir -p "$W/$1/reports" "$W/$1/judge-a" "$W/$1/judge-b"
  echo '{"schema":1,"cases":{"alpha":"r00000000a1","beta":"r00000000b2","gamma":"r00000000c3","delta":"r00000000d4"}}' >"$W/$1/map.json"
  rep "$1" alpha F1:CRITICAL F2:WARNING F3:WARNING F4:CRITICAL:verified
  rep "$1" beta W1:WARNING
  rep "$1" gamma
  rep "$1" delta N1:NOTE
  local w; for w in a b; do
    jud "$1" $w alpha E1:F1 E2:none; jud "$1" $w beta E1:W1; jud "$1" $w gamma E1:none; jud "$1" $w delta E1:N1
  done
}
sc() { g score --run "$W/$1" --cases "$C" "${@:2}"; }
mkrun agree
j="$(sc agree --json)"; r=$?
check "scoring: validated recall 2/3, unvalidated 1/2" eval \
  '[ "$r" = 0 ] && jq -e ".validated.all == {\"matched\":2,\"expected\":3,\"recall\":0.667} and .unvalidated.all == {\"matched\":1,\"expected\":2,\"recall\":0.5}" <<<"$j" >/dev/null'
check "scoring: recall per severity and per dimension" eval \
  'jq -e ".validated[\"severity:CRITICAL\"].recall == 1 and .validated[\"severity:WARNING\"].recall == 0.5 and .validated[\"dimension:reliability\"].recall == 0.5 and .unvalidated[\"dimension:docs\"].recall == 0" <<<"$j" >/dev/null'
check "scoring: unmatched report findings counted, a verified one is not" eval \
  'jq -e ".unmatched == {\"CRITICAL\":0,\"WARNING\":2,\"NOTE\":0,\"other\":0}" <<<"$j" >/dev/null'
check "scoring: a NOTE matched to a WARNING is counted as a lower severity" eval 'jq -e ".downgraded == 1" <<<"$j" >/dev/null'
check "judges that agree: agreement 1.0 over 5 expected findings" eval \
  'jq -e ".agreement.rate == 1 and .agreement.compared == 5 and (.agreement.disagreements|length) == 0" <<<"$j" >/dev/null'
t="$(sc agree)"
check "the table names unvalidated cases as candidates only" eval 'grep -q "unvalidated recall 0.5 (1/2)  CANDIDATES ONLY" <<<"$t" && grep -q "^validated recall 0.667 (2/3)$" <<<"$t"'
sc agree --min-recall 0.8 >/dev/null; r=$?
check "--min-recall on the validated cases unmet -> exit 1" eval '[ "$r" = 1 ]'
sc agree --min-recall 0.6 >/dev/null; r=$?
check "--min-recall met -> exit 0" eval '[ "$r" = 0 ]'

# the second judge's sample
s1="$(g sample --run "$W/agree" --cases "$C")"; s2="$(g sample --run "$W/agree" --cases "$C")"
check "sample: 3 of 4 cases (at least 3), the same each time" eval '[ "$(wc -l <<<"$s1" | tr -d " ")" = 3 ] && [ "$s1" = "$s2" ]'
d="$W/many"; mkdir -p "$d"; for i in $(seq 1 21); do cp "$C/beta.json" "$d/c$i.json"; done
s="$(g sample --run "$W/agree" --cases "$d")"
check "sample: 5 of 21 cases (20%, rounded up)" eval '[ "$(wc -l <<<"$s" | tr -d " ")" = 5 ]'

# a disagreement is flagged
mkrun disagree; jud disagree b beta E1:none
t="$(sc disagree)"; r=$?
check "judges that disagree: the finding is named and the exit is 1" eval \
  '[ "$r" = 1 ] && grep -q "^DISAGREEMENT beta E1: judge-a W1, judge-b none$" <<<"$t" && grep -q "judge agreement: 0.8 (4/5" <<<"$t"'

# a sampled case without the second judge is not scored
mkrun nob; first="$(g sample --run "$W/nob" --cases "$C" | head -n 1)"; rm -f "$W/nob/judge-b/$first.json"
o="$(sc nob 2>&1)"; r=$?
check "a sampled case with no second judge -> exit 2" eval '[ "$r" = 2 ] && grep -q "in the second judge.s sample and has no judge-b" <<<"$o"'
mkrun noa; rm -f "$W/noa/judge-a/gamma.json"; sc noa >/dev/null 2>&1; r=$?
check "a case with no primary judge -> exit 2" eval '[ "$r" = 2 ]'
mkrun norep; rm -f "$W/norep/reports/r00000000c3.md"; sc norep >/dev/null 2>&1; r=$?
check "a missing report -> exit 2" eval '[ "$r" = 2 ]'
mkrun noblock; printf 'no block\n' >"$W/noblock/reports/r00000000c3.md"; sc noblock >/dev/null 2>&1; r=$?
check "a report without a findings block -> exit 2" eval '[ "$r" = 2 ]'

# ---- strict judge JSON ----------------------------------------------------------------------------
jbad() { # row-name case jq-filter expected-message
  local run="jbad$RANDOM$RANDOM"; mkrun "$run"
  jq "$3" "$W/$run/judge-a/$2.json" >"$W/$run/x" && mv "$W/$run/x" "$W/$run/judge-a/$2.json"
  local msg="$4" o; o="$(sc "$run" 2>&1)"; local rc=$?
  check "$1" eval '[ "$rc" = 2 ] && grep -qF -- "$msg" <<<"$o"'
}
jbad "judge: an expected id the case does not have" beta '.matches += [{expected:"E9",matched:"none",reason:"x"}]' "names expected id 'E9'"
jbad "judge: an expected id left out" alpha '.matches |= .[:1]' "expected id(s) E2 are not judged"
jbad "judge: an expected id judged twice" beta '.matches += [.matches[0]]' "is judged twice"
jbad "judge: a matched id the report does not have" beta '.matches[0].matched="W7"' "is not a counted finding of the report"
jbad "judge: a matched id that is closed (verified) in the report" alpha '.matches[1].matched="F4"' "is not a counted finding"
jbad "judge: one report finding matched twice" alpha '.matches[1].matched="F1"' "is matched to both E1 and E2"
jbad "judge: an extra key" beta '.score=1' "exactly the keys"
jbad "judge: an extra key in a match" beta '.matches[0].confidence=0.9' "exactly the keys expected, matched, reason"
jbad "judge: matched null instead of \"none\"" beta '.matches[0].matched=null' "matched must be a report finding id or"
jbad "judge: a reason over two lines" beta '.matches[0].reason="one\ntwo"' "reason must be one printable line"
jbad "judge: an empty reason" beta '.matches[0].reason=""' "reason must be one printable line"
jbad "judge: another head" beta '.head="'"$H2"'"' "case, pr and head must be the case's own"
jbad "judge: the wrong judge letter" beta '.judge="b"' "judge must be 'a'"
run=jnotjson; mkrun $run; echo '{not json' >"$W/$run/judge-a/beta.json"; o="$(sc $run 2>&1)"; r=$?
check "judge: a file that is not JSON -> exit 2" eval '[ "$r" = 2 ] && grep -q "is not valid JSON" <<<"$o"'
run=jesc; mkrun $run; jq '.matches[0].matched="W1\u001b[2J"' "$W/$run/judge-a/beta.json" >"$W/$run/x" && mv "$W/$run/x" "$W/$run/judge-a/beta.json"
o="$(sc $run 2>&1)"; r=$?
check "judge: an ESC in a matched id is refused and not printed" eval '[ "$r" = 2 ] && ! grep -q $'"'"'\x1b'"'"' <<<"$o"'

# a malformed case stops the score
run=badcase; mkrun $run; d="$W/badcases"; cp -R "$C" "$d"; jq 'del(.repo)' "$C/gamma.json" >"$d/gamma.json"
o="$(g score --run "$W/$run" --cases "$d" 2>&1)"; r=$?
check "score refuses a malformed case -> exit 2" eval '[ "$r" = 2 ] && grep -q "case gamma: missing key(s) repo" <<<"$o"'

# ---- prepare's hunk check and --min-recall with nothing validated -----------------------------------
hk="$(python3 -I - "$G" <<'PY'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("g", sys.argv[1]); g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)
d = b"diff --git a/x.py b/x.py\n--- a/x.py\n+++ b/x.py\n@@ -1,2 +10,3 @@\n a\n+b\n c\n--- a/y.py\n+++ /dev/null\n@@ -1 +0,0 @@\n-z\n"
rng = g.hunks(d)
case = {"expected": [{"id": "E1", "file": "x.py", "lines": [12, 14]}, {"id": "E2", "file": "x.py", "lines": [13, 13]},
                     {"id": "E3", "file": "y.py", "lines": [1, 1]}, {"id": "E4", "file": "x.py", "lines": [8, 9]}]}
print(json.dumps({"rng": rng, "outside": [e["id"] for e in g.outside(case, rng)]}))
PY
)"
jv="$(python3 -I - "$G" "$C/alpha.json" <<'PY'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("g", sys.argv[1]); g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)
c = json.load(open(sys.argv[2])); v = g.judge_view(c)
print(json.dumps({"view": v, "case_kept": "source_id" in c["expected"][0]}))
PY
)"
check "prepare's judge copy drops source_id and keeps every other field" eval \
  'jq -e "(.view.expected | map(has(\"source_id\")) | any | not) and .case_kept and (.view.expected[0] | keys) == [\"description\",\"dimension\",\"file\",\"id\",\"lines\",\"severity\"] and .view.pr == 1" <<<"$jv" >/dev/null'
check "prepare's hunk reader: new-file ranges, deleted files left out" eval 'jq -e ".rng == {\"x.py\": [[10, 12]]}" <<<"$hk" >/dev/null'
check "prepare refuses expected lines outside the diff, keeps overlapping ones" eval 'jq -e ".outside == [\"E2\",\"E3\",\"E4\"]" <<<"$hk" >/dev/null'
d="$W/nonevalidated"; mkdir -p "$d"; cp "$C/beta.json" "$C/gamma.json" "$d/"
mkdir -p "$W/nv/reports" "$W/nv/judge-a" "$W/nv/judge-b"
echo '{"schema":1,"cases":{"beta":"r00000000b2","gamma":"r00000000c3"}}' >"$W/nv/map.json"
rep nv beta W1:WARNING; rep nv gamma
for w in a b; do jud nv $w beta E1:W1; jud nv $w gamma E1:none; done
g score --run "$W/nv" --cases "$d" --min-recall 0.1 >/dev/null; r=$?
check "--min-recall with no validated case -> exit 1 (unvalidated cases never meet it)" eval '[ "$r" = 1 ]'

# ---- build-cases.py selection, on a fixture pull request (no gh call) ------------------------------
cat >"$W/sel.py" <<'PY'
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location("bc", sys.argv[1]); bc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bc)
gate = bc.load_gate()
O = "<" "!--"
def verdict(p, v, sha, ents):
    lines = ["%s adversarial-review: sha=%s verdict=%s pass=%d -->" % (O, sha, v, p), "", "## Review", "",
             "```findings", "version: 1", "findings:"]
    for fid, f, ln, dim, st in ents:
        lines += ["  - id: " + fid, "    severity: WARNING", "    file: " + f, "    line: " + ln,
                  "    dimension: " + dim, "    claim: something is wrong"] + (["    status: " + st] if st else [])
    return "\n".join(lines + ["```"])
def closure(c, who="trusted-one"):
    return {"author": {"login": who}, "body": "%s pr-fixer-closure: cycle=%d head=%s closed=1 refused=0 debt=0 -->" % (O, c, "b" * 40)}
A = "a" * 40
def pr(**kw):
    p1 = {"author": {"login": "trusted-one"}, "createdAt": "2026-11-01T00:00:00Z",
          "body": verdict(1, "BLOCKED", A, [("W1", "src/a.sh", "10-12", "security", ""), ("W2", "src/b.sh", "5", "testing", ""),
                                             ("W3", "src/c.sh", "3", "reliability", "")])}
    p2 = {"author": {"login": "trusted-one"}, "createdAt": "2026-11-02T00:00:00Z",
          "body": verdict(2, "PASSED", "c" * 40, [("W1", "src/a.sh", "11", "security", "verified"),
                                                  ("W2", "src/d.sh", "5", "testing", "verified"),
                                                  ("W3", "src/c.sh", "3", "reliability", "open"),
                                                  ("W4", "src/e.sh", "1", "security", "verified")])}
    d = {"state": "MERGED", "comments": [p1, kw.get("closure", closure(1)), p2], "editedComments": [], "deletedComments": []}
    d.update(kw.get("extra", {}))
    return d
os.environ["REVIEW_MARKER_AUTHORS"] = "trusted-one"
out = {}
sel, why = bc.select(pr(), gate)
out["ok"] = {"first": sel[0], "ids": [c["source_id"] for c in sel[2]], "lines": sel[2][0]["lines"], "dropped": sel[3],
             "fix_head": sel[2][0]["draft_fix_head"]}
out["untrusted_closure"] = bc.select(pr(closure=closure(1, "someone-else")), gate)[1]
out["not_merged"] = bc.select(pr(extra={"state": "OPEN"}), gate)[1]
out["edited"] = bc.select(pr(extra={"editedComments": [{"author": {"login": "trusted-one"}, "editor": {"login": "trusted-one"},
                                                         "body": O + " adversarial-review: sha=%s verdict=PASSED pass=3 -->" % A}]}), gate)[1]
# A trusted comment that is not a marker, edited or deleted: by its author it is kept, by another login
# the pull request is skipped.
def ed(editor):
    return {"editedComments": [{"author": {"login": "trusted-one"}, "editor": {"login": editor}, "body": "a plain comment"}]}
def de(actor):
    return {"deletedComments": [{"author": {"login": "trusted-one"}, "actor": {"login": actor}, "body": None}]}
out["foreign_edit"] = bc.select(pr(extra=ed("someone-else")), gate)[1]
out["own_edit"] = bc.select(pr(extra=ed("trusted-one")), gate)[1]
out["foreign_delete"] = bc.select(pr(extra=de("someone-else")), gate)[1]
out["own_delete"] = bc.select(pr(extra=de("trusted-one")), gate)[1]
print(json.dumps(out))
PY
sel="$(python3 -I "$W/sel.py" "$T/build-cases.py" 2>&1)"
check "build-cases: only a first-pass finding verified after a trusted closure is a candidate" eval \
  'jq -e ".ok.first == 1 and .ok.ids == [\"W1\"] and .ok.lines == [10,12] and .ok.fix_head == \"$(printf b%.0s {1..40})\"" <<<"$sel" >/dev/null'
check "build-cases: an id verified at another file is dropped and named" eval 'jq -e ".ok.dropped == [\"W2\"]" <<<"$sel" >/dev/null'
check "build-cases: a closure by an untrusted login does not count" eval 'jq -e ".untrusted_closure | startswith(\"no first-pass finding\")" <<<"$sel" >/dev/null'
check "build-cases: a pull request that is not merged is skipped" eval 'jq -e ".not_merged == \"not merged\"" <<<"$sel" >/dev/null'
check "build-cases: an edited trusted marker skips the pull request" eval 'jq -e ".edited | startswith(\"a trusted marker comment was edited\")" <<<"$sel" >/dev/null'
check "build-cases: a trusted comment edited by another login skips the pull request" eval \
  'jq -e ".foreign_edit == \"a trusted marker comment was edited, or a trusted comment was edited by someone else\" and .own_edit == null" <<<"$sel" >/dev/null'
check "build-cases: a trusted comment deleted by another login skips the pull request" eval \
  'jq -e ".foreign_delete == \"a trusted comment was deleted by someone other than its author\" and .own_delete == null" <<<"$sel" >/dev/null'

# ---- build-cases.py base: a stale local origin/<base> ref (git only; the origin is a local bare repo) --
GD="$W/git"; mkdir -p "$GD"
gt() { git -c user.name=golden -c user.email=golden@example.invalid -c commit.gpgsign=false \
         -c core.hooksPath=/dev/null -c init.defaultBranch=main "$@"; }
mk() { GIT_AUTHOR_DATE="$2" GIT_COMMITTER_DATE="$2" gt -C "$1" commit -q --allow-empty -m "$3"; } # repo date message
gt init -q --bare "$GD/origin.git"; gt init -q "$GD/src"
mk "$GD/src" 2026-10-01T00:00:00Z c1; mk "$GD/src" 2026-10-02T00:00:00Z c2
gt -C "$GD/src" push -q "$GD/origin.git" HEAD:refs/heads/main
gt clone -q "$GD/origin.git" "$GD/clone" 2>/dev/null      # the clone's origin/main stops at c2
STALE="$(git -C "$GD/src" rev-parse HEAD)"
mk "$GD/src" 2026-10-03T00:00:00Z c3; mk "$GD/src" 2026-10-04T00:00:00Z c4; FORK="$(git -C "$GD/src" rev-parse HEAD)"
gt -C "$GD/src" checkout -q -b feat; mk "$GD/src" 2026-10-05T00:00:00Z p1; P1="$(git -C "$GD/src" rev-parse HEAD)"
gt -C "$GD/src" checkout -q main; mk "$GD/src" 2026-11-05T00:00:00Z c5   # after the verdict
gt -C "$GD/src" push -q "$GD/origin.git" main feat
gt -C "$GD/clone" fetch -q origin "+refs/heads/feat:refs/remotes/origin/feat"
cat >"$W/base.py" <<'PY'
import importlib.util, json, subprocess, sys
spec = importlib.util.spec_from_file_location("bc", sys.argv[1]); bc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bc)
clone, stale, fork, p1 = sys.argv[2:6]
at = "2026-11-01T00:00:00Z"
out = {"stale_ref": bc.base_of(clone, "main", stale, p1, at, [p1])}
subprocess.run(("git", "-C", clone, "update-ref", "refs/remotes/origin/main", stale), check=True)
subprocess.run(("git", "-C", clone, "remote", "set-url", "origin", clone + "-gone.git"), check=True)
out["unreachable"] = bc.base_of(clone, "main", stale, p1, at, [p1])
out["head_not_listed"] = bc.base_of(clone, "main", fork, p1, at, ["0" * 40])
print(json.dumps(out))
PY
bo="$(python3 -I "$W/base.py" "$T/build-cases.py" "$GD/clone" "$STALE" "$FORK" "$P1" 2>&1)"
check "build-cases: a stale local origin/main is fetched first, so the base is the fork point" eval \
  'jq -e --arg f "$FORK" ".stale_ref == [\$f, null]" <<<"$bo" >/dev/null'
check "build-cases: a base whose base..head count differs from the pull request's commits is refused" eval \
  'jq -e ".unreachable[0] == null and (.unreachable[1] | contains(\"3 commit(s)\") and contains(\"has 1 up to the first-pass head\"))" <<<"$bo" >/dev/null'
check "build-cases: a first-pass head that is not among the pull request's commits is refused" eval \
  'jq -e ".head_not_listed[0] == null and (.head_not_listed[1] | test(\"not among the pull request.s commits\"))" <<<"$bo" >/dev/null'

# ---- no network --------------------------------------------------------------------------------------
check "no gh, curl or wget was called by any row" eval '[ ! -e "$W/net.log" ]'
check "golden.py imports no network module" eval '! grep -nE "^\s*(import|from)\s.*\b(socket|urllib|http|requests|ssl)\b" "$G"'

printf '%s\n' "${ROWS[@]}"
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
