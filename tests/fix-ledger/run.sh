#!/usr/bin/env bash
# Drives fix-ledger.sh against a fake gh (tests/fix-ledger/bin/gh) and a scratch git repository
# whose commits the fake pull requests name. Prints a pass/fail table. No network.
#
# The pull requests (trusted login rev-bot, untrusted mallory):
#   1  kept:       pass 1 BLOCKED, fixer cycle 1 (one commit), pass 2 PASSED.
#   2  undone:     fixer cycle 1 has two commits; a person reverts the first (git revert) and
#                  rewrites the lines of the second; pass 2 raises one new WARNING.
#   3  refusals:   cycle 1 closes C1, refuses C2, C4 and C5 and escalates C6; pass 2 rejects the
#                  refusal of C2, accepts C4 and C5 and raises a new CRITICAL; a person then changes
#                  the line C4 cites. False refusals: C2 (re-raised) and C4 (fixed by a person).
#   4  untrusted:  mallory posts a closure and a PASSED verdict that would make her commit a fixer one.
#   5  edited:     rev-bot's cycle-1 closure was edited, so pr-json.py drops it and the row is
#                  incomplete; cycle 2 still has a fixer commit a person overwrote, which must stay
#                  out of every rate.
#   6  two cycles: cycle 1 only refuses C1 (no commit), cycle 2 fixes C2 in "h q.sql"; pass 3 still
#                  lists C1 as refused-accepted. A person's commit deletes a line reading
#                  `-- header` (which a -U0 diff prints as `--- header`) and rewrites the fix.
set -u
# A caller's REVIEW_BLOCK_AT or PUSH_GUARD_ALLOW_SENSITIVE would change what is refused.
unset REVIEW_BLOCK_AT PUSH_GUARD_ALLOW_SENSITIVE
T="$(cd "$(dirname "$0")" && pwd)"
SRC="$(cd "${1:-$T/../../.agents/skills/pr-fixer/scripts}" && pwd)"
FL="$SRC/fix-ledger.sh"
W="$T/work-${TEST_TAG:-main}"
rm -rf "$W"; mkdir -p "$W/gh"
export PATH="$T/bin:$PATH" FAKE_DIR="$W/gh" XDG_DATA_HOME="$W/xdg" REVIEW_MARKER_AUTHORS=rev-bot
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com \
  GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
: >"$FAKE_DIR/calls.log"
PASS=0; FAIL=0; ROWS=()
row() { if [ "$2" = ok ]; then PASS=$((PASS+1)); ROWS+=("PASS | $1"); else FAIL=$((FAIL+1)); ROWS+=("FAIL | $1 ($3)"); fi; }

# ---- the scratch repository ----------------------------------------------------------------------
R="$W/repo"
git init -q "$R" && cd "$R" || { echo "cannot make the scratch repository"; exit 1; }
git checkout -q -b main
for i in 1 2 3 4 5 6 7 8 9 10; do echo "line $i"; done >f.txt
for i in 1 2 3 4 5 6 7 8 9 10; do echo "g $i"; done >g.txt
git add f.txt g.txt && git commit -qm base
setl() { python3 -I -c 'import sys
p, n, t = sys.argv[1], int(sys.argv[2]), sys.argv[3]
L = open(p).read().split("\n"); L[n - 1] = t; open(p, "w").write("\n".join(L))' "$@"; }
ci() { git commit -qam "$1" && git rev-parse HEAD; }
git checkout -q -b p1 main
A1=$(setl f.txt 2 bug2 && ci "author: work")
F1=$(setl f.txt 2 fixed2 && ci "fix C1")
git checkout -q -b p2 main
A2=$(setl f.txt 3 bug3 && ci "author: work")
F2A=$(setl f.txt 3 fix3 && ci "fix C1")
F2B=$(setl g.txt 5 $'fix5\nfix5b' && ci "fix C2")
git revert --no-edit "$F2A" >/dev/null && H2A=$(git rev-parse HEAD)
H2B=$(setl g.txt 5 human5 && setl g.txt 6 human5b && ci "person: rewrite")
git checkout -q -b p3 main
A3=$(setl f.txt 4 bug4 && setl g.txt 2 maybe2 && ci "author: work")
F3=$(setl f.txt 4 fix4 && ci "fix C1")
H3=$(setl g.txt 2 really2 && ci "person: g line 2")
git checkout -q -b p4 main
A4=$(setl f.txt 5 bug5 && ci "author: work")
M4=$(setl f.txt 5 mal5 && ci "mallory")
git checkout -q -b p5 main
A5=$(setl f.txt 6 bug6 && ci "author: work")
F5=$(setl f.txt 6 fix6 && ci "fix C1")
F5B=$(setl f.txt 7 fix7 && ci "fix C2")
H5=$(setl f.txt 7 person7 && ci "person")
git checkout -q -b p6 main
A6=$(printf -- '-- header\na\nb\nc\n' >"h q.sql" && git add "h q.sql" && ci "author: sql")
F6=$(setl "h q.sql" 4 "fixed c" && ci "fix C2")
H6=$(printf 'a\nb\nperson c\n' >"h q.sql" && ci "person: sql")
git checkout -q -b p12 main
A12=$(setl f.txt 8 bug8 && ci "author: work")
F12=$(setl f.txt 8 $'fix8\nfix8b' && ci "fix C1")
H12=$(setl f.txt 8 person8 && ci "person: one of the two lines")
git checkout -q -b s13a main
setl g.txt 3 side3 && git commit -qam "side a"
git checkout -q -b s13b main
setl g.txt 7 side7 && git commit -qam "side b"
git checkout -q -b p13 main
A13=$(setl f.txt 9 bug9 && ci "author: work")
git merge -q --no-ff --no-edit s13a >/dev/null && M13A=$(git rev-parse HEAD)
F13=$(setl f.txt 9 fix9 && ci "fix C1")
git merge -q --no-ff --no-commit s13b >/dev/null 2>&1; setl f.txt 9 evil9 && git add f.txt \
  && git commit -qm "person: merge b, rewriting line 9 in the merge" && M13B=$(git rev-parse HEAD)
git checkout -q main
export A1 F1 A2 F2A F2B H2A H2B A3 F3 H3 A4 M4 A5 F5 F5B H5 A6 F6 H6 A12 F12 H12 A13 M13A F13 M13B
for v in A1 F1 A2 F2A F2B H2A H2B A3 F3 H3 A4 M4 A5 F5 F5B H5 A6 F6 H6 A12 F12 H12 A13 M13A F13 M13B; do
  [ -n "${!v}" ] || { echo "the scratch repository is missing commit $v"; exit 1; }
done

# ---- the fake pull requests ----------------------------------------------------------------------
python3 -I - "$FAKE_DIR" <<'PY'
import json, os, sys
d, E = sys.argv[1], os.environ
O = "<" + "!-- "


def verdict(who, sha, v, p, entries, c=0, w=0):
    block = "".join("  - id: %s\n    severity: %s\n    status: %s\n    file: %s\n    line: %d\n    claim: \"x\"\n" % e
                    for e in entries)
    return {"author": {"login": who},
            "body": O + "adversarial-review: sha=%s verdict=%s pass=%d critical=%d warning=%d note=0 -->\n"
                    "Written by pr-reviewer, pass %d.\n\n```findings\nversion: 1\npass: %d\nverdict: %s\n"
                    "counts: {critical: %d, warning: %d, note: 0}\nfindings:\n%s```\n" % (sha, v, p, c, w, p, p, v, c, w, block)}


def closure(who, c, head, closed, refused, debt, lines=""):
    return {"author": {"login": who},
            "body": O + "pr-fixer-closure: cycle=%d head=%s closed=%d refused=%d debt=%d -->\n"
                    "Written by pr-fixer, cycle %d.\n\n%s" % (c, head[:12], closed, refused, debt, c, lines)}


def status(who):
    return {"author": {"login": who}, "body": O + "pr-skill-status: skill=pr-fixer run=1 head=abc state=finished -->\nfinished"}


def pr(n, commits, comments, state="MERGED", edited=None, deleted=None):
    obj = {"number": n, "state": state, "isDraft": False, "title": "t", "body": "", "author": {"login": "alice"},
           "isCrossRepository": False, "labels": [], "headRefOid": commits[-1], "commits": [{"oid": x} for x in commits],
           "mergeCommit": {"oid": "f" * 40} if state == "MERGED" else None,
           "mergedAt": "2026-11-05T00:00:00Z" if state == "MERGED" else None, "comments": comments}
    for i, c in enumerate(comments):
        c["id"] = "IC_%d_%d" % (n, i)
    obj["edited"] = {"IC_%d_%d" % (n, i): who for i, who in (edited or {}).items()}
    obj["deleted"] = deleted or []
    json.dump(obj, open(os.path.join(d, "pr-%d.json" % n), "w"))


C1 = ("C1", "CRITICAL", "open", "f.txt", 2)
pr(1, [E["A1"], E["F1"]], [
    verdict("rev-bot", E["A1"], "BLOCKED", 1, [C1], c=1),
    status("rev-bot"),
    closure("rev-bot", 1, E["F1"], 1, 0, 1, "C1 closed: fixed.\n"),
    verdict("rev-bot", E["F1"], "PASSED", 2, [("C1", "CRITICAL", "verified", "f.txt", 2)])],
   edited={1: "rev-bot"})  # the status comment, edited in place by its author: not a trust problem
pr(2, [E["A2"], E["F2A"], E["F2B"], E["H2A"], E["H2B"]], [
    verdict("rev-bot", E["A2"], "BLOCKED", 1, [("C1", "CRITICAL", "open", "f.txt", 3), ("C2", "CRITICAL", "open", "g.txt", 5)], c=2),
    closure("rev-bot", 1, E["F2B"], 2, 0, 0),
    verdict("rev-bot", E["F2B"], "PASSED", 2, [("C1", "CRITICAL", "verified", "f.txt", 3), ("C2", "CRITICAL", "verified", "g.txt", 5),
                                              ("W3", "WARNING", "open", "g.txt", 1)], w=1)])
pr(3, [E["A3"], E["F3"], E["H3"]], [
    verdict("rev-bot", E["A3"], "BLOCKED", 1, [("C1", "CRITICAL", "open", "f.txt", 4), ("C2", "CRITICAL", "open", "f.txt", 7),
                                              ("C4", "CRITICAL", "open", "g.txt", 2), ("C5", "CRITICAL", "open", "g.txt", 8),
                                              ("C6", "CRITICAL", "open", "f.txt", 9)], c=5),
    closure("rev-bot", 1, E["F3"], 1, 3, 0, "C1 closed: fixed.\nC2 refused: does not reproduce.\n"
            "C4 refused: does not reproduce.\nC5 refused: does not reproduce.\nC6 escalated: a person decides.\n"),
    verdict("rev-bot", E["F3"], "BLOCKED", 2, [("C1", "CRITICAL", "verified", "f.txt", 4), ("C2", "CRITICAL", "refused-rejected", "f.txt", 7),
                                              ("C4", "CRITICAL", "refused-accepted", "g.txt", 2), ("C5", "CRITICAL", "refused-accepted", "g.txt", 8),
                                              ("C6", "CRITICAL", "open", "f.txt", 9), ("C7", "CRITICAL", "open", "f.txt", 1)], c=3)],
   state="OPEN")
pr(4, [E["A4"], E["M4"]], [
    verdict("rev-bot", E["A4"], "BLOCKED", 1, [("C1", "CRITICAL", "open", "f.txt", 5)], c=1),
    closure("mallory", 1, E["M4"], 5, 0, 0),
    verdict("mallory", E["M4"], "PASSED", 2, [])])
pr(5, [E["A5"], E["F5"], E["F5B"], E["H5"]], [
    verdict("rev-bot", E["A5"], "BLOCKED", 1, [("C1", "CRITICAL", "open", "f.txt", 6)], c=1),
    closure("rev-bot", 1, E["F5"], 1, 0, 0),
    verdict("rev-bot", E["F5"], "BLOCKED", 2, [("C1", "CRITICAL", "verified", "f.txt", 6), ("C2", "CRITICAL", "open", "f.txt", 7)], c=1),
    closure("rev-bot", 2, E["F5B"], 1, 0, 2),
    verdict("rev-bot", E["F5B"], "PASSED", 3, [("C2", "CRITICAL", "verified", "f.txt", 7)])],
   edited={1: "rev-bot"})
Q = "h q.sql"
pr(6, [E["A6"], E["F6"], E["H6"]], [
    verdict("rev-bot", E["A6"], "BLOCKED", 1, [("C1", "CRITICAL", "open", Q, 2), ("C2", "CRITICAL", "open", Q, 4)], c=2),
    closure("rev-bot", 1, E["A6"], 0, 1, 0, "C1 refused: does not reproduce.\n"),
    verdict("rev-bot", E["A6"], "BLOCKED", 2, [("C1", "CRITICAL", "refused-accepted", Q, 2), ("C2", "CRITICAL", "open", Q, 4)], c=1),
    closure("rev-bot", 2, E["F6"], 1, 0, 0, "C2 closed: fixed.\n"),
    verdict("rev-bot", E["F6"], "PASSED", 3, [("C1", "CRITICAL", "refused-accepted", Q, 2), ("C2", "CRITICAL", "verified", Q, 4)])])
json.dump([{"number": 1}, {"number": 2}], open(os.path.join(d, "list.json"), "w"))


# PRs 7 to 10 are PR 1 with one trust event each; every one of them must change the row on its own.
def one():
    return [verdict("rev-bot", E["A1"], "BLOCKED", 1, [C1], c=1), status("rev-bot"),
            closure("rev-bot", 1, E["F1"], 1, 0, 1, "C1 closed: fixed.\n"),
            verdict("rev-bot", E["F1"], "PASSED", 2, [("C1", "CRITICAL", "verified", "f.txt", 2)])]


pr(7, [E["A1"], E["F1"]], one(),  # one trusted comment deleted by another login, one by its own author
   deleted=[{"author": "rev-bot", "actor": "mallory"}, {"author": "rev-bot", "actor": "rev-bot"}])
pr(8, [E["A1"], E["F1"]], one(), edited={1: "mallory"})  # a trusted comment with no marker, edited by another login
pr(9, [E["A1"], E["F1"]], one(), edited={3: "rev-bot"})  # the last verdict, edited by its own author
quoted = closure("rev-bot", 1, E["F1"], 9, 9, 9)  # a trusted comment quoting a closure after its first line
pr(10, [E["A1"], E["F1"]], one() + [{"author": {"login": "rev-bot"}, "body": "Quoting it:\n" + quoted["body"]}])
pr(11, [E["A1"]], [verdict("rev-bot", E["A1"], "BLOCKED", 1, [C1], c=1),  # refused, no pass 2 yet
                   closure("rev-bot", 1, E["A1"], 0, 1, 0, "C1 refused: does not reproduce.\n")], state="OPEN")
pr(12, [E["A12"], E["F12"], E["H12"]], [
    verdict("rev-bot", E["A12"], "BLOCKED", 1, [("C1", "CRITICAL", "open", "f.txt", 8)], c=1),
    closure("rev-bot", 1, E["F12"], 1, 0, 0),
    verdict("rev-bot", E["F12"], "BLOCKED", 2, [("C1", "CRITICAL", "verified", "f.txt", 8),
                                               ("W8", "WARNING", "open", "f.txt", 1), ("W9", "WARNING", "verified", "f.txt", 1)], w=1)])
pr(13, [E["A13"], E["M13A"], E["F13"], E["M13B"]], [
    verdict("rev-bot", E["A13"], "BLOCKED", 1, [("C1", "CRITICAL", "open", "f.txt", 9)], c=1),
    closure("rev-bot", 1, E["F13"], 1, 0, 0),
    verdict("rev-bot", E["F13"], "PASSED", 2, [("C1", "CRITICAL", "verified", "f.txt", 9)])])
PY

# ---- rows ----------------------------------------------------------------------------------------
L="$W/ledger.jsonl"
# q <name> <pr> <jq boolean over that PR's newest ledger row>
q() {
  local got
  got=$(jq -c --argjson n "$2" 'select(.pr == $n)' "$L" 2>/dev/null | tail -n 1)
  if [ -n "$got" ] && printf '%s' "$got" | jq -e "$3" >/dev/null 2>&1; then row "$1" ok; else row "$1" bad "row: ${got:0:400}"; fi
}
has() { case "$3" in *"$2"*) row "$1" ok ;; *) row "$1" bad "no '$2' in: ${3:0:400}" ;; esac; }

out=$(env -u REVIEW_MARKER_AUTHORS bash "$FL" --prs 1 --ledger "$L" 2>&1); rc=$?
[ "$rc" = 2 ] && [ ! -e "$L" ] && row "no REVIEW_MARKER_AUTHORS: refused (exit 2), no ledger written" ok \
  || row "no REVIEW_MARKER_AUTHORS: refused (exit 2), no ledger written" bad "exit $rc: $out"
out=$(REVIEW_MARKER_AUTHORS=' , ' bash "$FL" --prs 1 --ledger "$L" 2>&1); rc=$?
[ "$rc" = 2 ] && [ ! -e "$L" ] && row "a list naming no login: refused (exit 2)" ok || row "a list naming no login: refused (exit 2)" bad "exit $rc: $out"

out=$(bash "$FL" --prs 1,2,3,4,5 --ledger "$L" 2>&1); rc=$?
[ "$rc" = 0 ] && row "record 1-5: exit 0" ok || row "record 1-5: exit 0" bad "exit $rc: $out"
[ "$(wc -l <"$L" 2>/dev/null | tr -d ' ')" = 5 ] && row "record 1-5: one ledger line per pull request" ok \
  || row "record 1-5: one ledger line per pull request" bad "$(wc -l <"$L" 2>&1)"
q "PR 1: the fixer commit of cycle 1 is kept" 1 '.complete and .commits == {"kept":1,"overwritten":0,"reverted":0,"unknown":0} and .fixer_commits[0].sha == "'"$F1"'"'
q "PR 1: closed 1, refused 0, debt 1; nothing new after the cycle" 1 '.findings == {"closed":1,"refused":0,"escalated":0,"debt":1} and .cycles[0].new_critical == 0 and .cycles[0].new_warning == 0'
q "PR 1: a status comment its author edited leaves the row complete" 1 '.complete and .ignored.edited_trusted == 0'
q "PR 2: both commits of cycle 1 are the fixer's, the person's are not" 2 '[.fixer_commits[].sha] == ["'"$F2A"'","'"$F2B"'"]'
q "PR 2: a git revert of a fixer commit counts as reverted" 2 '.fixer_commits[0].status == "reverted"'
q "PR 2: a person rewriting the fixer's lines counts as overwritten" 2 '.fixer_commits[1].status == "overwritten" and .fixer_commits[1].lines_overwritten == 2'
q "PR 2: the new WARNING on pass 2 is counted" 2 '.cycles[0].new_warning == 1 and .cycles[0].new_critical == 0'
q "PR 3: refused, escalated and the new CRITICAL after the cycle" 3 '.findings.refused == 3 and .findings.escalated == 1 and .cycles[0].new_critical == 1'
q "PR 3: a refusal the reviewer rejected is re-raised at pass 2" 3 '(.refused_findings[] | select(.id == "C2")) | .reraised_at_pass == 2 and .false_refusal'
q "PR 3: a refusal a person later fixed on the cited line is false" 3 '(.refused_findings[] | select(.id == "C4")) | .human_fix == "'"$H3"'" and .false_refusal and .reraised_at_pass == null'
q "PR 3: an accepted refusal nobody touched holds" 3 '(.refused_findings[] | select(.id == "C5")) | .false_refusal == false'
q "PR 4: markers by an untrusted login make no cycle and no fixer commit" 4 '.complete and .cycles == [] and .fixer_commits == [] and .findings.closed == 0 and .ignored.untrusted_markers == 2'
q "PR 5: an edited trusted closure is ignored and the row is incomplete" 5 '(.complete | not) and [.cycles[].cycle] == [2] and .ignored.edited_trusted == 1 and .fixer_commits == [{"sha":"'"$F5B"'","cycle":2,"lines_added":1,"lines_overwritten":1,"status":"overwritten"}]'
out6=$(bash "$FL" --prs 6 --ledger "$W/six.jsonl" 2>&1)
six=$(tail -n 1 "$W/six.jsonl" 2>/dev/null)
printf '%s' "$six" | jq -e '[.cycles[] | [.cycle, (.fixer_commits | length)]] == [[1,0],[2,1]]' >/dev/null 2>&1 \
  && row "PR 6: a refuse-only cycle has no commit; the next cycle has its own" ok || row "PR 6: a refuse-only cycle has no commit; the next cycle has its own" bad "${six:0:400} $out6"
printf '%s' "$six" | jq -e '.fixer_commits[0].status == "overwritten"' >/dev/null 2>&1 \
  && row "PR 6: a removed line reading -- header and a path with a space do not hide an overwrite" ok \
  || row "PR 6: a removed line reading -- header and a path with a space do not hide an overwrite" bad "${six:0:400}"
printf '%s' "$six" | jq -e '[.refused_findings[] | [.id, .cycle]] == [["C1",1]]' >/dev/null 2>&1 \
  && row "PR 6: a refusal carried forward on a later pass is counted once" ok || row "PR 6: a refusal carried forward on a later pass is counted once" bad "${six:0:400}"
has "summary: accepted-fix rate over the complete rows" "accepted-fix rate: 2/4 (50.0%)" "$out"
has "summary: commit counts" "fixer commits: 4 (kept 2, overwritten 1, reverted 1, unknown 0)" "$out"
has "summary: findings totals" "findings: closed 4, refused 3, escalated 1, debt 1" "$out"
has "summary: new findings after a cycle" "new after a fix cycle: critical 1, warning 1, over 3 cycle(s) measured" "$out"
has "summary: the incomplete row is named and left out" "#5 left out" "$out"
if grep -q 'pr-fixer-closure\|does not reproduce\|claim' "$L"; then row "ledger holds parsed fields only, no comment text" bad "$(head -c 300 "$L")"
else row "ledger holds parsed fields only, no comment text" ok; fi

cp "$L" "$W/first.jsonl"; size=$(wc -c <"$L" | tr -d ' ')
out=$(bash "$FL" --prs 1,2,3,4,5 --ledger "$L" 2>&1)
if [ "$(wc -l <"$L" | tr -d ' ')" = 10 ] && [ "$(head -c "$size" "$L" | cmp - "$W/first.jsonl" && echo same)" = same ]; then
  row "append-only: a second run adds lines and leaves the first bytes as they were" ok
else row "append-only: a second run adds lines and leaves the first bytes as they were" bad "$(wc -l <"$L")"; fi
out=$(bash "$FL" summary --ledger "$L" 2>&1)
has "summary from the ledger takes the newest line per pull request" "fixer commits: 4 (kept 2, overwritten 1, reverted 1, unknown 0)" "$out"
out=$(bash "$FL" summary --ledger "$L" --prs 4 2>&1)
has "a summary with no fixer commit prints n/a, not a division" "accepted-fix rate: n/a" "$out"

out=$(bash "$FL" audit --ledger "$L" 2>&1); rc=$?
has "audit: false-refusal rate" "false-refusal rate: 2/3 (66.7%)" "$out"
has "audit: names the re-raised refusal" "#3 C2 (cycle 1, f.txt:7): false refusal: re-raised as open at pass 2" "$out"
has "audit: names the person's later fix" "#3 C4 (cycle 1, g.txt:2): false refusal: a later commit ${H3:0:7} changed the cited line" "$out"
has "audit: an untouched refusal holds" "#3 C5 (cycle 1, g.txt:8): held" "$out"
out=$(bash "$FL" audit --ledger "$L" --sample 1 --seed 7 2>&1)
has "audit --sample 1 samples one" "3 refused finding(s) in 4 complete pull request(s), 1 sampled (seed 7)" "$out"

out=$(bash "$FL" --prs 1 --ledger "$R/ledger.jsonl" 2>&1); rc=$?
[ "$rc" = 2 ] && [ ! -e "$R/ledger.jsonl" ] && row "a ledger inside the repository is refused" ok || row "a ledger inside the repository is refused" bad "exit $rc: $out"
out=$(bash "$FL" --prs 1 --ledger "$R/ledger.jsonl" --allow-in-repo 2>&1); rc=$?
[ "$rc" = 0 ] && [ -s "$R/ledger.jsonl" ] && row "--allow-in-repo writes it there" ok || row "--allow-in-repo writes it there" bad "exit $rc: $out"
out=$(bash "$FL" --prs 1 2>&1); rc=$?
[ "$rc" = 0 ] && [ -s "$XDG_DATA_HOME/pr-reviewer-fixer/fix-ledger.jsonl" ] && row "default ledger is under the user's data folder" ok \
  || row "default ledger is under the user's data folder" bad "exit $rc: $out"

: >"$FAKE_DIR/calls.log"
out=$(bash "$FL" --since 2026-11-01 --ledger "$W/since.jsonl" 2>&1); rc=$?
if [ "$rc" = 0 ] && [ "$(wc -l <"$W/since.jsonl" | tr -d ' ')" = 2 ] && grep -q 'pr list --state merged --search merged:>=2026-11-01' "$FAKE_DIR/calls.log"; then
  row "--since lists the merged pull requests through gh pr list" ok
else row "--since lists the merged pull requests through gh pr list" bad "exit $rc: $out"; fi
for bad in "--since 2026-13-01" "--since yesterday" "--prs 1,x" "--prs 1 --since 2026-11-01" "--prs 1 --sample 2"; do
  rm -f "$W/bad.jsonl"; out=$(bash "$FL" $bad --ledger "$W/bad.jsonl" 2>&1); rc=$?
  [ "$rc" = 2 ] && [ ! -e "$W/bad.jsonl" ] && row "bad arguments refused: $bad" ok || row "bad arguments refused: $bad" bad "exit $rc: $out"
done
out=$(bash "$FL" --prs 1,99 --ledger "$W/partial.jsonl" 2>&1); rc=$?
[ "$rc" = 2 ] && [ "$(wc -l <"$W/partial.jsonl" | tr -d ' ')" = 1 ] && row "an unreadable pull request: exit 2, the others still recorded" ok \
  || row "an unreadable pull request: exit 2, the others still recorded" bad "exit $rc: $out"
if grep -vE '^gh (pr view [0-9]+ --json|api graphql |pr list --state merged )' "$FAKE_DIR/calls.log" | grep -q .; then
  row "read-only: gh is only asked to read" bad "$(grep -vE '^gh (pr view|api graphql|pr list)' "$FAKE_DIR/calls.log" | head -n 3)"
else row "read-only: gh is only asked to read" ok; fi
[ -z "$(git -C "$R" status --porcelain --untracked-files=no)" ] && row "the git repository is left as it was" ok || row "the git repository is left as it was" bad "$(git -C "$R" status --short)"

# ---- trust events, one per pull request, each the only reason (PR 79 W1) --------------------------
# ql <ledger> <name> <pr> <jq>: q over another ledger.
ql() { local L="$1"; shift; q "$@"; }
M="$W/more.jsonl"
out=$(bash "$FL" --prs 7,8,9,10,11,12,13 --ledger "$M" 2>&1); rc=$?
[ "$rc" = 0 ] && row "record 7-13: exit 0" ok || row "record 7-13: exit 0" bad "exit $rc: $out"
ONE='(.complete | not) and (.incomplete_reasons | length) == 1'
ql "$M" "PR 7: a trusted comment deleted by another login makes the row incomplete; its author's own deletion does not" 7 "$ONE"' and .ignored.deleted_trusted == 1'
ql "$M" "PR 8: a trusted comment with no marker, edited by another login, makes the row incomplete" 8 "$ONE"' and .ignored.edited_trusted == 1'
ql "$M" "PR 9: a trusted verdict edited by its own author makes the row incomplete" 9 "$ONE"' and .ignored.edited_trusted == 1'
ql "$M" "PR 10: a closure marker quoted after the first line of a trusted comment is not read" 10 '.complete and .findings == {"closed":1,"refused":0,"escalated":0,"debt":1} and [.cycles[].cycle] == [1]'
ql "$M" "PR 11: a refusal labelled only in the closure, with no later pass, is a refused finding" 11 '[.refused_findings[].id] == ["C1"]'
ql "$M" "PR 12: one of two added lines overwritten is half, so the commit is overwritten" 12 '.fixer_commits[0] | .status == "overwritten" and .lines_added == 2 and .lines_overwritten == 1'
ql "$M" "PR 12: a new id with a status other than open is not a new finding" 12 '.cycles[0].new_warning == 1'
ql "$M" "PR 13: a merge commit inside the fixer range is not a fixer commit (N2)" 13 '[.fixer_commits[].sha] == ["'"$F13"'"]'
ql "$M" "PR 13: a later merge that rewrites a fixer line is not judged" 13 '.fixer_commits[0].status == "kept"'

# ---- a clone that lacks the pull request's commits (PR 79 W2) -------------------------------------
O2="$W/other"
git init -q "$O2" && git -C "$O2" commit -q --allow-empty -m other
NG="$W/nogit.jsonl"
out=$(cd "$O2" && bash "$FL" --prs 3 --ledger "$NG" 2>&1); rc=$?
[ "$rc" = 0 ] && row "record 3 from a clone without its commits: exit 0" ok || row "record 3 from a clone without its commits: exit 0" bad "exit $rc: $out"
ql "$NG" "no commits locally: the fixer commit is unknown, not kept" 3 '.git == "a commit of the pull request is not in the local clone" and .fixer_commits[0].status == "unknown" and .commits.unknown == 1'
ql "$NG" "no commits locally: an unre-raised refusal is not judged, not held" 3 '(.refused_findings[] | select(.id == "C4")) | .human_fix_checked == false and .false_refusal == null'
ql "$NG" "no commits locally: a re-raised refusal is still a false refusal" 3 '(.refused_findings[] | select(.id == "C2")) | .false_refusal == true'
out=$(bash "$FL" audit --ledger "$NG" 2>&1)
has "audit without the commits: C4 is not judged" "#3 C4 (cycle 1, g.txt:2): not judged: the commits were not in the local clone" "$out"
has "audit without the commits: the rate counts only judged refusals" "false-refusal rate: 1/1 (100.0%)" "$out"
has "audit without the commits: says how many were left out" "2 refused finding(s) not judged" "$out"

# ---- notes (PR 79 N3, N4, N6) ---------------------------------------------------------------------
ln -s "$R/linked.jsonl" "$W/link.jsonl"
out=$(bash "$FL" --prs 1 --ledger "$W/link.jsonl" 2>&1); rc=$?
[ "$rc" = 2 ] && [ ! -e "$R/linked.jsonl" ] && row "a ledger symlinked into the repository is refused" ok \
  || row "a ledger symlinked into the repository is refused" bad "exit $rc: $out"
out=$(bash "$FL" --since 2026-11-01 --limit 2 --ledger "$W/lim.jsonl" 2>&1)
has "--limit reached: says there may be more" "raise --limit" "$out"
out=$(bash "$FL" --since 2026-11-01 --limit 3 --ledger "$W/lim.jsonl" 2>&1)
case "$out" in *"raise --limit"*) row "--limit not reached: no warning" bad "$out" ;; *) row "--limit not reached: no warning" ok ;; esac
G="$W/gate-renamed"; mkdir -p "$G" && cp "$SRC"/*.sh "$SRC"/*.py "$G"/
python3 -I -c 'import sys; p = sys.argv[1]; s = open(p).read(); open(p, "w").write(s.replace("def marker_author_allowed(", "def marker_author_allowed_renamed(", 1))' "$G/gate-pr-review-state.py"
out=$(bash "$G/fix-ledger.sh" --prs 1 --ledger "$W/gate.jsonl" 2>&1); rc=$?
[ "$rc" = 2 ] && [ ! -e "$W/gate.jsonl" ] && grep -q 'def marker_author_allowed_renamed(' "$G/gate-pr-review-state.py" \
  && row "a gate without one of the names it imports: exit 2, no ledger" ok || row "a gate without one of the names it imports: exit 2, no ledger" bad "exit $rc: $out"

printf '%s\n' "${ROWS[@]}"
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
