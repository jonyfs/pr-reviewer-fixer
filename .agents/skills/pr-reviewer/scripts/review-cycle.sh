#!/usr/bin/env bash
#
# review-cycle.sh: the mechanical half of the adversarial review cycle.
#
# WHY IT EXISTS. The cycle requires a reviewer, a fixer and a second pass, and a pull request can
# still reach merge with no review marker at its head. Nothing was misconfigured in the reviewer:
# there was simply no TRIGGER. A skill that scores the user's prompt only suggests; a CI check
# that validates the FORM of the label lets `review:pending` pass forever, so a never-reviewed
# pull request stays green in the one place anybody looks. The cycle had a rule, a skill and a
# check, and no clock.
#
# WHAT THIS SCRIPT IS, AND IS NOT. It does not review anything and it has no opinion about a diff.
# It answers one question, has THIS head been reviewed, and it performs the two writes the answer
# implies. The judgement stays in `/pr-reviewer`; the corrections stay in `/pr-fixer`. This is
# the part that must never be done from memory, because remembering is what failed.
#
# THE ANTI-FABRICATION PROPERTY, MOVED FROM POLICY INTO MECHANISM. An earlier version kept the
# marker honest by refusing to be invoked by a model at all. That makes fabrication awkward, not
# impossible, and it also makes the cycle unable to finish without a person, which is the thing
# being fixed here. So the property is now enforced where it can actually be checked: `publish`
# re-reads the head from GitHub at the moment it writes, and REFUSES when the caller's `--sha` is not
# that head. A marker can only ever name a commit that was really at the head when the review ran.
# It still cannot tell a truthful report from an invented one (nothing can) but it can guarantee
# that a pass is bound to a specific commit and evaporates the moment anyone pushes over it.
#
# THE MARKER, AND WHY IT CARRIES ARITHMETIC NOW. At first the marker said only which head was
# read, what the verdict was, and which pass it came from:
#
#     <!-- adversarial-review: sha=<40hex> verdict=PASSED|BLOCKED pass=<n> -->
#
# It now also says what the reviewer counted:
#
#     <!-- adversarial-review: sha=<40hex> verdict=PASSED pass=2 critical=0 warning=3 note=7 -->
#
# The reason is a measured impasse. On a prior review cycle, many passes over several pull
# requests produced dozens of findings and zero approvals; none of them was CRITICAL by the
# reviewer's own severity table, because the changes touched nothing the project declares
# non-negotiable, and every verdict came back BLOCKED. The skill said `BLOCK = 1+ CRITICAL`; the
# practice said `BLOCK = 1+ finding`; and there was nothing mechanical between the two sentences,
# so the looser one won every time. Writing the counts into the marker is what puts the two in the
# same place, where they can be compared: `publish` refuses a BLOCKED that counts no CRITICAL, and
# refuses a PASSED that counts one.
#
# `verdict=PASSED` therefore means **nothing blocks**, never "perfect". That is Google's "favour
# approving once the change definitely improves overall code health, even if it is not perfect", and
# the warnings and notes beside it are declared debt rather than an unlisted objection.
#
# BOTH FORMS ARE READ, and this is not a courtesy. Every marker published before the counts existed
# has three fields. A reader that only understands six declares those markers ABSENT, and in this
# cycle absence reads as *not reviewed*, so the fix for a stuck cycle would have started by
# invalidating every review it had already done. The three counts are one optional group,
# all-or-nothing: `critical=` without its two siblings is not a marker carrying partial
# information, it is not a marker.
#
# SUBCOMMANDS:
#
#     status [pr]          what the cycle owes, and the next command (exit codes below)
#     debt [pr]            the same answer as an exit code only, for hooks and CI
#     start [pr]           review:running, and review:needs-human withdrawn
#     fix [pr]             review:fixing, and review:needs-human withdrawn. Refused first when the
#                          pull request is from a fork or any author is not a collaborator with
#                          write access (FIXER_TRUSTED_LOGINS names bots allowed without a lookup)
#     halt [pr] [--reason R]
#                          review:needs-human added to a review:blocked pull request: the loop
#                          paused or stopped and a person has to decide. With --reason, also posts
#                          the `state=halted` extension marker.
#     budget [pr]          the cycle budget read from the trusted markers: what the loop does
#                          next (fix, ask, ceiling or none) as B_<KEY>='<value>' lines. With
#                          REVIEW_MARKER_AUTHORS unset it answers none and trusts nothing.
#     extend [pr] --n <n>  records that a person granted n more cycles (`state=granted` marker)
#     export-audit [pr] [--out <dir>]
#                          writes <dir>/<pr>-<pass>.json (default docs/compliance-records) from
#                          the trusted marker and the PR timeline; refuses when the head moved
#     stale [pr]           a marker-backed state whose head moved goes back to review:pending
#     marker [file] [--author <login>]
#                          reads one marker from a file or stdin
#     publish [pr] --verdict PASSED|BLOCKED --pass <n> --sha <40hex> --report <file>
#             --critical <n> --warning <n> --note <n> [--model <id> --tier fast|standard|deep]
#                          posts the marker comment, then moves the label. On PASSED, a draft
#                          pull request is marked ready for review (`gh pr ready`). Refuses a
#                          report that holds a token or private key (never printed), and wraps a
#                          bare @login in backticks so the comment notifies nobody.
#     lint-report [pr] --report <file> [--diff <file>]
#                          checks that every finding names a file and a line the diff shows, and
#                          that the `counts:` line matches the open entries, and that the coverage note says what was
#                          declined, and fails a report that holds a token or private key. Run
#                          before publish;
#                          posts nothing. Exit 1 on a problem, 2 when it could not read an input.
#     ensure-labels        creates or updates the six review:* labels in the current repository
#                          (gh resolves the repository from the working directory or GH_REPO)
#
# ENVIRONMENT:
#
#     REVIEW_MARKER_AUTHORS   Required comma-separated allowlist of GitHub logins, as `gh pr view
#                             --json comments` prints them in `author.login`. Set it to the
#                             login the harness session publishes as (`gh api user --jq .login`).
#                             When this variable
#                             holds anything other than whitespace, a comment supplies a marker
#                             only if its author is on the list (compared case-insensitively),
#                             in every reader: `parse()` here, `marker --author`, and
#                             gate-pr-review-state.py. Without it, anyone who can comment on the
#                             pull request can post an invisible PASSED marker, because the marker
#                             is an HTML comment and every comment is scanned. The list must name
#                             at least one login: unset, empty, whitespace and a lone comma all
#                             make `status`, `publish`, `budget`, `extend`, `export-audit` refuse.
#                             Only the bare `marker` subcommand still reads with the list unset.
#                             A comment edited after it was created is never read (pr-json.py).
#     MAX_REVIEW_CYCLES       Automatic review-fix-review cycles before the loop asks a person.
#                             Default 5. Read by `budget` and `extend`.
#     MAX_REVIEW_CYCLES_HARD  Absolute ceiling no answer passes. Default 10, clamped to 1..10.
#     REVIEW_GATE_TIMEOUT_S   Seconds the gate has to answer inside `status` on a merged pull
#                             request. Default 15; see the comment above `GATE_TIMEOUT_S`.
#
# Exit codes: 0 = nothing owed · 1 = review owed · 2 = anything that is not either of those, and it
# is never the same as approved.
#
# **The 2 of `cmd_status` carries seven meanings, and saying so is what keeps it harmless.** The
# subject is the FUNCTION and not the file, and the difference is not pedantry: the count a test
# checks against this sentence is `return 2` inside `cmd_status`, while the file also exits 2 in
# several places outside it, counted by their own sentence further down, which is where they belong.
# A sentence whose subject is wider than what it counts reads as a total and is not one.
#
# The gate this function calls was split precisely because one integer meant two things; the same
# conflation lives on here, one layer up. Addressed by NAME, because the previous version of this
# paragraph addressed them by line number and every one of the four had rotted by the next commit,
# one of them landing in a node one-liner inside `parse()`. `cmd_status` returns 2 for:
#
#   · no pull request for this branch, or `gh` offline: the `[ -n "$json" ]` guard at its top;
#   · the gate not being READABLE, not COMPILING, not proving it decided (the `--emit-token`
#     comparison), not RETURNING AT ALL within `GATE_TIMEOUT_S`, and the gate having PROVED it
#     decided while answering a code that is not a reading: the `*)` arm of the `case`.
#     That is five sentences that all end in "only that nobody looked";
#   · the gate having READ a MERGED pull request and recorded that it carries no valid
#     `review:passed`: the sentence ending in "this is recorded, not owed".
#
# **The `*)` arm was missing from this list at first, and it is the one that is different.**
# The other four blind sentences never get a decision out of the gate, and they split in two: the
# unreadable gate and the gate that does not compile never ran at all, while the gate killed by
# `GATE_TIMEOUT_S` and the gate that exited with no matching `--emit-token` line DID run and left
# nothing behind to read. Calling all of them "never ran" was wrong about the timeout in
# particular, which is a gate that ran and was killed mid-answer. The `*)` arm is a third thing
# again: the gate ran, PROVED it ran, and what it decided was that it could not read a label:
# precisely the distinction the `--emit-token` contract exists to make, absent from the paragraph
# whose whole job is to declare the distinctions.
#
# It was found by counting, and BOTH numbers of this paragraph count the same thing: the lines of
# `cmd_status` ending in `only that nobody looked`: the first counting all of them, the second that
# same count minus the `*)` arm it sets apart. Counting anything else (cases in a suite, items in a
# list) gave a different number every time, which is how this paragraph once said `five` in one
# sentence and `three` two lines below it, about the same set of branches. Whoever edits either
# sentence counts those lines again.
#
# Four more 2s live outside `cmd_status` and belong in the same list: the `command -v gh` check
# at the top of the file exits 2 when `gh` is not installed, `parse()` exits 2 when the payload
# holds no readable pull request number (so every subcommand that parses, `stale` included, ends
# there on an unreadable payload), `cmd_stale` returns 2 when there is no pull request to read,
# and `cmd_ensure_labels` returns 2 when `gh` could not create a label (offline, no token, no
# permission). None of them is a decision about a review either.
#
# Today nothing branches on the difference: the callers speak only at rc=1 and treat every
# 2 as silence, so the conflation is inert. It stays inert by being declared, not by luck: the
# next caller that wants to tell "nobody looked" from "read and recorded" has to split this the way
# the gate was split, and this comment is what tells them the split has not happened yet.
set -uo pipefail

PATH="${PATH:+$PATH:}/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
export PATH

# **A declared copy of `run_with_timeout`, and the reason for not sourcing a shared helper is
# measured, not aesthetic.** This file is COPIED alone into a temporary directory by its own
# suite (that is how the cases swap the gate for a stub without touching the repository), and
# no sibling helper directory exists there. A time limit that only exists when the whole tree is
# mounted is a limit that is missing exactly where the test exercises it: sourcing a helper from
# outside this directory leaves the limit missing in every case run from a temporary directory.
#
# The duplication becomes a drift risk, so the drift should be MEASURED: run every copy of the
# wall against the same child that hangs, in both branches, and require the same 124 **and** the
# same silence in `ps` from all four passes, because 124 alone does not tell killing the child
# from leaving it orphaned, which was a defect every copy once carried together.
#
# The body follows the usual pattern, and so does its reason: stock macOS ships neither `timeout`
# nor `gtimeout` (both are coreutils, not base utilities), and falling back to "no limit at all"
# when they are missing means having no limit on exactly the machine that needs one most.
#
# **The two declared limitations of this wall, each measured, apply here**: a child that calls
# `setsid()` leaves the group and survives the group `kill`, **only on the pure-bash fallback**,
# and not because killing by group is inherently like that: GNU `timeout` signals the monitored
# pid IN ADDITION to the group, so it has no such hole; what this wall monitors is the subshell
# wrapping the command, never the command, and that layer is the difference. And the `timeout`
# branch does not escalate to `KILL`, so it hangs forever on a child that ignores `TERM`. No
# command this file passes to the wall does either.
run_with_timeout() {
  local secs="$1"; shift
  # `</dev/null` ON EVERY BRANCH, and it is a contract, not a tidy-up: the child NEVER reads the
  # caller's stdin. Hooks that call this script are handed a JSON payload on stdin by the
  # harness, and a child that consumes that payload leaves the hook nothing to read, with no way
  # to tell theft from an empty stdin. A test should pipe a payload through the wall in both
  # branches and require the child to print none of it.
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@" </dev/null; return $?
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@" </dev/null; return $?
  fi
  local out; out="$(mktemp 2>/dev/null)" || { "$@" </dev/null; return $?; }
  # `set -m` makes the background subshell a PROCESS GROUP LEADER, and that is the whole reason it
  # is here. Without it `$!` names the SUBSHELL and the command the subshell launched is a
  # grandchild: `kill "$pid"` reaped the subshell, returned 124, and left the command running,
  # reparented to init. A limit that reports and does not limit, on exactly the stock machine this
  # fallback was written for.
  #
  # WHAT `set -m` DOES NOT CONTAIN, and the `set +m` below cannot undo. Two effects land at the FORK,
  # not at the option, so restoring the caller's job control afterwards restores nothing about them:
  #
  #   1. Without job control bash points an asynchronous command's stdin at `/dev/null` on its own.
  #      With job control on at the fork it does not, and the child inherits the caller's stdin.
  #      That is why the `</dev/null` above is written out here instead of being left to bash.
  #   2. The child is in a BACKGROUND process group. A child that then tries to read a terminal takes
  #      `SIGTTIN` and STOPS, and `kill -0` answers yes for a stopped process, so the poll below
  #      would wait out the whole budget instead of answering when the command did. `</dev/null`
  #      closes this one too: there is no terminal left to read.
  #
  # The option itself is restored to whatever the caller had, never left on.
  local jobcontrol=0; case "$-" in *m*) jobcontrol=1 ;; esac
  set -m
  ( "$@" </dev/null >"$out" 2>&1; echo $? >"$out.rc" ) &
  local pid=$!
  [ "$jobcontrol" = 1 ] || set +m
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$secs" ]; then
      # The GROUP first, `-$pid`, so the grandchild goes with the subshell. The plain `$pid` is
      # the fallback for a shell that refused job control: killing only the subshell is worse than
      # the group and better than nothing, and it is what this line did before.
      #
      # THE GUARANTEE IS `set -m` **AND** `-$pid`, CONJOINTLY, never either one on its own. Read as
      # "`set -m` is what carries it", this `-$pid` looks like decoration a future editor may drop.
      # Measured with `set -m` in place and both lines aiming at the bare `$pid`:
      #
      #     $ perl -i -pe 's{kill -(TERM|KILL) -"\$pid" .* \|\| kill -\1 "\$pid" .*}{kill -$1 "\$pid"}'
      #     the child launched by the wall survives (a surviving pid is reported)
      #
      # The orphan is back with the option still on. `set -m` is necessary and not sufficient: it
      # only makes a group exist, and `-$pid` is what aims at it.
      #
      # WHAT A TEST SUITE KILLS, SAID WITHOUT AMBIGUITY. Mutating the two `kill` lines one at a
      # time, only the `KILL` line is individually necessary. Run one mutation per run of the whole
      # suite, in every copy of the wall, and write down the VERDICT of each, never how many cases
      # moved. A kill ratio is only checkable by running the mutation in the tree you are standing
      # in, so the number is the reader's to obtain and the command above is what does not rot:
      #
      #     mutation                               result
      #     both lines aimed at the bare `$pid`    red
      #     only the `KILL` line at `$pid`         red
      #     only the `TERM` line at `$pid`         green
      #     `set -m` deleted                       red
      #
      # The two mutations a suite kills separately are the `perl` above and the deletion of
      # `set -m`, which is the conjunction this paragraph is about. The `TERM` line aimed at the
      # bare `$pid` survives, and that survival is a declared gap in the measurement.
      kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
      sleep 1
      kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      cat "$out" 2>/dev/null; rm -f "$out" "$out.rc"
      return 124
    fi
    sleep 1; waited=$((waited+1))
  done
  wait "$pid" 2>/dev/null
  local rc=0; [ -f "$out.rc" ] && rc="$(cat "$out.rc")"
  cat "$out" 2>/dev/null; rm -f "$out" "$out.rc"
  return "$rc"
}

# How long the gate has to answer. Configurable because the suite needs a short budget, and
# fixed at 15 in real use: less than the 25 with which a caller may wrap this whole call,
# so the inner limit fires before the outer one and the sentence says WHICH gate hung.
#
# **THERE IS A THIRD LIMIT, it is the LARGEST of the three, and it sits INSIDE what this one kills.** The gate
# calls `gh` with `subprocess.run(..., timeout=60)`. The 15 was justified only against the outer 25;
# nobody had compared it with the inner 60. The order that results is 15 < 25 < 60, and the consequence
# is that the gate's `timeout=60` is DEAD on this path: a hung `gh` makes this `timeout`
# kill the gate at 15s, and what describes the event is the sentence here, "the gate did not return
# within 15s", never the gate's own sentence about `gh`. That is the desired behavior (the outer sentence
# names the gate, which is what the reader needs to know), and it remains declared debt: the 60 is
# unreachable for this caller and reachable for any other that invokes the gate directly.
#
# **And 15 is not tight.** Measured with the real gate against a real pull request:
#
#     $ for i in 1 2 3; do /usr/bin/time -p python3 gate-pr-review-state.py <pr>; done
#     real 1.21 · real 1.29 · real 1.21
#
# That is ~12× of headroom against the 15. A `gh` that takes longer than that is not slow, it is hung,
# which is exactly the case the limit exists for.
GATE_TIMEOUT_S="${REVIEW_GATE_TIMEOUT_S:-15}"

# **The five states, declared once and read from here.** At first this line had no caller at
# all: `parse()` carried its own copy of the same alternation inside a JavaScript literal, so the
# "declaration" was a comment that happened to be a variable, and the two lists agreed only until
# somebody edited one. `parse()` now builds its filter from THIS string, which is what makes adding
# a state a one-line change instead of a two-place ritual with a silent failure mode: a state
# missing from the copy is not read as unknown, it is read as ABSENCE, and absence in this cycle
# means *not reviewed*.
#
# The order is the cycle read left to right (pending, running, fixing, blocked, passed) and it
# is an order of READING, never of precedence: exactly one of them holds at a time, and two at once is
# refused by the CI check rather than resolved by rank.
STATES_RE='review:(pending|running|fixing|blocked|passed)'
# The shell reader. It had no caller at first, a third reader of the marker format that read
# nothing, which is why no test could ever see it drift from the other two. `marker` is its
# caller now, and a test can drive both forms through it.
MARKER_RE='<!--[[:space:]]*adversarial-review:[[:space:]]*sha=([0-9a-f]{7,40})[[:space:]]+verdict=(PASSED|BLOCKED)[[:space:]]+pass=([0-9]+)([[:space:]]+critical=([0-9]+)[[:space:]]+warning=([0-9]+)[[:space:]]+note=([0-9]+))?([[:space:]]+model=([A-Za-z0-9._:-]+)[[:space:]]+tier=(fast|standard|deep))?[[:space:]]*-->'

die() { printf '%s\n' "$*" >&2; exit 1; }

# **Digits AND a magnitude the shell can compare, because "digits" was never the property.**
# `[ 99999999999999999999 -gt 0 ]` is not false: it is an ERROR, status 2, and under `set -uo
# pipefail` without `-e` the `&&` chain around it short-circuits past `die`. A twenty-digit
# `--critical` therefore walked through the guard that keeps a CRITICAL out of a PASSED and got
# published, exit 0, with the error printed to a stderr nobody reads, and `debt` discards stderr
# entirely. This is the same class already fixed for `--pass`; the counts arrived afterwards without
# the lesson, which is what a rule written in one place and not the other looks like.
#
# Nine digits is past any count a review can produce and inside every 64-bit shell, so the bound
# refuses only values that were going to break the comparison anyway.
numero() {
  case "$2" in ''|*[!0-9]*) die "review-cycle: $1 must be digits (^[0-9]+\$), got '$2'" ;; esac
  [ "${#2}" -le 9 ] || die "review-cycle: $1 has ${#2} digits, and a number this large is not compared, it is an ERROR the guards short-circuit past — got '$2'"
}

# "More than zero" decided by SHAPE, never by numeric comparison, because the readers take whatever a
# marker carries, including one posted by hand or by an older script, which `numero` never saw. A
# count is positive when it is digits and not all zeros. This is what stopped `status` from printing
# "Nothing owed." at exit 0 over the very marker the CI check refuses by name.
positivo() { case "${1:-}" in ''|-|*[!0-9]*) return 1 ;; *[!0]*) return 0 ;; *) return 1 ;; esac; }

# The marker author allowlist, the shell half. The node reader in `parse()` and the gate apply the
# same three rules: the list is active when the variable holds anything other than whitespace, each
# entry has all whitespace removed (a login never contains any), and the compare ignores case.
marker_authors_active() { case "${REVIEW_MARKER_AUTHORS:-}" in *[![:space:]]*) return 0 ;; *) return 1 ;; esac; }
# READY is stricter than active: at least one login must survive the normalisation. Unset, empty,
# whitespace and a lone comma are all not ready, and every command that decides from markers
# (`status`, `publish`, `budget`, and so `extend`) refuses to guess in that case. The marker reader
# applies the same rule, so the commands cannot disagree about what "," means.
marker_authors_ready() {
  local entry list=()
  IFS=, read -r -a list <<<"${REVIEW_MARKER_AUTHORS:-}"
  for entry in ${list[@]+"${list[@]}"}; do
    [ -n "$(printf '%s' "$entry" | tr -d '[:space:]')" ] && return 0
  done
  return 1
}
NOT_READY_MSG='REVIEW_MARKER_AUTHORS is not set or lists no login, so no marker can be trusted. Set it to the login the harness publishes as: gh api user --jq .login'
marker_author_allowed() {
  local want entry list=()
  want="$(printf '%s' "${1:-}" | tr -d '[:space:]' | tr 'A-Z' 'a-z')"
  [ -n "$want" ] || return 1
  # `read -a` and not an unquoted expansion, so an entry such as `*` is never globbed.
  IFS=, read -r -a list <<<"${REVIEW_MARKER_AUTHORS:-}"
  for entry in ${list[@]+"${list[@]}"}; do
    entry="$(printf '%s' "$entry" | tr -d '[:space:]' | tr 'A-Z' 'a-z')"
    [ -n "$entry" ] && [ "$entry" = "$want" ] && return 0
  done
  return 1
}
command -v gh >/dev/null 2>&1 || { echo "review-cycle: gh is not installed — INCONCLUSIVE" >&2; exit 2; }

# Reads the pull request once. $1 is an optional explicit number; without it, the branch's own.
pr_json() {
  local n="${1:-}"
  # Read through pr-json.py, which drops every comment edited after it was created and fails closed
  # when edits cannot be checked. Nothing here reads comments from `gh pr view` directly.
  python3 -I "$(dirname "$0")/pr-json.py" ${n:+"$n"} 2>/dev/null
}

# Parses the payload into NUMBER / HEAD / LABEL / MARKER_SHA / MARKER_VERDICT / MARKER_PASS.
parse() {
  local json="$1"
  # One node process reads the six simple fields (a fork per field was the cost of every call).
  # The unit separator keeps an empty field empty. `$STATES_RE` comes through the environment,
  # never retyped here: a second copy of the vocabulary is a second thing to forget, and an unlisted
  # state leaves `$LABEL` empty, which every caller reads as "nobody reviewed this".
  local fields
  fields=$(printf '%s' "$json" | STATES_RE="$STATES_RE" node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{
    const p=JSON.parse(s),re=new RegExp("^"+process.env.STATES_RE+"$"),L=(p.labels||[]).map(x=>x.name);
    const a=[String(p.number||""),String(p.headRefOid||"").toLowerCase(),String(p.state||""),
      p.isDraft===true?"yes":"",L.filter(n=>re.test(n)).join(" "),L.includes("review:needs-human")?"yes":""];
    // A field holding the separator would shift every field after it. Print nothing instead: every
    // variable comes out empty, which callers read as "could not read the pull request".
    if(!a.some(x=>x.includes("\x1f")))process.stdout.write(a.join("\x1f"))}catch(e){}})')
  IFS=$'\x1f' read -r NUMBER HEAD STATE IS_DRAFT LABEL HALTED <<<"$fields"
  # No number means the payload was unreadable (or held the separator). Every caller treats the
  # variables as facts, so stop here, with the code `status` uses for "could not read".
  [ -n "$NUMBER" ] || { echo "review-cycle: could not read the pull request fields — INCONCLUSIVE" >&2; exit 2; }
  # `review:needs-human` is a SIXTH label and deliberately not one of the five states: the states
  # are a cycle position (exactly one at a time) and this one is a modifier of `review:blocked`
  # that says the loop paused or stopped and a person has to decide. Keeping it out of $LABEL is what lets
  # both live on the pull request without the CI check reading them as "two review states at once".

  # The marker is whatever OPENS a comment, never the last thing that happens to match inside one.
  # `publish` always writes `<!-- marker -->\n\n<report>`, so a genuine marker sits at position 0
  # of its comment. A report body routinely QUOTES the marker format, to show what a passing one
  # will look like once the findings close, and that quotation used to win here, because the old
  # regex scanned the whole body and kept the LAST match, wherever it fell. Anchoring at comment
  # start makes a quotation invisible to this parser without asking anyone to stop writing reports
  # that explain themselves. Among comments that DO open with a marker, the last one (chronological
  # order, oldest first) is still the current verdict.
  #
  # The three counts are an OPTIONAL group, so this reader takes both the three-field marker the
  # older passes posted and the six-field one the newer passes post. A `-` in a count
  # means the marker predates them, which is deliberately not the same value as `0`: one says nobody
  # counted, the other says somebody counted nothing.
  #
  # The author filter. With `REVIEW_MARKER_AUTHORS` active (see the header), a comment whose
  # `author.login` is not on the list is skipped before the regex runs, so it can supply neither
  # the current verdict nor the BLOCKED history below. Both answers come out of this one loop,
  # which is why the filter lives here and not in a second pass. Callers that decide
  # (`status`, `publish`, `budget`, `extend`, `export-audit`) refuse an unset or login-less list
  # before they get here; an empty list skips nothing.
  local m
  m=$(printf '%s' "$json" | REVIEW_MARKER_AUTHORS="${REVIEW_MARKER_AUTHORS:-}" node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{
    const re=/^\s*<!--\s*adversarial-review:\s*sha=([0-9a-f]{7,40})\s+verdict=(PASSED|BLOCKED)\s+pass=(\d+)(?:\s+critical=(\d+)\s+warning=(\d+)\s+note=(\d+))?(?:\s+model=([A-Za-z0-9._:-]+)\s+tier=(fast|standard|deep))?\s*-->/i;
    const env=process.env.REVIEW_MARKER_AUTHORS||"",active=/\S/.test(env);
    const allow=env.split(",").map(x=>x.replace(/\s+/g,"").toLowerCase()).filter(Boolean);
    let last=null,blocked="no";
    for(const c of (JSON.parse(s).comments||[])){
      if(active){const who=String((c&&c.author&&c.author.login)||"").toLowerCase();if(!who||!allow.includes(who))continue;}
      const mm=re.exec(c.body||"");
      if(mm){last=mm;if(mm[2].toUpperCase()==="BLOCKED")blocked="yes";}}
    for(const c of (JSON.parse(s).editedComments||[])){
      if(active){const who=String((c&&c.author&&c.author.login)||"").toLowerCase();if(!who||!allow.includes(who))continue;}
      const mm=re.exec(c.body||"");
      if(mm&&mm[2].toUpperCase()==="BLOCKED")blocked="yes";}
    process.stdout.write(last?[last[1].toLowerCase(),last[2].toUpperCase(),last[3],
      last[4]||"-",last[5]||"-",last[6]||"-",blocked,last[7]||"-",last[8]||"-"].join(" "):
      // No readable marker, but a BLOCKED one was seen (it may have been edited): keep the history.
      (blocked==="yes"?["","","","-","-","-",blocked,"-","-"].join(" "):""))
  }catch(e){}})')
  MARKER_SHA=$(printf '%s' "$m" | cut -d' ' -f1)
  MARKER_VERDICT=$(printf '%s' "$m" | cut -d' ' -f2)
  MARKER_PASS=$(printf '%s' "$m" | cut -d' ' -f3)
  MARKER_CRITICAL=$(printf '%s' "$m" | cut -d' ' -f4)
  MARKER_WARNING=$(printf '%s' "$m" | cut -d' ' -f5)
  MARKER_NOTE=$(printf '%s' "$m" | cut -d' ' -f6)
  # **Whether the pull request was EVER blocked, which is a different question from what the newest
  # marker says.** It is what makes `pass>=2` mean the thing it was written to mean: the second pass
  # exists to review a CORRECTION, so the bar applies where a correction was demanded and nowhere
  # else. Reading only the last marker cannot answer it: a BLOCKED at pass 1 is precisely the
  # marker a later PASSED overwrites as "current".
  MARKER_BLOCKED_SEEN=$(printf '%s' "$m" | cut -d' ' -f7)
  # Self-attested by the publishing session, never verified. `-` when the marker carries none.
  MARKER_MODEL=$(printf '%s' "$m" | cut -d' ' -f8)
  MARKER_TIER=$(printf '%s' "$m" | cut -d' ' -f9)
}

# Reads ONE marker, through `MARKER_RE`, from a file or from stdin, and prints
# `sha verdict pass critical warning note`, with `-` in each count that the marker does not carry.
# Exit 1 when there is no marker to read, which includes a marker QUOTED inside a body rather than
# opening it: the anchor is the same rule the other two readers apply, and it is applied here rather
# than described here for the same reason.
#
# `--author <login>` names who wrote the text. It matters only when `REVIEW_MARKER_AUTHORS` is
# active: then a text with no `--author`, or with one that is not on the list, has no marker, the
# same answer `parse()` and the gate give for a comment by somebody off the list. A bare text
# carries no author of its own, so the caller has to say it, and not saying it is not trusted.
# Unset, `--author` is accepted and ignored.
cmd_marker() {
  local body file="" author=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --author) [ $# -ge 2 ] || die "review-cycle: --author needs a login"; author="$2"; shift 2 ;;
      *)        [ -z "$file" ] || die "review-cycle: marker takes one file, got '$file' and '$1'"
                file="$1"; shift ;;
    esac
  done
  if [ -n "$file" ]; then
    [ -r "$file" ] || die "review-cycle: cannot read '$file'"
    body="$(cat -- "$file")"
  else
    body="$(cat)"
  fi
  if marker_authors_active && ! marker_author_allowed "$author"; then
    echo "review-cycle: REVIEW_MARKER_AUTHORS is set and the author '${author:-<none given>}' is not on it, so this text supplies no marker" >&2
    return 1
  fi
  # **The whole text, and case-insensitively, because the other two readers are both.** This reader
  # exists so the shell stops deriving the marker format from JavaScript and Python; it shipped still
  # deriving it, only stricter, which is a third answer wearing a fail-safe coat. Cutting to the
  # first line lost a marker preceded by a blank line and the two-line marker that
  # `gate-pr-review-state.py` displays as THE format in its own docstring; `[[ =~ ]]` being case
  # sensitive lost `verdict=passed` and an uppercase SHA, which `/i` takes on both siblings.
  #
  # The anchor is untouched and does the same work on the whole body as it did on one line:
  # `[[:space:]]` spans newlines, so only whitespace may precede a marker and a quoted one is still
  # not one.
  local restaura; restaura="$(shopt -p nocasematch)"
  shopt -s nocasematch
  if [[ "$body" =~ ^[[:space:]]*$MARKER_RE ]]; then
    printf '%s %s %s %s %s %s\n' \
      "$(printf '%s' "${BASH_REMATCH[1]}" | tr 'A-Z' 'a-z')" \
      "$(printf '%s' "${BASH_REMATCH[2]}" | tr 'a-z' 'A-Z')" \
      "${BASH_REMATCH[3]}" \
      "${BASH_REMATCH[5]:--}" "${BASH_REMATCH[6]:--}" "${BASH_REMATCH[7]:--}"
    eval "$restaura"
    return 0
  fi
  eval "$restaura"
  echo "review-cycle: no marker opens this text — a quotation of the format is not a marker" >&2
  return 1
}

# Says, in one line, what the cycle owes, and the exact next command, never a description of one.
cmd_status() {
  marker_authors_ready || { echo "review-cycle: $NOT_READY_MSG — INCONCLUSIVE"; return 2; }
  local json; json="$(pr_json "${1:-}")"
  [ -n "$json" ] || { echo "review-cycle: no open pull request for this branch, gh is offline, or comment edits could not be checked — INCONCLUSIVE"; return 2; }
  parse "$json"
  # CLOSED without merge shipped nothing. MERGED shipped, and the first version of this line treated the
  # two the same, so **merging switched off the Stop hook**, which is the half the gate had already
  # fixed and this one had not. Found by an adversarial review: the gate said exit 1 on a merged pull
  # request without `review:passed` and this script said 0 on the same one, about the same fact.
  if [ "$STATE" = "CLOSED" ]; then echo "review-cycle: #$NUMBER was closed without merging — nothing shipped"; return 0; fi
  if [ "$STATE" = "MERGED" ]; then
    # **DELEGATES to the gate instead of reimplementing the question.** The first version matched
    # `*review:passed*` against the raw label list and did not look at the marker, so it accepted a merged pull
    # request whose label said `review:passed` with no evidence behind it, while the
    # gate refused the SAME pull request for "the claim standing alone". Two implementations of the
    # same question disagree; it is the same disease that made the `publish` guard bypassable.
    # EXISTENCE is checked BEFORE the call, and not by the exit code afterwards. `python3` returns
    # **2** both for "file does not exist" and for the gate's own INCONCLUSIVE, so
    # telling them apart by code is impossible: the first version of this guard tried and said "merged
    # without review:passed" about a pull request it never got to read.
    # `local`, and the reason is the usual one in this file: a value that survives the function is a value
    # someone reads later without knowing where it came from. Measured: `_rc` and `_portao` reached the
    # caller intact. Inert today; the way to stay inert is the declaration, not luck.
    local _portao _rc _saida _token
    _portao="$(dirname "$0")/gate-pr-review-state.py"
    if [ ! -r "$_portao" ]; then
      echo "review-cycle: #$NUMBER is MERGED and the gate is not readable at $_portao — this says nothing about the review, only that nobody looked"
      return 2
    fi
    # **`[ -r ]` answers "is it there"; it does not answer "does it run".** A gate that exists and
    # does not compile is the fourth blind path, and it was the loudest: `python3` answers a
    # `SyntaxError` with exit **1**, before the first line of the gate executes, and before any
    # `try/except` inside it exists to catch anything, and 1 is the branch below that means "read
    # it and refused". So a gate that never ran produced the sentence that ASSERTS a pull request
    # merged without `review:passed`, with nobody having examined a label. Same class as the
    # version bail: an exit code borrowed from the interpreter, read as if the program had chosen
    # it.
    #
    # `compile()` and not `python3 -m py_compile`: the module writes a `__pycache__` next to the
    # gate, and a readiness check that leaves files behind next to it is a check with a
    # side effect. This one reads and throws away.
    if ! python3 -c 'import sys; compile(open(sys.argv[1]).read(), sys.argv[1], "exec")' "$_portao" >/dev/null 2>&1; then
      echo "review-cycle: #$NUMBER is MERGED and the gate at $_portao does not compile — a gate that cannot run has not run; this says nothing about the review, only that nobody looked"
      return 2
    fi
    # **The two guards above are REDUNDANT since the token exists, and stay because they are
    # diagnostic.** The guarantee is the line right below: an absent gate, one that does not compile and one
    # that blows up before deciding all land in the same place by producing no token. What the
    # two guards add is NAMING the cause ("not there", "does not compile") for whoever is
    # debugging, instead of returning the same generic sentence for three different defects.
    # Declared redundancy; if it ever becomes a nuisance, the line below stands alone.
    #
    # **The gate PROVES that it decided, and that is not inferred from the exit code.** A Python process's
    # exit code comes from the interpreter as much as from the program: an empty file exits 0, an
    # `import` that does not resolve exits 1, a `SyntaxError` exits 1. Measured with the real gate
    # replaced by a zero-byte file: `[ -r ]` passed, `compile("")` passed, `python3` exited 0,
    # and this `case` read 0 as "I read it; the claim holds", the sentence `#<n> merged with a valid
    # review:passed` about a pull request nobody read. Fabrication committed by the mechanism
    # meant to prevent it.
    #
    # `--emit-token` makes the gate print `gate-pr-review-state: rc=<n>` as the LAST line of
    # stdout, from the same value it passes to `sys.exit`. Requiring the line PRESENT and with the
    # number EQUAL to the exit code closes the four fake gates a test can stage:
    # empty file, `import` that does not resolve, output with no token
    # at all, and a token that disagrees with the code the process exits with. None of them manages to print
    # the matching line, and a gate that printed a stale line would be caught by the divergence.
    #
    # **The gate that does not return is the FIFTH way of not deciding, and it was the only one with no limit.**
    # The previous four are the gate answering something: absent, not compiling, with no matching token,
    # and with a code that is not a reading. This one is it not answering: `python3` without
    # `timeout` hangs `cmd_status` indefinitely. Measured with a stub that sleeps and an external
    # wall: `timeout 10 review-cycle.sh status <pr>` returned 124 in 10s, with no output line;
    # without the wall, forever. A caller that wraps this call in its own limit survives that, and
    # one that wraps nothing does not.
    #
    # **This number was once counted more than one way within the same paragraph, and the counts
    # did not agree with each other.** The sentence counted suite cases, the enumeration beside it
    # counted prose items, and the code has the branches, and each way gave a different result. One
    # thing is counted now, and it is code: the lines of `cmd_status` that end in "only that
    # nobody looked", the first sentence counting all of them, the second that count minus the form it
    # sets aside. Whoever edits either of the two counts those lines again.
    #
    # On the pure-bash fallback of `run_with_timeout` the child's stderr is folded into stdout, so the
    # outer `2>/dev/null` does not reach it. The comparison below looks at the LAST line, and the token is
    # the last thing the gate prints, so a traceback ahead of it does not change the answer.
    _saida="$(run_with_timeout "$GATE_TIMEOUT_S" python3 "$_portao" "$NUMBER" --emit-token 2>/dev/null)"
    _rc=$?
    if [ "$_rc" -eq 124 ]; then
      # Own branch, and not the generic sentence for a missing token. "It did not prove it decided" would be
      # true and would send the person looking for a broken gate, and the gate is intact, it just did not
      # return. Saying which limit it was is what makes the sentence actionable.
      echo "review-cycle: #$NUMBER is MERGED and the gate did not return within ${GATE_TIMEOUT_S}s — it was killed, so it decided nothing; this says nothing about the review, only that nobody looked"
      return 2
    fi
    _token="$(printf '%s\n' "$_saida" | tail -n 1)"
    if [ "$_token" != "gate-pr-review-state: rc=$_rc" ]; then
      echo "review-cycle: #$NUMBER is MERGED and the gate exited $_rc without proving it decided — no rc token matching that exit; this says nothing about the review, only that nobody looked"
      return 2
    fi
    case "$_rc" in
      0) echo "review-cycle: #$NUMBER merged with a valid review:passed"; return 0 ;;
      # **1 and 3 are the gate having READ; 2, 4 and the rest are the gate not having read.** It is the only
      # question this branch decides, and it only became answerable when the gate gained
      # five codes instead of three: before, the SAME 2 meant "I could not read" in two
      # places and "I read, decided, and do not block because the merge already happened" in a third, and the SAME
      # event came out 1 or 2 depending on the mode. 4 is "I could not read what exists", and for THIS reader
      # it is as blind as 2: nobody opened a label, so the sentence cannot assert anything.
      #
      # The two earlier versions were wrong, each in a different direction. The first joined `1|2` and
      # let three paths that read nothing reach the sentence that ASSERTS. The second sent all of 2
      # to `*)`, and since the gate's real case (merged without `review:passed`) came out
      # exactly 2, it started being answered with "only that nobody looked" about a pull request
      # read in full, while the historical sentence became unreachable. Measured on two real pull requests.
      #
      # What closes the blind paths is not this `case`: it is the gate returning 2 or 4 on them. The
      # Python version bail, the payload with no head, the undecipherable JSON and the unhandled exception came out
      # 1 or 2 depending on the mode and now come out 4 in both, which a test of the gate proves.
      # This branch trusts the contract, and a test of this script checks the other end with a stub
      # per code, including 4.
      1|3) ;;
      # **"without deciding" was false HERE, and true three guards above.** This branch is only
      # reached after the token matches, that is, after the gate proved it ran and that the
      # number it exits with is the one it chose itself. What did not happen was a LABEL READ
      # (1 and 3 are the only two codes that mean that). Sending whoever is debugging to look for a
      # gate that did not decide is sending them to look for a defect that does not exist.
      *) echo "review-cycle: #$NUMBER is MERGED and the gate proved it ran and answered $_rc — not one of the two codes that mean it read a label; this says nothing about the review, only that nobody looked"; return 2 ;;
    esac
    # Exit 2 and not 1: the Stop hook only speaks at rc=1, and with 1 here EVERY branch whose pull request
    # merged without `review:passed` would block the Stop forever (dozens of them, measured) over
    # a historical fact that no new work undoes. And the way out the hook offers in that state
    # is `publish --verdict PASSED`, that is: the harness pushing the FABRICATION that the cycle
    # exists to prevent. The fact is still printed, and the gate still reports it.
    echo "review-cycle: #$NUMBER MERGED without a valid review:passed — the loop closed after the merge, or not at all; this is recorded, not owed"
    return 2
  fi

  local short="${HEAD:0:12}"
  if [ -z "$LABEL" ]; then
    echo "#$NUMBER head $short — NO review:* label. Absence reads as not reviewed."
    echo "  next: /pr-reviewer over this diff, then review-cycle.sh publish ..."
    return 1
  fi
  case "$LABEL" in
    *" "*) echo "#$NUMBER carries several review states at once ($LABEL) — the projection has to project one thing"; return 1 ;;
  esac

  # A PASSED marker that counts a CRITICAL is the reviewer contradicting its own arithmetic, and it
  # is refused BEFORE the nothing-owed branch below. `PASSED` means nothing blocks, and a CRITICAL is
  # the only thing that blocks; the two statements cannot both be on the same line. Old markers carry
  # `-` here and skip the check entirely: they were written before anybody counted.
  if [ "$LABEL" = "review:passed" ] && [ "$MARKER_VERDICT" = "PASSED" ] \
     && positivo "${MARKER_CRITICAL:-}"; then
    echo "#$NUMBER head $short — the marker says PASSED and counts $MARKER_CRITICAL CRITICAL. Only a CRITICAL blocks, so a passing verdict cannot carry one."
    echo "  next: /pr-fixer on the critical findings, then /pr-reviewer again"
    return 1
  fi

  # The read side applies the write side's rule, or the two disagree about the same marker: a pass 1
  # `publish` accepts is a pass 1 `status` has to accept, otherwise the Stop hook keeps demanding a
  # review that already happened and the impasse just moves one command downstream.
  _pass_suficiente=no
  if [ "${MARKER_PASS:-0}" -ge 2 ] 2>/dev/null; then _pass_suficiente=yes
  elif [ "${MARKER_PASS:-0}" = 1 ] && [ "${MARKER_BLOCKED_SEEN:-no}" != "yes" ]; then _pass_suficiente=yes; fi

  if [ "$LABEL" = "review:passed" ] && [ -n "$MARKER_SHA" ] \
     && [ "${HEAD:0:${#MARKER_SHA}}" = "$MARKER_SHA" ] && [ "$MARKER_VERDICT" = "PASSED" ] \
     && [ "$_pass_suficiente" = yes ]; then
    echo "#$NUMBER head $short — reviewed, pass $MARKER_PASS, marker matches head. Nothing owed."
    # The debt is PRINTED, not owed. That distinction is the point: a warning and a note leave
    # the reviewer's hands as recorded debt with an owner, and a reader of this line sees what was
    # accepted rather than an approval that pretends there was nothing to accept.
    if positivo "${MARKER_WARNING:-}" || positivo "${MARKER_NOTE:-}"; then
      echo "  declared debt at this head: $MARKER_WARNING warning, $MARKER_NOTE note — recorded, not blocking"
    fi
    return 0
  fi

  case "$LABEL" in
    review:pending)
      echo "#$NUMBER head $short — never reviewed at this head."
      echo "  next: review-cycle.sh start $NUMBER  →  /pr-reviewer" ;;
    review:running)
      echo "#$NUMBER head $short — a pass is in flight. If it stays here, the pass died; that is information."
      echo "  next: finish the pass and publish, or re-run /pr-reviewer" ;;
    # The corrector's own state, symmetric to `review:running`. What it says that no other state can
    # is that the pull request is being CHANGED right now, so nothing about the current head is a
    # conclusion. If it stays here, the correction died, and that is information in the same way a
    # dead pass is.
    review:fixing)
      echo "#$NUMBER head $short — a correction is in flight. The head is about to move, so nothing here concludes anything."
      echo "  next: land the corrections, then /pr-reviewer again over the corrected diff (pass 2+)" ;;
    review:blocked)
      if [ -n "${HALTED:-}" ]; then
        echo "#$NUMBER head $short — findings open and the loop is halted; a person has to decide."
        echo "  next: a person fixes by hand or runs /pr-fixer, then review-cycle.sh start $NUMBER  →  /pr-reviewer"
      else
        echo "#$NUMBER head $short — findings open."
        echo "  next: /pr-fixer, then /pr-reviewer again over the corrected diff (pass 2+)"
      fi ;;
    review:passed)
      if [ -z "$MARKER_SHA" ]; then
        echo "#$NUMBER head $short — labelled passed with NO marker. A claim standing alone."
      elif [ "${HEAD:0:${#MARKER_SHA}}" != "$MARKER_SHA" ]; then
        echo "#$NUMBER head $short — the pass names ${MARKER_SHA:0:12}, which is no longer the head. A push invalidated it."
      elif [ "${MARKER_BLOCKED_SEEN:-no}" = "yes" ]; then
        echo "#$NUMBER head $short — passed at pass ${MARKER_PASS:-1}, and this pull request was BLOCKED once; the pass that approves a correction is the one that read it."
      else
        # The only other way to land here is a `pass=` this reader cannot compare: a marker posted
        # by hand or by an older script, carrying a number `numero` never saw. Saying "BLOCKED once"
        # about it would be this file asserting what it did not read, inside the branch that exists
        # to catch exactly that.
        echo "#$NUMBER head $short — the marker says pass ${MARKER_PASS:-1}, which is not a number this reader can compare, so nothing here is confirmed."
      fi
      echo "  next: /pr-reviewer over the CURRENT diff" ;;
  esac
  return 1
}

# The loop paused or stopped (the cycle budget is spent and the question is open, `stop`, or no
# answer) and what is left is a person's decision. `review:blocked` alone cannot say that: it is also the state a pull request is in
# while the fixer is about to run. This adds a modifier and moves nothing else. It refuses anything
# but an OPEN pull request in `review:blocked`, because a halt over any other state would be a claim
# the cycle does not back.
cmd_halt() {
  local reason="" pr=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --reason) reason="${2:-}"; shift 2 ;;
      *) pr="$1"; shift ;;
    esac
  done
  case "$reason" in ''|*[!A-Za-z0-9_.-]*) [ -z "$reason" ] || die "review-cycle: --reason takes letters, digits, dot, dash and underscore only" ;; esac
  marker_authors_ready || die "review-cycle: REFUSED. $NOT_READY_MSG"
  local json; json="$(pr_json "$pr")"; [ -n "$json" ] || die "review-cycle: no pull request to halt"
  parse "$json"
  [ "$STATE" = "OPEN" ] || die "review-cycle: #$NUMBER is $STATE — there is no loop left to halt"
  [ "$LABEL" = "review:blocked" ] || die "review-cycle: #$NUMBER is ${LABEL:-unlabelled}, not review:blocked — only a blocked pull request can need a person"
  # The marker goes first and the label second: a failed comment then leaves no label behind, so a
  # retry posts the marker again. The marker is skipped only when the newest TRUSTED extension marker
  # is already a halted one with this reason, which is the exact reading `budget` makes for the
  # ceiling; a label alone is not evidence of it (a person can add the label by hand).
  local posted=""
  if [ -n "$reason" ]; then
    local have
    have="$(printf '%s' "$json" | R="$reason" A="${REVIEW_MARKER_AUTHORS:-}" python3 -I -c '
import json, os, re, sys
allow = {x.strip().lower() for x in os.environ["A"].split(",") if x.strip()}
try:
    comments = json.load(sys.stdin).get("comments") or []
except ValueError:
    comments = []
last = None
for c in comments:
    who = str(((c or {}).get("author") or {}).get("login") or "").lower()
    m = re.match(r"<!-- pr-skill-extension: (state=[^>]*)-->", (c or {}).get("body") or "")
    if who in allow and m:
        last = dict(re.findall(r"([a-z_]+)=([^ >]+)", m.group(1)))
if last and last.get("state") == "halted" and last.get("reason") == os.environ["R"]:
    print("yes")
' 2>/dev/null)"
    if [ "$have" != "yes" ]; then
      printf '<!-- pr-skill-extension: state=halted reason=%s -->\npr-skill: halted on #%s (reason: %s). The pull request stays review:blocked and a person decides.\n' \
        "$reason" "$NUMBER" "$reason" | gh pr comment "$NUMBER" --body-file - >/dev/null \
        || die "review-cycle: the halted marker could not be posted on #$NUMBER; run it again"
      posted="yes"
    fi
  fi
  [ -z "${HALTED:-}" ] && { gh pr edit "$NUMBER" --add-label review:needs-human >/dev/null \
    || die "review-cycle: ${posted:+halted marker posted, but }could not add review:needs-human on #$NUMBER; labels may be missing: run review-cycle.sh ensure-labels"; }
  echo "#$NUMBER → review:needs-human (head ${HEAD:0:12})${posted:+, halted marker posted ($reason)}"
}

# The cycle budget, read from the trusted markers and nothing else. Prints one `B_<KEY>='<value>'`
# line per field. `B_NEXT` is what the loop does now:
#
#     fix      cycle `B_PASS` of at most `B_ALLOWED`: dispatch the fixer
#     ask      the automatic cycles are spent and a CRITICAL is open: ask a person (`extend` or halt)
#     ceiling  the hard ceiling was reached: halt, no answer passes it
#     none     nothing to do: no trusted verdict at the head, or the verdict there is not BLOCKED, or
#              the ceiling halt is already posted
#
# The cycle number is the `pass=` of the newest trusted marker at the head, never a constant. A
# granted extension is the newest `state=granted` marker by a trusted login: it allows `cycle + n`
# cycles in all, clamped to the hard ceiling. A `state=halted` marker other than the ceiling one
# does not stop a later run from asking again. `B_SUGGESTED` is the number of further cycles the
# progress supports: 3 when the open CRITICAL count fell in each of the last two cycles, 1 when it
# is lower than at pass 1 but did not keep falling, 0 otherwise, never more than what remains.
cmd_budget() {
  local json; json="$(pr_json "${1:-}")"; [ -n "$json" ] || die "review-cycle: no pull request to read a budget from"
  # Fail closed. With no author allowlist every commenter would be trusted, and a stranger's
  # `state=granted` comment would raise the budget. Unlike `status`, which only reads a verdict, the
  # budget decides whether agents keep editing the branch, so it refuses to guess.
  if ! marker_authors_ready; then
    printf "B_NEXT='none'\nB_WHY='REVIEW_MARKER_AUTHORS is not set or lists no login, so no marker is trusted and the budget is not read'\n"
    return 0
  fi
  printf '%s' "$json" | BUDGET_AUTHORS="${REVIEW_MARKER_AUTHORS:-}" BUDGET_MAX="${MAX_REVIEW_CYCLES:-5}" \
    BUDGET_HARD="${MAX_REVIEW_CYCLES_HARD:-10}" python3 -I -c '
import json, os, re, shlex, sys

def num(v, d):
    return int(v) if isinstance(v, str) and re.fullmatch(r"[0-9]+", v) else d

def fields(text):
    return {m.group(1): m.group(2) for m in re.finditer(r"([a-z_]+)=([^ >]+)", text)}

data = json.load(sys.stdin)
hard = min(max(num(os.environ["BUDGET_HARD"], 10), 1), 10)
mx = min(max(num(os.environ["BUDGET_MAX"], 5), 1), hard)
head = data.get("headRefOid") or ""
allow = [a.strip().lower() for a in os.environ["BUDGET_AUTHORS"].split(",") if a.strip()]
trusted = [c for c in data.get("comments", [])
           if not allow or str((c.get("author") or {}).get("login") or "").lower() in allow]

verdicts = []
for c in trusted:
    m = re.match(r"\s*<!--\s*adversarial-review:\s*(sha=[0-9a-f]{7,40}\s+verdict=(?:PASSED|BLOCKED)\s+pass=\d+"
                 r"(?:\s+critical=\d+\s+warning=\d+\s+note=\d+)?"
                 r"(?:\s+model=[A-Za-z0-9._:-]+\s+tier=(?:fast|standard|deep))?)\s*-->", c.get("body") or "", re.I)
    if not m:
        continue
    f = fields(m.group(1))
    if "pass" in f and "verdict" in f:
        verdicts.append({"sha": f["sha"], "verdict": f["verdict"].upper(), "pass": num(f["pass"], 0),
                         "critical": num(f["critical"], 0) if "critical" in f else None})
at = next((v for v in reversed(verdicts) if head.startswith(v["sha"])), None)

ext = []
for c in trusted:
    m = re.match(r"<!-- pr-skill-extension: (state=[^>]*)-->", c.get("body") or "")
    if m:
        ext.append(fields(m.group(1)))
last_ext = ext[-1] if ext else None
granted_marker = next((e for e in reversed(ext) if e.get("state") == "granted"), None)
granted = num(granted_marker.get("cycle"), 0) + num(granted_marker.get("n"), 0) if granted_marker else 0
allowed = min(max(mx, granted), hard)

last_per_pass = {}
for v in verdicts:
    last_per_pass[v["pass"]] = v
counts = [last_per_pass[p] for p in sorted(last_per_pass) if last_per_pass[p]["critical"] is not None]
xs = [v["critical"] for v in counts]
n = len(xs)
if n >= 3 and xs[n-3] > xs[n-2] > xs[n-1]:
    rule = 3
elif n >= 2 and xs[n-1] < xs[0]:
    rule = 1
else:
    rule = 0

done = 0 if at is None else at["pass"] - 1
remaining = max(hard - done, 0)
if at is None:
    nxt, why = "none", "no trusted verdict marker at the head"
elif at["verdict"] != "BLOCKED":
    nxt, why = "none", "verdict at the head is " + at["verdict"]
elif done < allowed:
    nxt, why = "fix", "cycle %d of at most %d" % (at["pass"], allowed)
elif done >= hard:
    if last_ext and last_ext.get("state") == "halted" and last_ext.get("reason") == "ceiling":
        nxt, why = "none", "the ceiling halt is already posted"
    else:
        nxt, why = "ceiling", "%d cycles done, the hard ceiling is %d" % (done, hard)
else:
    nxt, why = "ask", "%d cycles done, %d allowed" % (done, allowed)

out = {
    "next": nxt, "why": why,
    "verdict": at["verdict"] if at else "NONE", "pass": at["pass"] if at else 0,
    "crit": "" if not at or at["critical"] is None else at["critical"],
    "done": done, "allowed": allowed, "max": mx, "hard": hard, "remaining": remaining,
    "suggested": min(rule, remaining), "rule": rule,
    "progress": ", ".join("pass %d: %d" % (v["pass"], v["critical"]) for v in counts),
    "ext_state": (last_ext or {}).get("state", ""),
}
for k, v in out.items():
    print("B_%s=%s" % (k.upper(), shlex.quote(str(v))))
'
}

# Records that a person granted `--n` more cycles. It writes the one marker `budget` reads and
# refuses anything the budget would not honour: no CRITICAL open at the head, cycles that are not
# spent yet, or more than the hard ceiling leaves. The question itself is asked in the session, by
# the harness's own question tool; this only makes the answer outlive the session.
cmd_extend() {
  local pr="" n=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --n) n="${2:-}"; shift 2 ;;
      *) pr="$1"; shift ;;
    esac
  done
  case "$n" in ''|*[!0-9]*) die "review-cycle: extend needs --n <whole number>" ;; esac
  local json; json="$(pr_json "$pr")"; [ -n "$json" ] || die "review-cycle: no pull request to extend"
  parse "$json"
  [ "$STATE" = "OPEN" ] || die "review-cycle: #$NUMBER is $STATE — there is no loop to extend"
  local b; b="$(cmd_budget "$NUMBER")" || die "review-cycle: could not read the budget on #$NUMBER"
  local B_NEXT="" B_DONE="" B_REMAINING="" B_HARD=""
  eval "$b"
  [ "$B_NEXT" = "ask" ] || die "review-cycle: #$NUMBER is not waiting for an extension (budget says: $B_NEXT)"
  [ "$n" -ge 1 ] && [ "$n" -le "$B_REMAINING" ] || die "review-cycle: --n must be between 1 and $B_REMAINING (the hard ceiling is $B_HARD, $B_DONE cycles are done)"
  printf '<!-- pr-skill-extension: state=granted cycle=%s n=%s -->\npr-skill: %s more review-fix cycles granted on #%s after cycle %s.\n' \
    "$B_DONE" "$n" "$n" "$NUMBER" "$B_DONE" | gh pr comment "$NUMBER" --body-file - >/dev/null \
    || die "review-cycle: could not post the granted marker on #$NUMBER"
  echo "#$NUMBER → $n more cycles granted after cycle $B_DONE (allowed becomes $((B_DONE + n)))"
}

# Debt, reduced to an exit code, for hooks and CI. Prints nothing on success.
cmd_debt() { cmd_status "${1:-}" >/dev/null 2>&1; return $?; }

cmd_start() {
  local json; json="$(pr_json "${1:-}")"; [ -n "$json" ] || die "review-cycle: no pull request to start on"
  parse "$json"
  gh pr edit "$NUMBER" --add-label review:running ${HALTED:+--remove-label review:needs-human} \
      $( [ -n "$LABEL" ] && [ "$LABEL" != "review:running" ] && printf -- "--remove-label %s" "$LABEL" ) >/dev/null \
    || die "review-cycle: could not move the label on #$NUMBER; labels may be missing: run review-cycle.sh ensure-labels"
  echo "#$NUMBER → review:running (head ${HEAD:0:12})"
}

# The mechanical barrier in front of the fixer's writes (ISO 27001 A.8.28, task B). A script cannot
# sandbox the agent's own tool calls: isolation of the tests the fixer runs belongs to the harness.
# What a script CAN do is refuse to start a correction on code the person did not write or accept.
#
# It builds the set of principals (the pull request author and the author of every commit on the
# pull request) and refuses unless each one is a collaborator with `write`, `maintain` or `admin`
# permission on the repository. Fail closed: a fork, a commit with no linked GitHub login, a
# lookup that errors, a bot, or any lower permission refuses. `FIXER_TRUSTED_LOGINS` (comma
# separated) names logins allowed without a lookup, for a bot the repository owns. Base-branch merge
# commits are covered because their authors are resolved like any other.
fix_guard() {
  FG_PR="$1" FG_TRUSTED="${FIXER_TRUSTED_LOGINS:-}" python3 -I - <<'PY'
import json, os, subprocess, sys

pr = os.environ["FG_PR"]
trusted = {x.strip().lower() for x in os.environ["FG_TRUSTED"].split(",") if x.strip()}
OK = {"admin", "maintain", "write"}

def gh(*args):
    try:
        r = subprocess.run(("gh",) + args, capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return r.stdout if r.returncode == 0 else None

def refuse(msg):
    print("review-cycle: REFUSED. " + msg, file=sys.stderr)
    sys.exit(1)

out = gh("pr", "view", pr, "--json", "isCrossRepository,author")
try:
    meta = json.loads(out or "")
except ValueError:
    refuse("could not read who wrote #%s, and an unreadable author is not a trusted one" % pr)
if not isinstance(meta.get("isCrossRepository"), bool):
    refuse("could not tell whether #%s comes from a fork, and an unknown origin is not a trusted one" % pr)
if meta.get("isCrossRepository"):
    refuse("#%s comes from a fork. The fixer does not edit or run code from a fork." % pr)
principals = {}
author = ((meta.get("author") or {}).get("login") or "")
principals[author] = "the pull request author"
raw = gh("api", "repos/{owner}/{repo}/pulls/%s/commits" % pr, "--paginate")
if raw is None:
    refuse("could not list the commits of #%s, so their authors cannot be checked" % pr)
dec, i, commits = json.JSONDecoder(), 0, []
raw = raw.strip()
try:
    while i < len(raw):
        part, j = dec.raw_decode(raw, i)
        commits.extend(part if isinstance(part, list) else [part])
        i = j
        while i < len(raw) and raw[i].isspace():
            i += 1
except ValueError:
    refuse("the commit list of #%s was not JSON" % pr)
if len(commits) >= 250:
    refuse("#%s has 250 or more commits, the most this check can list, so some authors would go unchecked" % pr)
for c in commits:
    login = ((c.get("author") or {}).get("login") or "") if isinstance(c, dict) else ""
    principals.setdefault(login, "commit %s" % str((c or {}).get("sha", "?"))[:7])
for login, why in principals.items():
    if not login:
        refuse("%s has no linked GitHub login, so the fixer cannot tell who wrote it." % why)
    if login.lower() in trusted:
        continue
    perm = gh("api", "repos/{owner}/{repo}/collaborators/%s/permission" % login, "--jq", ".permission")
    if perm is None:
        refuse("could not confirm that %s (%s) is a collaborator with write access. A bot or an "
               "outside contributor is refused; list a bot you own in FIXER_TRUSTED_LOGINS." % (login, why))
    if perm.strip() not in OK:
        refuse("%s (%s) has permission '%s' here, and the fixer only edits code written by "
               "collaborators with write access or higher." % (login, why, perm.strip()))
PY
}

# The corrector's `start`, and the two writes are the same two writes for the same reason.
#
# **WHY IT EXISTS, measured.** `cmd_start` takes the cycle for the reviewer and drops
# `review:needs-human` in the same call: the claim "a person has to decide" is withdrawn the moment
# the cycle is taken again. Nothing did that for the corrector, and the gap is
# not symmetric-looking, it is dangerous: when a `/pr-fixer` starts, the head has not
# moved yet, so `review:passed` is still true about the COMMIT and already false about the
# INTENTION. `cmd_stale`, the one thing that retires a claim the head outgrew, cannot help: it acts
# only after a push, and the whole window is before the push.
#
# **Pull requests merged inside that window**, carrying `review:passed`
# while correctors were working, and the corrections stayed on disk and
# never reached the base branch: among them a security guard and a defect that locked users out.
# Each needed a rescue pull request, which is the expensive way to discover that a label was
# answering a question about a commit while the reader was asking one about the work.
#
# So the corrector says so out loud, and `review:fixing` is what says it. This function does not
# review, does not correct and does not judge: it moves a label and removes a claim.
cmd_fix() {
  local json; json="$(pr_json "${1:-}")"; [ -n "$json" ] || die "review-cycle: no pull request to fix on"
  parse "$json"
  # **Mirrors the check `cmd_stale` already makes before writing anything** (`[ "$STATE" = "OPEN" ]
  # || return 0`), and for the same reason `cmd_publish` refuses a non-OPEN state outright: a pull
  # request that already merged or closed has no cycle left to claim. Without this, `fix` on a
  # MERGED pull request labelled it `review:fixing` anyway, and `gate-pr-review-state.py` reads that
  # label on a merged pull request as "a correction was in flight when the merge happened, so look
  # for corrections that never landed", a specific, false forensic trail about a correction that
  # never existed, produced by a label applied by mistake after the fact.
  [ "$STATE" = "OPEN" ] || die "review-cycle: #$NUMBER is $STATE — there is no cycle to claim on a pull request that already merged or closed"
  # Before any label moves: a refused correction leaves the pull request exactly as it was.
  fix_guard "$NUMBER" || die "review-cycle: #$NUMBER was not claimed for correction"
  gh pr edit "$NUMBER" --add-label review:fixing ${HALTED:+--remove-label review:needs-human} \
      $( [ -n "$LABEL" ] && [ "$LABEL" != "review:fixing" ] && printf -- "--remove-label %s" "$LABEL" ) >/dev/null \
    || die "review-cycle: could not move the label on #$NUMBER; labels may be missing: run review-cycle.sh ensure-labels"
  echo "#$NUMBER → review:fixing (head ${HEAD:0:12})${HALTED:+, review:needs-human withdrawn}"
}

# A push over a reviewed head does not make the review wrong; it makes it about another commit.
# Resetting to `pending` REMOVES a claim, which is why it is safe to do without asking.
cmd_stale() {
  local json; json="$(pr_json "${1:-}")"; [ -n "$json" ] || return 2
  parse "$json"
  [ "$STATE" = "OPEN" ] || return 0
  [ -n "$LABEL" ] || return 0
  # `pending` has nothing to retire. `running` is the one that looks stale and is not: a pass in
  # flight has published no marker yet, so the newest marker on the pull request belongs to a
  # PREVIOUS pass and naming an older commit is exactly what it should do. Comparing it to the head
  # retired a live pass once while the head had not moved at all: the hook cancelling the
  # review it had just asked for. Only a marker-backed state can go stale.
  #
  # **`review:fixing` is NOT in that exemption, and it is the state's exit door.** It looks like
  # `running` (somebody is working) and it is the opposite case: the marker that stands on the
  # pull request is the BLOCKED one from the pass that DEMANDED the correction, so it is
  # marker-backed, and the correction landing is precisely what moves the head past it. Retiring it
  # here is the whole transition out: the corrector pushes, `fixing` goes back to `pending`, and
  # `review:needs-human` goes with it if it was standing.
  case "$LABEL" in review:pending|review:running|*" "*) return 0 ;; esac
  [ -n "$MARKER_SHA" ] || return 0
  if [ "${HEAD:0:${#MARKER_SHA}}" != "$MARKER_SHA" ]; then
    gh pr edit "$NUMBER" --remove-label "$LABEL" ${HALTED:+--remove-label review:needs-human} \
        --add-label review:pending >/dev/null 2>&1 \
      && echo "#$NUMBER: head moved past ${MARKER_SHA:0:12} — $LABEL → review:pending"
  fi
}

# **A report is posted to a place other people read, so it is screened before it leaves.** A token
# pasted into a finding (a reviewer quoting a diff line that holds a key) becomes public the moment
# `publish` posts it. Redacting by regex has missed loose tokens in other tools, so this refuses
# instead: the report is never rewritten, and the person or agent removes the secret and publishes
# again. The match itself is never printed. High-entropy strings are not screened: a 40-character
# commit SHA is the commonest thing in a report and would be refused every time.
report_secrets() {
  X_FILE="$1" python3 -I - <<'PY'
import os, re, sys
text = open(os.environ["X_FILE"], encoding="utf-8", errors="replace").read()
pats = {
    "GitHub token": r"(?<![A-Za-z0-9])(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})",
    "AWS access key id": r"(?<![A-Za-z0-9])(?:AKIA|ASIA)[0-9A-Z]{16}(?![A-Za-z0-9])",
    "private key block": r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----",
    "Slack token": r"(?<![A-Za-z0-9])xox[abprs]-[A-Za-z0-9-]{10,}",
    "API key (sk-...)": r"(?<![A-Za-z0-9])sk-[A-Za-z0-9_-]{20,}",
    "Stripe key": r"(?<![A-Za-z0-9])[sr]k_(?:live|test)_[A-Za-z0-9]{16,}",
    "Google API key": r"(?<![A-Za-z0-9])AIza[0-9A-Za-z_-]{35}",
    "JSON web token": r"(?<![A-Za-z0-9])eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}",
    "npm token": r"(?<![A-Za-z0-9])npm_[A-Za-z0-9]{36}",
    "GitLab token": r"(?<![A-Za-z0-9])glpat-[A-Za-z0-9_-]{20,}",
    "Google OAuth token": r"(?<![A-Za-z0-9])ya29\.[A-Za-z0-9_-]{20,}",
    "bearer credential": r"(?i)\bauthorization:\s*bearer\s+[^\s`'\"]{20,}",
}
hits = [name for name, p in pats.items() if re.search(p, text)]
if hits:
    print(", ".join(hits))
    sys.exit(1)
PY
}

# Wraps a bare @login in backticks so posting the report does not notify anyone. It reads the report
# the way CommonMark does, in two linear passes. Blocks: a fence closes only on a line of the same
# character, at least as long as the opener, with nothing after it; a list item, quote line, table
# row, heading or rule starts a new block, and an inline code span never crosses a block boundary.
# Inline: a code span runs from a run of N backticks to the next run of exactly N, found by index
# (no backtracking); a backslash-escaped backtick opens nothing. Fenced blocks and code spans are
# left alone, and so is an address like a@b.example or a path like a/@b, because a word character
# or a slash comes before the @. When in doubt it wraps: an extra pair of backticks is cosmetic, a
# bare mention notifies someone.
report_mentions() {
  python3 -I -c '
import bisect, re, sys
MENTION = re.compile(r"(?<![\w@/])@(?P<m>[A-Za-z0-9][A-Za-z0-9-]{0,38}(?:/[A-Za-z0-9_-]+)?)")
RUN = re.compile(r"`+")
PREFIX = re.compile(r"^(?:\s*(?:>|(?:[-+*]|\d{1,9}[.)])(?=\s)))*\s*")
FENCE = re.compile(r"^(`{3,}|~{3,})(.*)$")
START = re.compile(r"^\s*(?:>|\||[-+*](?:\s|$)|\d{1,9}[.)](?:\s|$)|#{1,6}(?:\s|$))")
SINGLE = re.compile(r"^(?: {0,3}#{1,6}(?:\s|$)| {0,3}([-*_])(?:\s*\1){2,}\s*$)")
def wrap(t):
    return MENTION.sub(lambda m: "`@" + m.group("m") + "`", t)
def inline(t):
    runs = [(m.start(), m.end()) for m in RUN.finditer(t)]
    by = {}
    for i, (a, b) in enumerate(runs):
        by.setdefault(b - a, []).append(i)
    out, pos, i = [], 0, 0
    while i < len(runs):
        a, b = runs[i]
        n, k = b - a, a
        while k > pos and t[k - 1] == "\\":
            k -= 1
        if (a - k) % 2:
            a, n = a + 1, n - 1
        if n:
            idx = by.get(n, [])
            at = bisect.bisect_right(idx, i)
            if at < len(idx):
                j = idx[at]
                out.append(wrap(t[pos:a]))
                out.append(t[a:runs[j][1]])
                pos, i = runs[j][1], j
        i += 1
    out.append(wrap(t[pos:]))
    return "".join(out)
out, seg, fence = [], [], None
def flush():
    if seg:
        out.append(inline("\n".join(seg)))
        seg.clear()
for ln in sys.stdin.read().split("\n"):
    s = PREFIX.sub("", ln, count=1)
    m = FENCE.match(s)
    if fence is not None:
        out.append(ln)
        if m and m.group(1)[0] == fence[0] and len(m.group(1)) >= len(fence) and not m.group(2).strip():
            fence = None
        continue
    if m and not (m.group(1)[0] == "`" and "`" in m.group(2)):
        flush(); fence = m.group(1); out.append(ln); continue
    if not ln.strip():
        flush(); out.append(ln); continue
    if START.match(ln) or SINGLE.match(ln):
        flush()
    seg.append(ln)
    if SINGLE.match(ln):
        flush()
flush()
sys.stdout.write("\n".join(out))'
}

cmd_publish() {
  local verdict="" passno="" sha="" report="" number="" crit="" warn="" note="" model="" tier=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --verdict)  verdict="$2"; shift 2 ;;
      --pass)     passno="$2";  shift 2 ;;
      --sha)      sha="$(printf '%s' "$2" | tr 'A-Z' 'a-z')"; shift 2 ;;
      --report)   report="$2";  shift 2 ;;
      --critical) crit="$2";    shift 2 ;;
      --warning)  warn="$2";    shift 2 ;;
      --note)     note="$2";    shift 2 ;;
      --model)    model="$2";   shift 2 ;;
      --tier)     tier="$2";    shift 2 ;;
      *)          number="$1";  shift ;;
    esac
  done
  case "$verdict" in PASSED|BLOCKED) ;; *) die "review-cycle: --verdict must be PASSED or BLOCKED" ;; esac
  [ -n "$passno" ] || die "review-cycle: --pass is required"
  # Validated as digits BEFORE any numeric comparison touches it. Under `set -uo pipefail` (no
  # `-e`), `[ abc -lt 2 ]` is not false: it is an ERROR (status 2), and the `&&` chain that used
  # to run this check directly short-circuited past `die` on any non-numeric --pass, publishing
  # `review:passed` with a marker the gate can never parse back (`pass=(\d+)` does not match
  # `pass=abc`). A format check first turns that error into a refusal.
  numero --pass "$passno"
  [ -n "$sha" ]    || die "review-cycle: --sha is required — it is what binds the marker to a real commit"
  # 40 hex characters, exactly: a Git SHA-1 is never shorter. Accepting any prefix let `--sha 9`
  # pass whenever the head happened to start with "9"; the comparison below is now EXACT, so this
  # format check is what makes "exact" meaningful rather than "exact against a string nobody
  # validated the length of".
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die "review-cycle: --sha must be a full 40-character hex commit SHA, got '$sha'"
  [ -s "$report" ] || die "review-cycle: --report must name a file that exists AND is not empty; the report is the evidence, and an empty file is none"
  local leaked
  leaked="$(report_secrets "$report")" || die "review-cycle: REFUSED. The report looks like it contains a secret ($leaked).
   A comment on a pull request is public to everyone who can read it. Replace the value with
   [REDACTED] in the report, then publish again. The report was not changed and nothing was posted."

  # **Required when WRITING, optional when READING.** A marker published now carries all three
  # counts; a marker published by an older script carries none, and the readers above still take it. The
  # asymmetry is deliberate: relaxing the write side would let a new marker be posted without the one
  # number the verdict is checked against, and tightening the read side would retroactively unreview
  # every pull request already reviewed.
  [ -n "$crit" ] && [ -n "$warn" ] && [ -n "$note" ] || \
    die "review-cycle: --critical, --warning and --note are required — the verdict is checked against the counts, and a verdict with no counts is the sentence that produced the impasse"
  numero --critical "$crit"
  numero --warning  "$warn"
  numero --note     "$note"

  # **This pair of refusals is the whole of the arithmetic rule, and it lives here rather than only
  # in the skill because the skill already said it.** The reviewer skill has defined
  # `BLOCK = 1+ CRITICAL` since its first version, and a measured cycle (many passes, dozens of
  # findings, zero approvals, zero criticals) blocked on every one of them anyway. A rule written
  # in prose and checked nowhere is a rule the next pass restates and breaks again.
  [ "$verdict" = "BLOCKED" ] && [ "$crit" -eq 0 ] && \
    die "review-cycle: REFUSED. BLOCKED needs at least one CRITICAL, and this marker counts none.
   A CRITICAL is data loss, a security hole, a production outage, or a broken invariant the project
   declares non-negotiable (for example in its constitution, CLAUDE.md or AGENTS.md). Warnings and
   notes are DEBT: publish PASSED with the counts, and declare them in the pull request with an
   owner."
  [ "$verdict" = "PASSED" ] && [ "$crit" -gt 0 ] && \
    die "review-cycle: REFUSED. PASSED cannot carry a CRITICAL, and this marker counts $crit.
   Only a CRITICAL blocks, so a passing verdict beside one is the verdict contradicting the
   arithmetic that produced it. Close them with /pr-fixer and review the correction."

  marker_authors_ready || die "review-cycle: REFUSED. $NOT_READY_MSG"
  local json; json="$(pr_json "$number")"; [ -n "$json" ] || die "review-cycle: no pull request to publish on"
  parse "$json"

  # **A verdict is not published on what already merged**, and this guard lives HERE because here
  # it is already known which pull request is being talked about. Its first version ran a SECOND argument
  # parser above, which disagreed with the real one right below: `--x 51`, `-- 51` and `--report=file`
  # made the two see different pull requests, and so the guard judged one and `publish`
  # wrote to the other. Two parsers for the same thing is a disagreement waiting to happen;
  # `$STATE` comes from the `parse` that `publish` itself uses, so there is no way to diverge.
  #
  # What this prevents: a verdict stamped after the merge is a review that could no longer change
  # anything, and the Stop hook even went so far as to SUGGEST it as a way out: the harness pushing
  # the fabrication that the cycle exists to prevent.
  [ "$STATE" = "OPEN" ] || die "review-cycle: #$NUMBER is $STATE — a verdict stamped after the merge is a review that could not change anything, which is what the review cycle forbids"

  # **`publish` never read `$LABEL` before this line, so a pull request in `review:fixing` (the
  # corrector's OWN state, which `cmd_status` already describes as "the head is about to move, so
  # nothing here concludes anything") could be stamped `review:passed`
  # anyway. That is the merged-while-fixing shape rebuilt from inside the mechanism meant to
  # close it: a green
  # "may merge" beside corrections still sitting on disk, unbound by anything checking the one label
  # that says the head is not staying still. `start` is the legitimate way off `fixing`: it already
  # replaces the label and drops `review:needs-human` with it (see `cmd_start` above), so the
  # refusal names it as the next step instead of leaving the caller to guess.
  # Matched against the padded string, not by equality: `parse()` joins the states it finds with a
  # space, so two labels at once arrive here as one string. Equality would miss that and let the
  # marker through, failing OPEN in the one case where the pull request is most confused about
  # itself. `cmd_stale` bails on `*" "*` for the same reason.
  case " $LABEL " in *" review:fixing "*) die "review-cycle: REFUSED. #$NUMBER is review:fixing — a correction is in flight and the head is about to move, so nothing at this head concludes anything.
   Publishing a verdict now binds review:passed to a commit the correction is still rewriting.
   Run review-cycle.sh start $NUMBER to take the cycle back before /pr-reviewer runs." ;; esac

  # The whole anti-fabrication property lives in this comparison. It is EXACT now, not a prefix:
  # `sha` is already validated as a full 40-hex string above, so this is `$HEAD = $sha` or nothing.
  if [ "$HEAD" != "$sha" ]; then
    die "review-cycle: REFUSED. The review names ${sha:0:12}; the head is now ${HEAD:0:12}.
   Someone pushed while the pass ran, so the report is about a commit that is no longer up for merge.
   Re-run /pr-reviewer over the current diff. This is not a formality: publishing here is
   exactly the green-that-proves-nothing result a CI check exists to catch."
  fi

  # **`pass>=2` was never about the number, and reading it as a number closed the only door a clean
  # first pass had.** Once `BLOCKED` requires a CRITICAL, a pass 1 that counts none is the EXPECTED
  # outcome, not an oddity, and the script refused it both ways: `BLOCKED` for having no CRITICAL,
  # `PASSED` for not being a second pass. The first approved verdict a clean review produced
  # could not be published; the reviewer sat in that impasse trying to publish its own.
  #
  # The stated reason for the bar is the whole of it: *the second pass reviews the CORRECTION*. Where
  # nothing blocked, nothing was corrected, and asking for a second pass is asking someone to review
  # nothing. So the bar now applies exactly where its own sentence is true: a `BLOCKED` marker
  # stands on this pull request, so a correction exists and the cycle wants the reviewer to have
  # read THAT one. That invariant is the heart of the rule and is not what changed here.
  #
  # It is read from the marker history rather than from the label, because the label carries one
  # state at a time and `publish` is itself the thing about to overwrite it.
  if [ "$verdict" = "PASSED" ] && [ "$passno" -lt 2 ] && [ "${MARKER_BLOCKED_SEEN:-no}" = "yes" ]; then
    die "review-cycle: REFUSED. PASSED at pass $passno, and #$NUMBER already carries a BLOCKED marker.
   A correction was demanded, so there IS one to review, and the cycle wants the reviewer to have
   read it: publish the approval from pass 2 or later, over the corrected diff. Pass 1 may approve
   only where nothing ever blocked, because there a second pass would be reviewing nothing."
  fi

  # **The size refusal, and it has to come before the comment because the comment comes first.**
  # GitHub rejects a comment body over 65536 characters. The comment is posted before the label
  # moves (that order is deliberate: a label never claims a verdict that is not on the pull request),
  # so a rejected body leaves the pull request at `review:running` with no marker, a pass that looks
  # like it died in flight. Measured in bytes, which are never fewer than characters, so the count
  # can only overstate the length; the bar sits at 60000 to keep a margin below the hard limit.
  # Model id and tier are self-attested by the publishing session and are never verified here. They
  # are optional and come as a pair, so an old marker (without them) and a new one both read.
  local model_part=""
  if [ -n "$model$tier" ]; then
    [ -n "$model" ] && [ -n "$tier" ] || die "review-cycle: --model and --tier go together"
    case "$model" in ''|*[!A-Za-z0-9._:-]*) die "review-cycle: --model takes letters, digits, dot, colon, dash and underscore only" ;; esac
    [ "${#model}" -le 64 ] || die "review-cycle: --model is longer than 64 characters"
    case "$tier" in fast|standard|deep) ;; *) die "review-cycle: --tier is one of fast, standard, deep" ;; esac
    model_part=" model=$model tier=$tier"
  fi
  local marker_line body_bytes
  marker_line="$(printf '<!-- adversarial-review: sha=%s verdict=%s pass=%s critical=%s warning=%s note=%s%s -->' \
      "$HEAD" "$verdict" "$passno" "$crit" "$warn" "$note" "$model_part")"
  body_bytes=$(( $(printf '%s\n\n' "$marker_line" | wc -c) + $(wc -c <"$report") ))
  if [ "$body_bytes" -gt 60000 ]; then
    die "review-cycle: REFUSED. The marker plus the report is $body_bytes bytes, and the limit here is 60000.
   GitHub rejects a comment body over 65536 characters, and a rejected comment leaves #$NUMBER at
   review:running with no marker. Shorten the report: keep the findings block in it, and move long
   prose to a second comment or to a job artifact, then publish again."
  fi

  local label="review:blocked"; [ "$verdict" = "PASSED" ] && label="review:passed"
  # Any new verdict ends a halt: the person's decision, or the loop's next pass, supersedes it.
  local halted_rm=""
  [ -n "${HALTED:-}" ] && halted_rm="--remove-label review:needs-human"
  { printf '%s\n\n' "$marker_line"
    report_mentions <"$report"; } | gh pr comment "$NUMBER" --body-file - >/dev/null \
    || die "review-cycle: could not post the marker on #$NUMBER"
  gh pr edit "$NUMBER" --add-label "$label" $halted_rm \
      $( [ -n "$LABEL" ] && [ "$LABEL" != "$label" ] && printf -- "--remove-label %s" "$LABEL" ) >/dev/null \
    || die "review-cycle: marker posted but the label did not move on #$NUMBER; fix by hand; labels may be missing: run review-cycle.sh ensure-labels, then move the label to $label"
  echo "#$NUMBER → $label${halted_rm:+, review:needs-human withdrawn}, marker bound to ${HEAD:0:12}, pass $passno, critical=$crit warning=$warn note=$note"
  # An approved pull request stops being a draft. This is the one thing publish does beyond the
  # marker and the label, and only after both are written, so the gate (which starts on
  # ready_for_review) already finds the marker. A failure here is reported and does not undo the
  # verdict: the marker is the authority, the draft flag is a convenience.
  if [ "$verdict" = "PASSED" ] && [ -n "${IS_DRAFT:-}" ]; then
    if gh pr ready "$NUMBER" >/dev/null 2>&1; then
      echo "  #$NUMBER was a draft: marked ready for review"
    else
      echo "review-cycle: verdict published, but #$NUMBER could not be marked ready for review; run: gh pr ready $NUMBER" >&2
    fi
  fi
  [ "$verdict" = "PASSED" ] && { positivo "$warn" || positivo "$note"; } && \
    echo "  declared debt: $warn warning, $note note — name an owner for each in the pull request body; passed means nothing blocks, not that nothing was found"
  audit_append "$NUMBER" "$passno" "$HEAD" "$verdict" "$crit" "$warn" "$note" "${model:--}" "${tier:--}"
  return 0
}

# A convenience copy of what was just published, one JSON line per verdict, on this machine only:
# `${XDG_STATE_HOME:-$HOME/.local/state}/pr-reviewer-fixer/audit.jsonl`. It is NOT evidence. The
# marker on the pull request is the authority, and this file can be edited or lost with the laptop.
# A failure to write it is a warning and never undoes the verdict.
audit_append() {
  local dir file who ts
  dir="${XDG_STATE_HOME:-${HOME:-}/.local/state}/pr-reviewer-fixer"
  file="$dir/audit.jsonl"
  who="$(gh api user --jq .login 2>/dev/null)" || who=""
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if ! { mkdir -p "$dir" && A_PR="$1" A_PASS="$2" A_SHA="$3" A_VERDICT="$4" A_CRIT="$5" A_WARN="$6" A_NOTE="$7" \
         A_MODEL="$8" A_TIER="$9" A_WHO="$who" A_TS="$ts" python3 -I -c '
import json, os
e = os.environ
n = lambda k: None if e[k] in ("", "-") else e[k]
print(json.dumps({"pr": int(e["A_PR"]), "pass": int(e["A_PASS"]), "sha": e["A_SHA"],
    "verdict": e["A_VERDICT"], "critical": int(e["A_CRIT"]), "warning": int(e["A_WARN"]),
    "note": int(e["A_NOTE"]), "model": n("A_MODEL"), "tier": n("A_TIER"),
    "publisher": n("A_WHO"), "published_at": e["A_TS"]}, sort_keys=True))' >>"$file"; } 2>/dev/null; then
    echo "review-cycle: warning: the local audit copy could not be written to $file; the marker on #$1 is the record" >&2
  fi
}

# Exports what the pull request itself says about one review, as a JSON file a person commits
# through a pull request (`docs/compliance-records/<pr>-<pass>.json`). It decides from the same
# trust rules as `status` and the gate: an author on `REVIEW_MARKER_AUTHORS`, a comment never edited
# after it was created (pr-json.py), and a refusal when the allowlist is empty or lists no login. It
# REFUSES when no trusted marker remains, and when the head moved after the last trusted marker,
# so a record never pairs one commit's verdict with another head. Markers that were posted by
# someone off the list are listed under `ignored`, with the reason, and never used.
#
# Model id and tier are copied from the marker as they are: self-attested by the publishing
# session, never verified. Everything else (sha, counts, publisher, timestamps, label events)
# comes from GitHub.
cmd_export_audit() {
  local pr="" out="docs/compliance-records"
  while [ $# -gt 0 ]; do
    case "$1" in
      --out) out="${2:-}"; shift 2 ;;
      *) pr="$1"; shift ;;
    esac
  done
  marker_authors_ready || die "review-cycle: REFUSED. $NOT_READY_MSG"
  local json; json="$(pr_json "$pr")"; [ -n "$json" ] || die "review-cycle: could not read the pull request, or its comment edits could not be checked"
  parse "$json"
  local events
  events="$(gh api "repos/{owner}/{repo}/issues/$NUMBER/events?per_page=100" --paginate 2>/dev/null)" \
    || die "review-cycle: could not read the timeline of #$NUMBER, and an export without it would be incomplete"
  mkdir -p "$out" 2>/dev/null || die "review-cycle: cannot create $out"
  X_JSON="$json" X_EVENTS="$events" X_AUTHORS="${REVIEW_MARKER_AUTHORS:-}" X_OUT="$out" python3 -I - <<'PY' || exit 1
import json, os, re, sys

MARK = re.compile(
    r"^\s*<!--\s*adversarial-review:\s*sha=([0-9a-f]{7,40})\s+verdict=(PASSED|BLOCKED)\s+pass=(\d+)"
    r"(?:\s+critical=(\d+)\s+warning=(\d+)\s+note=(\d+))?"
    r"(?:\s+model=([A-Za-z0-9._:-]+)\s+tier=(fast|standard|deep))?\s*-->", re.I)

def die(msg):
    print("review-cycle: REFUSED. " + msg, file=sys.stderr)
    sys.exit(1)

pr = json.loads(os.environ["X_JSON"])
allow = {re.sub(r"\s+", "", x).lower() for x in os.environ["X_AUTHORS"].split(",")} - {""}
head = (pr.get("headRefOid") or "").lower()
trusted, ignored = [], []
for c in pr.get("comments", []):
    m = MARK.match(c.get("body") or "")
    if not m:
        continue
    who = ((c.get("author") or {}).get("login") or "")
    if who.lower() in allow:
        trusted.append((c, m))
    else:
        ignored.append({"reason": "author is not in REVIEW_MARKER_AUTHORS", "author": who or None,
                        "created_at": c.get("createdAt"), "url": c.get("url")})
if not trusted:
    die("no trusted marker remains on #%s, so there is nothing to export." % pr.get("number"))
c, m = trusted[-1]
if m.group(1).lower() != head:
    die("the head of #%s is %s but the last trusted marker names %s: the head moved after the "
        "review, so a record would pair one commit's verdict with another head. Run the loop again."
        % (pr.get("number"), head[:12], m.group(1)[:12]))
try:
    # `gh api --paginate` prints one JSON array per page, back to back, so decode them one by one.
    dec, i, raw, events = json.JSONDecoder(), 0, os.environ["X_EVENTS"].strip(), []
    while i < len(raw):
        part, j = dec.raw_decode(raw, i)
        events.extend(part if isinstance(part, list) else [part])
        i = j
        while i < len(raw) and raw[i].isspace():
            i += 1
except ValueError:
    die("the timeline of #%s was not JSON." % pr.get("number"))
labels = [{"event": e.get("event"), "label": (e.get("label") or {}).get("name"),
           "actor": (e.get("actor") or {}).get("login"), "at": e.get("created_at")}
          for e in events if e.get("event") in ("labeled", "unlabeled")]
rec = {
    "schema": 1,
    "pr": pr.get("number"), "head": head, "pass": int(m.group(3)), "verdict": m.group(2).upper(),
    "critical": int(m.group(4)) if m.group(4) else None,
    "warning": int(m.group(5)) if m.group(5) else None,
    "note": int(m.group(6)) if m.group(6) else None,
    "model": m.group(7), "tier": m.group(8), "model_and_tier_self_attested": True,
    "publisher": (c.get("author") or {}).get("login"), "published_at": c.get("createdAt"),
    "marker_url": c.get("url"),
    "label_events": labels,
    "ignored": ignored,
    "comments_dropped_for_edits": pr.get("commentsDroppedEdited", 0),
}
path = os.path.join(os.environ["X_OUT"], "%s-%s.json" % (pr.get("number"), m.group(3)))
tmp = path + ".tmp"
with open(tmp, "w") as fh:
    json.dump(rec, fh, indent=2, sort_keys=True)
    fh.write("\n")
os.replace(tmp, path)
print(path)
PY
}

# Checks the `findings` block of a report against the diff it claims to review, before `publish`.
# A finding must name a file the diff touches, and a line the diff shows (a hunk's new side). The
# `counts:` line must equal the number of entries still open, and the coverage note must carry a
# `Declined to judge:` line. Nothing here posts or labels.
#
# Exit 0 = every finding is anchored · 1 = at least one is not, or the report has no findings
# block · 2 = the diff or the report could not be read.
cmd_lint_report() {
  local pr="" report="" diff=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --report) report="${2:-}"; shift 2 ;;
      --diff)   diff="${2:-}"; shift 2 ;;
      *) pr="$1"; shift ;;
    esac
  done
  [ -s "$report" ] || { echo "review-cycle: lint-report needs --report <file> that exists and is not empty" >&2; return 2; }
  local tmp=""
  if [ -z "$diff" ]; then
    [ -n "$pr" ] || { echo "review-cycle: lint-report needs a pull request number or --diff <file>" >&2; return 2; }
    tmp="$(mktemp)"; diff="$tmp"
    gh pr diff "$pr" >"$diff" 2>/dev/null || { rm -f "$tmp"; echo "review-cycle: could not read the diff of #$pr" >&2; return 2; }
  fi
  [ -s "$diff" ] || { rm -f "$tmp"; echo "review-cycle: the diff is empty or unreadable, so no finding can be checked against it" >&2; return 2; }
  local leaked
  if ! leaked="$(report_secrets "$report")"; then
    rm -f "$tmp"
    echo "lint-report: FAIL. 1 problem(s):"
    echo "  - the report looks like it contains a secret ($leaked); replace the value with [REDACTED]"
    return 1
  fi
  X_REPORT="$report" X_DIFF="$diff" python3 -I - <<'PY'
import os, re, sys

report = open(os.environ["X_REPORT"], encoding="utf-8", errors="replace").read()
diff = open(os.environ["X_DIFF"], encoding="utf-8", errors="replace").read().splitlines()

# New-side line ranges per file, and the files the diff deletes (no new side to check).
ranges, deleted, cur, old = {}, set(), None, None
rem_old = rem_new = 0
for ln in diff:
    if rem_old > 0 or rem_new > 0:
        # Inside a hunk: a removed line that reads "-- x" shows as "--- x", so only count lines here.
        if ln.startswith("+"):
            rem_new -= 1
        elif ln.startswith("-"):
            rem_old -= 1
        elif not ln.startswith("\\"):
            rem_old -= 1
            rem_new -= 1
        continue
    if ln.startswith("--- "):
        old = ln[4:].strip()
        old = old[2:] if old.startswith("a/") else old
    elif ln.startswith("+++ "):
        new = ln[4:].strip()
        if new == "/dev/null":
            deleted.add(old)
            cur = None
        else:
            cur = new[2:] if new.startswith("b/") else new
            ranges.setdefault(cur, [])
    elif ln.startswith("@@") and cur is not None:
        m = re.match(r"@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@", ln)
        if m:
            start, n = int(m.group(1)), int(m.group(2) if m.group(2) is not None else 1)
            ranges[cur].append((start, start + max(n, 1) - 1))
    if ln.startswith("@@"):
        h = re.match(r"@@ -\d+(?:,(\d+))? \+\d+(?:,(\d+))? @@", ln)
        if h:
            rem_old = int(h.group(1)) if h.group(1) is not None else 1
            rem_new = int(h.group(2)) if h.group(2) is not None else 1

m = re.search(r"```findings\n(.*?)\n```", report, re.S)
if not m:
    print("lint-report: FAIL. The report has no fenced `findings` block.")
    sys.exit(1)
block = m.group(1)

entries, e = [], None
for ln in block.splitlines():
    s = re.match(r"^\s*-\s+id:\s*(\S+)", ln)
    if s:
        e = {"id": s.group(1).strip("\"'")}
        entries.append(e)
        continue
    kv = re.match(r"^\s{2,}(file|line|severity|status):\s*(.*?)\s*$", ln)
    if kv and e is not None:
        e[kv.group(1)] = kv.group(2).strip("\"'")

problems = []
for f in entries:
    fid = f["id"]
    path, line = f.get("file"), f.get("line")
    if (f.get("status") or "open") in ("not-applicable",):
        continue
    if not path:
        problems.append("%s: no file named, so it cannot be checked against the diff" % fid)
        continue
    if path in deleted:
        continue
    if path not in ranges:
        problems.append("%s: %s is not in the diff" % (fid, path))
        continue
    lm = re.fullmatch(r"(\d+)(?:-(\d+))?", line or "")
    if not lm:
        problems.append("%s: line '%s' is not a line number or a range, so it cannot be checked" % (fid, line or ""))
        continue
    lo, hi = int(lm.group(1)), int(lm.group(2) or lm.group(1))
    if not any(a <= lo and hi <= b for a, b in ranges[path]):
        problems.append("%s: %s:%s is not inside any hunk of the diff" % (fid, path, line))

if not re.search(r"Declined to judge:", report):
    problems.append("the coverage note has no `Declined to judge:` line (write `none` when nothing was skipped)")

# The counts line equals the entries that still count: open or refused-rejected.
cm = re.search(r"^counts:\s*\{\s*critical:\s*(\d+),\s*warning:\s*(\d+),\s*note:\s*(\d+)\s*\}", block, re.M)
if cm:
    want = {"CRITICAL": 0, "WARNING": 0, "NOTE": 0}
    for f in entries:
        if (f.get("status") or "open") in ("open", "refused-rejected") and f.get("severity", "").upper() in want:
            want[f["severity"].upper()] += 1
    got = {"CRITICAL": int(cm.group(1)), "WARNING": int(cm.group(2)), "NOTE": int(cm.group(3))}
    if got != want:
        problems.append("counts line says %s but the entries add up to %s" % (got, want))
else:
    problems.append("the findings block has no `counts:` line")

if problems:
    print("lint-report: FAIL. %d problem(s):" % len(problems))
    for p in problems:
        print("  - " + p)
    sys.exit(1)
print("lint-report: ok. %d finding(s) anchored in the diff." % len(entries))
PY
  local rc=$?
  rm -f "$tmp"
  return $rc
}

# Creates the six labels, or updates them in place: `--force` makes `gh label create` overwrite the
# colour and description of a label that already exists, so running this twice is the same as
# running it once. It needs no pull request, only a repository `gh` can resolve. Every
# `gh pr edit --add-label` above fails on a label the repository does not have, which is why their
# refusals point here.
#
# Exit 0 when all six were written, 2 when any one was not: `gh` offline, no token, or a token
# without permission to write labels. A partial run says which labels it could not write.
cmd_ensure_labels() {
  local failed="" spec name color desc
  for spec in \
    "review:pending|fbca04|Not reviewed at this head yet" \
    "review:running|1d76db|A review pass is in flight" \
    "review:fixing|d876e3|A correction is in flight; the head is about to move" \
    "review:blocked|b60205|The review found at least one CRITICAL" \
    "review:passed|0e8a16|Nothing blocks at this head; the marker comment is the evidence" \
    "review:needs-human|d93f0b|The loop paused or stopped and a person has to decide; only with review:blocked"; do
    name="${spec%%|*}"; desc="${spec##*|}"; color="${spec#*|}"; color="${color%%|*}"
    if gh label create "$name" --force --color "$color" --description "$desc" >/dev/null 2>&1; then
      echo "label $name ok"
    else
      failed="${failed:+$failed }$name"
    fi
  done
  if [ -n "$failed" ]; then
    echo "review-cycle: could not create or update: $failed (gh offline, not authenticated, or no permission to write labels); INCONCLUSIVE" >&2
    return 2
  fi
  return 0
}

case "${1:-status}" in
  status)  shift || true; cmd_status  "${1:-}" ;;
  debt)    shift || true; cmd_debt    "${1:-}" ;;
  start)   shift || true; cmd_start   "${1:-}" ;;
  fix)     shift || true; cmd_fix     "${1:-}" ;;
  halt)    shift || true; cmd_halt    "$@" ;;
  budget)  shift || true; cmd_budget  "${1:-}" ;;
  extend)  shift || true; cmd_extend  "$@" ;;
  export-audit) shift || true; cmd_export_audit "$@" ;;
  stale)   shift || true; cmd_stale   "${1:-}" ;;
  marker)  shift || true; cmd_marker  "$@" ;;
  publish) shift || true; cmd_publish "$@" ;;
  lint-report) shift || true; cmd_lint_report "$@" ;;
  ensure-labels) shift || true; cmd_ensure_labels ;;
  *) die "usage: review-cycle.sh {status|debt|start|fix|halt|budget|extend|export-audit|stale|marker|publish|lint-report|ensure-labels} [pr]" ;;
esac
