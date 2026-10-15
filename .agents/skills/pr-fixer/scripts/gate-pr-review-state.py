#!/usr/bin/env python3
"""Review-state gate: the pull request says, in a label, whether the adversarial review acted.

WHY IT EXISTS. The cycle already required the review and the closure report, and both landed as
prose inside the pull request body. Prose is where a reader stops looking: two pull requests once
carried a full closure report each, and nothing in the pull request *list* distinguished a
reviewed change from an unreviewed one. The state existed and was unreadable.

WHAT A LABEL IS, AND WHAT IT IS NOT. A label is a **claim**, and the whole discipline here
is that a claim is not evidence. So the label is the human-readable projection and never the
authority. The authority is a marker comment the reviewer posts, naming the head SHA it actually
reviewed:

    <!-- adversarial-review: sha=<40 hex> verdict=PASSED|BLOCKED pass=<n>
                             critical=<n> warning=<n> note=<n> -->

`review:passed` with no marker is a claim with no evidence. `review:passed` whose marker names a SHA
that is no longer the head is the oldest green-that-proves-nothing there is: review passes, the
author pushes three more commits, and the label still reads green. Both fail here.

TWO FORMS, ONE READER. The three counts arrived after the first marker format shipped, and every marker published
before them has only the first three fields. This gate reads both, because the alternative is worse than
untidy: a reader that does not understand the old form reports it ABSENT, and absence here means
**not reviewed**, so adopting the new format would have retroactively unreviewed every pull request
already reviewed. The counts are one optional group and all-or-nothing; `critical=` without its two
siblings is not a marker carrying partial information, it is not a marker.

WHAT THE COUNTS BUY, beyond being readable. `review:passed` means **nothing blocks**, not "nothing
was found": the warnings and notes beside it are declared debt. What this gate can therefore check,
and does, is the one contradiction the format makes visible: a marker saying `verdict=PASSED` while
counting a CRITICAL. Only a CRITICAL blocks, so a passing verdict cannot carry one; that is the
reviewer disagreeing with its own arithmetic, the same family as the label disagreeing with the
verdict, one level down. It still does not read the findings, and still cannot tell a truthful count
from an invented one.

ABSENCE IS PESSIMISTIC, ON PURPOSE. A pull request with no `review:*` label fails rather than passes.
Forgetting to label must read as "not reviewed", never as "fine"; the opposite default is how a
process gate quietly becomes decoration.

WHAT IT DOES NOT DO, said instead of implied:
- It does not read the findings. `review:blocked` and `review:passed` are equally well-formed here;
  what separates them is the reviewer's verdict, not this gate's opinion.
- It cannot tell a truthful marker from a fabricated one. Posting a marker for a review that never
  ran is a lie written into an artifact, which is a different failure from forgetting.
- It says nothing about merge permission, and NOTHING it returns blocks a merge. This is the
  one place in this file that states the enforcement facts, because they are the easiest thing
  here to be confidently wrong about. An earlier revision of this docstring claimed that the CI
  job "fails on any non-zero, so `4` blocks the merge there", and the same change was busy
  deleting that exact falsehood from another caller. Measured on a real repository:

      $ gh api repos/<owner>/<repo>/branches/<base>/protection \
          --jq .required_status_checks.contexts
      ["<name of one required check>"]

  One required context on the base branch, and it is the NON-strict caller of this gate. The job
  that runs this gate in strict mode is NOT in that list: it turns its own step red and stops
  no merge. So this gate DETECTS after the fact and prevents nothing unless the project marks
  the strict job as a required check, and a comment that invents a second net is worse than no
  comment, because it argues the reader out of looking for one.

EXIT, AND IT HAS FIVE CODES BECAUSE FOUR STILL FUSED TWO EVENTS. At first the same `2` meant
both "I could not read the pull request" and "I read it, I decided, and I am not blocking because
the fact is historical". Splitting `3` off fixed that half and left the other: **the same event
still came out as a different code depending on the MODE.** In `--require-passed`, `gh` failing on a
pull request that exists, undecipherable JSON and a payload with no head all returned `1`, which
this contract defines as "read it and REFUSED, a decision against", while outside it they returned
`2`. Neither was true: no label was opened on any of those paths. The fifth code says the true
thing, and says it identically in both modes.

    0  read it; the claim holds
    1  read it and REFUSED: a decision against
    2  NOTHING to read: there is no pull request for this branch, or `gh` is offline, or the
       pull request was CLOSED without merging so there is no claim to hold
    3  read it and DECIDED: MERGED without a valid `review:passed`. Recorded, not blocked.
    4  could NOT read what EXISTS: `gh` failed on a pull request that is really there, the JSON
       is undecipherable, the head is missing, the Python version bail, an unhandled exception.
       Never a decision, and never a different number in a different mode.

WHAT DEPENDS ON THE MODE, AND WHAT DOES NOT.

    `4` never does. That is the whole point of it: "I could not read" cannot become "I refused"
        because somebody passed a flag. Severity is the CALLER's to choose, and the CI check chooses
        it by counting `4` as a failure. What no caller does is stop a merge: see "WHAT IT DOES NOT
        DO" above, which is the only place here that states that, and states it measured.
    `2` never does either: nothing to read is nothing to read, and that includes a pull request
        CLOSED without merging. At first it DID: `--require-passed` answered `1` on a
        CLOSED pull request, and `1` is the one code this contract defines as a decision against a
        label. Nothing had opened a label there. Same event, same code, both modes.
    `1` and `3` DO. `--require-passed` is the stricter mode on purpose: in the pre-commit,
        `review:blocked` is a legitimate state and a merge that already happened is a historical
        fact (`3`, recorded). In the strict mode the same facts are a refusal (`1`), because there
        the question is asked about a merge that has not happened yet, and refusing is what asking
        it is for.
"""

import json
import os
import re
import subprocess
import sys
import traceback

NOTHING_TO_READ = 2
# **RECORDED is not NOTHING_TO_READ, and the day they were the same number it cost a lying sentence.**
# NOTHING_TO_READ is the absence of the object: there is no pull request. RECORDED is the opposite: it read, decided, and
# the decision is about a merge that already happened, which no new commit undoes and which therefore INFORMS
# instead of blocking. A caller that needs to know whether a reading took place can only tell if the
# two are different integers.
RECORDED = 3
# **UNREADABLE is not NOTHING_TO_READ, and the difference is between there being nothing to read and not being able to read
# what exists.** The first is the normal state of someone who has not opened the pull request yet; the second is
# a failure of the environment, the payload or the gate itself, and in it any answer about the review
# would be invented. Before the split the two were 2 outside strict mode and 1 inside it: the
# SAME event with two codes, and one of them meaning "I refused" about a label nobody
# opened. UNREADABLE holds the same in both modes, on purpose.
UNREADABLE = 4
# Alias kept because the prose of this file and its test suites have talked about "INCONCLUSIVE" since before
# the second meaning existed. It is 2, and only 2.
INCONCLUSIVE = NOTHING_TO_READ

# The machine line that `--emit-token` prints. It is a fixed PREFIX followed by the exit code,
# and not a JSON or a sentence: whoever reads it compares string to string, and the day the format changes
# the comparison fails instead of accepting what it did not understand.
TOKEN_PREFIX = "gate-pr-review-state: rc="

MINIMUM = (3, 9)
if sys.version_info < MINIMUM:
    print(f"  ⛔ this gate needs Python {MINIMUM[0]}.{MINIMUM[1]}+ and found "
          f"{sys.version_info.major}.{sys.version_info.minor}. The gate is not what is broken.")
    # 4 and not 1, and not 2: the message above itself says the defect is not in the pull request. This
    # branch read no label at all (returning 1 made the caller announce a refusal that never
    # happened), and the pull request may well exist, so it is not "nothing to read" either. It is the gate
    # failing to run on what exists.
    sys.exit(UNREADABLE)
# **The five states, and `review:fixing` is the one added last.** The reviewer had a
# state of its own from the start and the corrector had none, so while a `/pr-fixer`
# worked the pull request still read `review:passed`: true about the commit, false about the work.
# Pull requests merged inside exactly that window and their corrections never reached the base
# branch.
# For THIS gate the fifth state is vocabulary, and vocabulary that is missing does not read as
# unknown: a label outside this tuple leaves `present` empty, and empty is the sentence for *nobody
# reviewed this*. Adding it here is what lets the gate say `review:fixing` by name in every message
# below that would otherwise report an absent label over a pull request somebody did label.
STATES = ("review:pending", "review:running", "review:fixing", "review:blocked", "review:passed")
# A sixth label, and deliberately NOT a sixth state. The five above are a position in the cycle and
# exactly one may hold at a time; this one is a modifier of `review:blocked` that says the loop
# paused or stopped and a person has to decide. It is only ever valid beside `review:blocked`.
NEEDS_HUMAN = "review:needs-human"
# Anchored at the START of a comment, never a search anywhere inside its body, and this is the
# SAME rule `review-cycle.sh`'s `parse()` applies, on purpose. `publish` always writes
# `<!-- marker -->\n\n<report>`, so a genuine marker sits at position 0. A report body routinely
# QUOTES the marker format, showing what a passing one will look like once findings close, and a
# body-wide search used to let that quotation outrank the real marker whenever it came later in the
# text, which review reports, discussing their own verdict, do constantly. If the two readers of
# this format ever draw the anchor differently, the defect just moves from one to the other.
#
# The three counts are ONE optional group: `(?:...)?` around all of them together, never three
# independent `?`, so a half-written marker falls out as no marker instead of being read as an old
# one whose leftover field is silently ignored.
MARKER = re.compile(
    r"^\s*<!--\s*adversarial-review:\s*sha=([0-9a-f]{7,40})\s+verdict=(PASSED|BLOCKED)\s+pass=(\d+)"
    r"(?:\s+critical=(\d+)\s+warning=(\d+)\s+note=(\d+))?\s*-->",
    re.I,
)

# The marker author allowlist, read from `REVIEW_MARKER_AUTHORS`: a comma-separated list of GitHub
# logins as `gh pr view --json comments` prints them in `author.login` (`github-actions` for the
# default Actions token). The marker is an HTML comment, so without a list anyone who can comment
# can post an invisible PASSED one. The rules are the same three `review-cycle.sh` applies: the
# list is active when the variable holds anything other than whitespace, each entry has all
# whitespace removed, and the compare ignores case. Active with no login left after that (a lone
# comma) accepts no marker, which reads as not reviewed. Unset or empty: every comment counts, as
# before the variable existed.
def marker_author_allowed(comment: dict) -> bool:
    raw = os.environ.get("REVIEW_MARKER_AUTHORS", "")
    if not raw.strip():
        return True
    allow = {re.sub(r"\s+", "", x).lower() for x in raw.split(",")}
    allow.discard("")
    author = comment.get("author") or {}
    login = (author.get("login") or "").lower() if isinstance(author, dict) else ""
    return bool(login) and login in allow


def gh(*args: str) -> "str | None":
    """Runs gh, or reports that it could not. Offline is not a defect of the pull request."""
    try:
        r = subprocess.run(("gh",) + args, capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return r.stdout if r.returncode == 0 else None


def main() -> int:
    # `--require-passed` is the strict mode, and it is stricter
    # than the pre-commit one on purpose. In the pre-commit, `review:blocked` is a legitimate state: the
    # review ran, found things, and whoever is fixing needs to be able to commit. In strict mode,
    # `review:blocked` is precisely what must not pass. Same reading, two different
    # questions, and what each caller DOES with the answer is stated, measured, in the docstring.
    #
    # And here INCONCLUSIVE becomes FAILURE. In the pre-commit, not being able to look is honest: green over
    # the unknown would be worse. In strict mode, an "I could not look" that returns success is the
    # cheapest way to switch the protection off: it is enough for `gh` to fail.
    strict = "--require-passed" in sys.argv
    # An explicit number is how this gate gets proved against a real pull request from a branch
    # that is not the one carrying it. Without it, the only way to see red would be to open a
    # deliberately broken pull request, and what matters is seeing the red, not staging theatre.
    explicit = [a for a in sys.argv[1:] if a.isdigit()]
    out = gh("pr", "view", *explicit, "--json", "number,headRefOid,labels,comments,state")
    if out is None:
        # The two causes are DIFFERENT and the first version said the same sentence for both. With an
        # explicit number, "not found" means `gh` could not read ONE pull request that
        # exists (token, permission or network), and telling someone to "open the pull request" there is
        # pointing at the wrong place. Without a number, it is the honest case of running outside a branch with a
        # pull request.
        if explicit:
            # `⛔` and not `⚠️`: in this tool the second glyph is inconclusive, and this path returns 4,
            # which callers count as a failure. The glyph is the PROJECTION of the code, and a projection that
            # disagrees hides the gate that blew up behind a warning.
            print(f"  ⛔ could not read pull request #{explicit[0]} — `gh` failed, and this is "
                  "not the same as approved")
            # **Do not claim it exists.** `gh pr view 99999` answers "Could
            # not resolve to a PullRequest with the number of 99999": the number simply does not
            # exist, and this message announced that it did, with v2 having encoded the
            # claim in an integer called "could NOT read what EXISTS". Both causes stay
            # named and neither is chosen. Telling one from the other would require matching the text of
            # `gh`'s prose on stderr, and a wording change there would silently reclassify a
            # blind path as decided, which this whole gate exists not to do.
            print("     Either that number does not exist in this repository, or reading it "
                  "failed — token, `pull-requests: read` permission, network. The gate cannot "
                  "tell those apart, so it claims neither.")
        else:
            print("  ⚠️  no pull request for this branch, or `gh` is offline — "
                  "gate INCONCLUSIVE, which is not the same as approved")
            print("     There is nothing to read a label from. Opening the pull request is what "
                  "makes this gate meaningful.")
        # **The distinction already existed in the MESSAGE and did not exist in the exit code.** With an explicit
        # number the pull request exists and what failed was reading it: UNREADABLE. Without a number, there may
        # simply be no pull request for this branch, which is the normal state of almost every local
        # commit: NOTHING_TO_READ. Neither depends on the mode: before, both became 1
        # in strict, and 1 is "I read it and refused".
        return UNREADABLE if explicit else NOTHING_TO_READ

    try:
        pr = json.loads(out)
    except json.JSONDecodeError:
        # `⛔`, and the sentence stops saying INCONCLUSIVE alongside it: this path is 4, not 2.
        print("  ⛔ `gh pr view` did not answer JSON — the gate could not read what is there, "
              "and that is not the same as approved")
        # `gh` answered; what it answered is not JSON. The pull request is there and the gate could not
        # read it.
        return UNREADABLE

    # CLOSED without merging shipped nothing, so the review state is moot. MERGED is the opposite:
    # it is the only state where the change reached the base branch, and it is exactly where the
    # first version of this gate went silent: `!= OPEN` returned 0, so **merging was how you
    # switched the gate off**. Measured on a real repository: a dozen pull requests merged in two
    # days, several of them before or during their own verdict, and this gate reported ✅ on every
    # one of them afterwards. A gate that the act it governs can turn off is not a gate.
    state_now = pr.get("state")
    if state_now == "CLOSED":
        # **2 and not 0, and the difference is what 0 means.** 0 is "I read it; the claim holds": there is a
        # label and it stands up. On a pull request closed without merging there is no claim at all to
        # hold: nothing shipped, and the label is not asserting anything about the base. Returning
        # 0 there was the gate saying it checked what does not exist.
        #
        # **And 2 IN BOTH MODES.** Strict mode returned 1 here, which is the only code the
        # contract defines as "read and REFUSED, a decision against", about a pull request in which
        # no label was ever examined; the message that accompanied that 1 said
        # "something is out of place", which is the opposite of a refusal. It was the SAME event coming out with
        # two codes depending on the flag, exactly the defect the fifth code exists to
        # close, surviving in the branch nobody reread. 2 is non-zero and no caller reads it as
        # approval; what changes is that it stops announcing a decision that did not happen.
        print(f"  ⚠️  pull request #{pr.get('number')} was closed without merging — "
              "nothing shipped, so there is no claim to hold")
        return NOTHING_TO_READ

    number = pr.get("number")
    head = (pr.get("headRefOid") or "").lower()
    # Without a head there is nothing to compare the marker against, and the comparison below FAILS OPEN when it
    # is missing: `sha.startswith(head[:len(sha)])` becomes `sha.startswith("")`, which is True for any
    # SHA. A forged marker would pass. Refusing by name is the only honest way out.
    if not head:
        print(f"  ⛔ pull request #{number} came back without a head SHA — there is nothing to "
              "compare a marker against, and comparing against nothing accepts everything")
        # What happened was not being able to read: the payload arrived unusable. Calling that a
        # refusal is announcing a decision about a label nobody got to examine, and it was
        # exactly what strict mode did. UNREADABLE in both modes, and strict does not become
        # more permissive because of it: 4 is non-zero just as 1 was.
        return UNREADABLE
    present = [l["name"] for l in pr.get("labels", []) if l.get("name") in STATES]
    errors = []

    if not present:
        errors.append(
            f"pull request #{number} carries no `review:*` label. Absence reads as **not "
            "reviewed** here, never as fine — say which of "
            f"{', '.join('`' + s + '`' for s in STATES)} it is"
        )
    elif len(present) > 1:
        errors.append(
            f"pull request #{number} carries {len(present)} review states at once "
            f"({', '.join(present)}) — the projection has to project one thing"
        )

    # Open, `review:blocked` is a legitimate state: the review ran and found things. MERGED, the same
    # label says the thing found shipped. `review:pending` and `review:running` on a merged PR
    # say something even worse: it merged before the verdict arrived, which has happened more than
    # once. Only `review:passed` justifies a merge, and this is where that becomes a rule instead of
    # habit.
    #
    # **A merged `review:fixing` has a name**: it is the shape of a pull request that
    # merged with a fixer in the field, and the corrections stayed on disk: the head had not
    # moved, so no label was technically lying about the commit, and it was
    # lying about the work. The sentence below names that case separately because its way out is
    # different from the others: it is not "review before merging", it is "the correction exists somewhere and
    # is not here".
    if state_now == "MERGED" and present and present != ["review:passed"]:
        errors.append(
            f"pull request #{number} MERGED carrying `{present[0]}`. A change that reached the base "
            "with anything other than `review:passed` closed the review loop after the fact, or not "
            "at all. `review:blocked` says the findings shipped; `review:running` and "
            "`review:pending` say the merge outran the verdict; `review:fixing` says a correction "
            "was in flight when the merge happened, so look for corrections that never landed"
        )

    if strict and present and present != ["review:passed"]:
        errors.append(
            f"pull request #{number} carries `{present[0]}` and this check requires "
            "`review:passed`. The review loop closes before the merge, not after it"
        )

    if present == ["review:passed"]:
        markers = []
        for c in pr.get("comments", []):
            # Skipped before matching, so a comment off the allowlist supplies neither the current
            # verdict nor the BLOCKED history read from `markers` below.
            if not marker_author_allowed(c):
                continue
            m = MARKER.match(c.get("body", "") or "")
            if m:
                markers.append(m.groups())
        if not markers:
            errors.append(
                f"pull request #{number} is labelled `review:passed` and carries no reviewer "
                "marker comment. A label is a claim; the marker is the evidence, and this is the "
                "claim standing alone"
            )
        else:
            sha, verdict, passes, criticals, _warnings, _notes = markers[-1]
            sha = sha.lower()
            if verdict.upper() != "PASSED":
                errors.append(
                    f"pull request #{number} is labelled `review:passed` and its latest marker "
                    f"says `verdict={verdict.upper()}` — the label disagrees with the reviewer"
                )
            elif not head.startswith(sha) and not sha.startswith(head[:len(sha)]):
                errors.append(
                    f"pull request #{number} is labelled `review:passed` for `{sha[:12]}`, and the "
                    f"head is `{head[:12]}` — a push after the review invalidates the pass. "
                    "The reviewer runs again over the corrected diff"
                )
            # `pass >= 2` is not a count of passes, it is "the reviewer read the CORRECTION", and
            # that sentence is only true where a correction was demanded. Once BLOCKED requires a
            # CRITICAL, a pass 1 counting none is the ordinary outcome, and reading the bar as a
            # number left it with no publishable verdict at all. So the bar applies where a BLOCKED
            # marker stands on this pull request and nowhere else. This is the third reader of the
            # format; all three answer the question the same way, or the marker means two things.
            elif int(passes) < 2 and any(m[1].upper() == "BLOCKED" for m in markers):
                errors.append(
                    f"pull request #{number} is labelled `review:passed` after pass {passes}, and "
                    f"pull request #{number} carries an earlier `verdict=BLOCKED` marker. A "
                    "correction was demanded, so the cycle requires the reviewer to run again "
                    "over the corrected diff — a pass counts from 2 once something blocked"
                )
            # `criticals` is None on a marker published before the counts existed, and None is not
            # zero: it says nobody counted, not that somebody counted nothing. Only a marker that
            # actually carries the number is checked against it.
            elif criticals is not None and int(criticals) > 0:
                errors.append(
                    f"pull request #{number} is labelled `review:passed` and its marker says "
                    f"`verdict=PASSED` while counting `critical={criticals}`. Only a CRITICAL "
                    "blocks, so a passing verdict cannot carry one — the reviewer is disagreeing "
                    "with the arithmetic that produced its own verdict"
                )

    # The halt label standing beside a state it does not belong to. `halt` only writes it over
    # `review:blocked`, and `start`, `fix` and `publish` all withdraw it, so any other combination
    # was labelled by hand and is a claim the cycle does not back.
    if any(l["name"] == NEEDS_HUMAN for l in pr.get("labels", [])) and present != ["review:blocked"]:
        errors.append(
            f"pull request #{number} carries `{NEEDS_HUMAN}` while its review state is "
            f"{', '.join('`' + p + '`' for p in present) if present else '**absent**'}. That label "
            "only means something beside `review:blocked`; a new pass, a fix or a push all retire it"
        )

    # **Merged without `review:passed` INFORMS, and in the pre-commit it does not BLOCK.** The
    # distinction is what separates this gate from one that teaches `--no-verify`. Measured on a
    # real repository, and the count was wrong TWICE before it closed: most local branches had a
    # merged pull request and nearly all of them lacked `review:passed`. The two wrong attempts
    # stay because each is wrong in a different direction and for a different cause. One came from
    # `-q '[.[0].labels[]?.name]'` returning an empty string both for "there is no pull request"
    # and for "there is one and it has no label": reading absence of a label as absence of a pull
    # request is the confusion that THIS gate refuses by design. The other came from counting
    # EVERY local branch, without filtering out the ones that have no merged pull request at all
    # (the base branches, the in-progress feature ones). The second was written calling itself
    # reconciled, which is worse than the first: undercounting is an error, declaring yourself
    # resolved is an error with a seal. The first version of this rule left the merged ones with
    # the pre-commit permanently red, over a HISTORICAL fact that no new commit can fix. A gate
    # that punishes the past and has no way out is a gate that the person works around, and then
    # it stops holding for the present too. A check that only knows how to go red trains the
    # person to ignore red.
    #
    # The report counts this outcome separately from approved: the finding shows up and the person
    # commits. What does NOT happen is the merge being blocked somewhere else: nothing blocks it,
    # and the docstring says so with the measurement attached. This branch informs; that is all it
    # does.
    if errors and not strict and state_now == "MERGED":
        print(f"  ⚠️  pull request #{number} MERGED without a valid `review:passed` — this is "
              "recorded, not blocked:")
        for e in errors:
            print(f"     {e}")
        print("     The merge already happened; no new commit on this branch can undo it, and "
              "nothing here would have stopped it — see this gate's own docstring, which measures "
              "that. What is left is the record.")
        # RECORDED (3), not INCONCLUSIVE (2). This HERE is the gate having read the label, compared
        # the marker and concluded. Returning the same number as blindness erased exactly the part that
        # matters, and `review-cycle.sh` answered "nobody looked" about a pull request that was read.
        return RECORDED

    if errors:
        if state_now == "MERGED":
            print(f"  ⛔ pull request #{number} MERGED without a valid `review:passed` — "
                  "the review loop did not close on a change that is already in the base:")
        else:
            print(f"  ⛔ {len(errors)} problem(s) in the pull request's review state:")
        for e in errors:
            print(f"     {e}")
        print("     The label is what a reader of the pull request list sees. It has to be true.")
        return 1

    state = present[0] if present else "?"
    where = " (MERGED)" if state_now == "MERGED" else ""
    print(f"  ✅ pull request #{number}{where} declares `{state}`"
          + (f", marker matches head `{head[:12]}`" if state == "review:passed" else ""))
    return 0


if __name__ == "__main__":
    # **`--emit-token` exists because an exit code does not prove that this program ran.** The
    # exit code of a Python process comes from the interpreter as much as from the program: an
    # EMPTY file exits 0, an `import` that does not resolve exits 1, a `SyntaxError` exits 1, and the caller
    # that infers "the gate decided" from the number alone reads 0 as "I read it; the claim holds". Measured
    # with this file replaced by zero bytes: `review-cycle.sh status <pr>` answered
    # `#<pr> merged with a valid review:passed`, rc=0. The mechanism of the review cycle declaring
    # a change reviewed that nobody read.
    #
    # With the flag, and ONLY with it, the last line of stdout is `gate-pr-review-state: rc=<n>`. Without it
    # the output is identical to what it always was, because a CI check prints this report for a person and
    # a machine line in the middle of it is pollution.
    #
    # **A single print point, and the number comes from the same `_rc` that goes to `sys.exit`.** The
    # normal path and the exception handler's one converge here instead of each printing its own:
    # two writes of the same number are two chances to disagree, which is the disease this token
    # exists to catch one level up.
    _emit = "--emit-token" in sys.argv
    # **An unhandled exception is the gate NOT HAVING READ, and it used to exit 1**, indistinguishable from "I read it and
    # refused", which is the only thing 1 can mean. Measured with `gh` returning a
    # list where the gate expects an object: `AttributeError` in `pr.get`, exit 1, and the caller
    # announcing that the pull request merged without `review:passed` when no label had been
    # read. The traceback is STILL printed: swapping an error that lies for an invisible error is not
    # a fix. `SystemExit` and `KeyboardInterrupt` pass through intact: the first carries the code
    # that `main` decided, and swallowing it would turn every exit of this gate into 2.
    try:
        _rc = main()
    except (SystemExit, KeyboardInterrupt):
        raise
    except BaseException:
        traceback.print_exc()
        print("  ⛔ the gate raised before deciding anything — it could not read what is there, "
              "never approved. What broke is above, and it is not the pull request's review state.")
        # **UNREADABLE, and this was a finding that a review cycle closed in red.** While this exited
        # 2, a caller counted the gate's blow-up under INCONCLUSIVE and exited **0**. Measured: with `gh` returning
        # a list where the gate expects an object, the traceback was printed and the pass ended
        # green. A gate that could not run must not be indistinguishable from a gate that approved.
        _rc = UNREADABLE
    # The machine line, and it is the LAST thing printed on stdout, immediately before
    # `sys.exit`, from the SAME value. The version bail up top exits with no token on purpose:
    # it happens at module import, before this block exists, and a gate that never got
    # to run is exactly what the caller has to read as "nobody looked".
    if _emit:
        print(f"{TOKEN_PREFIX}{_rc}")
    sys.exit(_rc)
