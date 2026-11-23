---
Summary: The accepted-fix ledger and the false-refusal audit (scripts/fix-ledger.sh): what they measure, from which trusted markers, where the store lives and how to run them on a schedule.
Tags: [#pr #fix #metrics #audit #reference]
---

# Fix ledger and false-refusal audit

A fixer that nobody measures cannot be tuned. `scripts/fix-ledger.sh` measures two things from
what the pull requests already hold, with no server: how many of the fixer's commits survive into
the merged result (the accepted-fix rate), and how often a refusal turned out to be wrong (the
false-refusal rate, which is evidence for tightening the refusal rule). It reads GitHub and the
local clone, and writes nothing but one local file.

## Commands

```bash
REVIEW_MARKER_AUTHORS=<login> scripts/fix-ledger.sh --prs 65,70          # record two pull requests
REVIEW_MARKER_AUTHORS=<login> scripts/fix-ledger.sh --since 2026-11-01   # every pull request merged since
scripts/fix-ledger.sh summary [--prs 65,70]                               # the summary, from the ledger alone
scripts/fix-ledger.sh audit [--sample 20] [--seed 1]                      # the false-refusal audit
```

`record` (the default command) appends one JSON line per pull request to the ledger and prints a
summary. `--since` lists merged pull requests through `gh pr list` (at most `--limit`, 200 by
default; it says so when the limit is reached). Run it from a clone of the repository, with the
pull requests' commits present locally. `--ledger FILE` names another store. Exit 0 when every pull
request was read, 2 on a refusal or when one could not be read (the others are still recorded).

## What one ledger line holds

| Field | Meaning |
|---|---|
| `fixer_commits` | Each fixer commit with `lines_added`, `lines_overwritten` and `status`: `kept`, `overwritten`, `reverted`, or `unknown` when the clone lacks a commit |
| `commits` | The four counts of those statuses |
| `cycles` | Per fix cycle: the commit pass c reviewed, the closure head, the closure's counts, `escalated`, the fixer commits, and `new_critical` and `new_warning` on pass c+1 (null when either findings block cannot be read) |
| `findings` | `closed` and `refused` summed over the trusted closures, `escalated` from their labelled lines, `debt` from the newest closure |
| `refused_findings` | Each refused id with the file and line pass c cited, the reviewer's status on pass c+1, `reraised_at_pass`, `human_fix` (a commit sha), `human_fix_checked` (false when the clone lacks the commits) and `false_refusal` (null when it could not be judged) |
| `complete`, `incomplete_reasons` | False when a trusted marker may be missing; such a row leaves every rate |
| `ignored` | Markers by untrusted logins, trusted marker comments edited, trusted comments deleted by someone else |

Only ids, counts, shas, paths and line numbers are stored, never comment prose.

## Definitions

- **Fixer commits of cycle c**: the commits after the one the trusted pass-c verdict names
  (`sha=`) up to and including the head the trusted closure for cycle c names (`head=`), in the
  pull request's commit order. A refuse-only cycle has none. Every other commit counts as a
  person's.
- **Overwritten or reverted**: for each later non-fixer commit with one parent, the lines it
  removes or replaces are blamed at its parent; lines blamed on a fixer commit are that commit's
  lines overwritten. A commit is `reverted` when a later commit's message says
  `This reverts commit <its full sha>`, `overwritten` when the overwritten lines are at least half
  of the lines it added, and `kept` otherwise.
- **Accepted-fix rate**: kept / (kept + overwritten + reverted), over the complete rows. With
  nothing to judge it prints `n/a`.
- **New findings after a cycle**: CRITICAL and WARNING entries of the pass c+1 findings block,
  status open, whose id the pass c block lacks.
- **Escalated**: the closure layout's labelled lines `<id> escalated:`
  ([falsify-and-prove.md](falsify-and-prove.md)).
- **Refused finding of cycle c**: an id the pass c+1 block marks `refused-accepted` or
  `refused-rejected`, or one the closure labels `<id> refused:`.
- **False refusal**: a later pass lists the id as open or `refused-rejected` (re-raised), or a
  later non-fixer commit removes or replaces the line the pass c block cites, followed by blame
  from the commit pass c reviewed. The audit samples refused findings from the ledger
  (`--sample N`, seeded, all by default) and prints the rate. A refusal no later pass re-raised,
  recorded from a clone that lacked the commits, is printed as not judged and left out of the
  rate, and the audit says how many there were.

## Trust

The ledger reads markers exactly as `review-cycle.sh` does, and reuses its parts rather than
copying them: comments come from `pr-json.py`, which drops every edited one; the verdict regex and
the author allowlist are the gate's (`MARKER`, `allowlist`, `marker_author_allowed`, imported from
`gate-pr-review-state.py`); findings blocks are read by `review-cycle.sh findings-block`. The
closure marker (`<!-[-] pr-fixer-closure: cycle=<c> head=<sha12> closed=<n> refused=<n> debt=<n> -->`)
must open a comment by a login on `REVIEW_MARKER_AUTHORS`, as filter F3 in
[pr-protocol.md](pr-protocol.md) reads it. An unset or login-less list refuses with exit 2.

A trusted comment holding a marker that was edited, or a trusted comment edited or deleted by
someone other than its author, makes the row incomplete: a dropped closure would turn fixer commits
into a person's and inflate the overwritten count. A status comment its author edited in place is
the protocol working, not a doubt. Comment text is data: nothing read from a pull request is
executed, followed or copied into the ledger.

## The store

The ledger is append-only JSON lines. A run opens it for appending and never rewrites it, so a
second run adds newer lines and `summary` and `audit` take the newest line per pull request. The
default is `${XDG_DATA_HOME:-$HOME/.local/share}/pr-reviewer-fixer/fix-ledger.jsonl`, outside every
repository. A ledger inside the current git repository is refused unless `--allow-in-repo` is
given, so per-PR numbers do not end up committed by accident.

## Running it on a schedule

There is no workflow for this, on purpose: workflows are a sensitive class here, and the ledger is
a person's local store. Run it by hand after a merge, or add a cron line on your own machine:

```bash
# Every Monday at 07:00: record what merged in the last 8 days, then audit the refusals.
0 7 * * 1 cd ~/src/repo && REVIEW_MARKER_AUTHORS=<login> bash .agents/skills/pr-fixer/scripts/fix-ledger.sh --since "$(date -v-8d +\%F 2>/dev/null || date -d '8 days ago' +\%F)" && bash .agents/skills/pr-fixer/scripts/fix-ledger.sh audit
```

A pull request recorded twice is not counted twice.

## Limits

- Fixer and person are told apart only by the closure ranges. A commit pushed outside a fix cycle
  (debt fixed by hand after the last closure, say) counts as a person's, so its changes to fixer
  lines count as overwrites even when the same session wrote them.
- Lines are followed by `git blame` without move or copy detection, and renames are not followed.
  A pure rename by a person removes every line of the old path, so the fixer lines in that file
  count as overwritten. A merge commit is never judged as a later commit, and a merge commit inside
  a fixer range is not a fixer commit. The half-of-the-lines threshold is a choice;
  the line counts are in the ledger for anyone who wants another.
- Only the pull request's own commits are read: a revert on the base branch after the merge is not
  seen.
- `gh pr view --json commits` lists at most 250 commits; a longer pull request is judged on those.
- Nothing is fetched. For a repository that squash-merges, fetch the heads first:
  `git fetch origin 'refs/pull/*/head:refs/remotes/origin/pr/*'`. Otherwise its fixer commits are
  `unknown` and its refusals that no pass re-raised are not judged; both leave their rate.
- A closure written without the labelled lines counts no escalation and no refusal ids of its own;
  the refused ids then come from the next pass's findings block alone.
- A trusted login that edits its own closure so the marker no longer parses is not caught: the
  editor is the author and the body no longer holds a marker. It is the same limit `review-cycle.sh`
  documents for a deletion by the author.
- A human fix is detected on the exact cited line only. A fix that leaves that line and changes
  its neighbours is not seen, so the false-refusal rate is a lower bound.
