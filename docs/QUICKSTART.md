# Quick start

This takes about ten minutes. At the end, a pull request in your repository gets a review, fixes
when they are needed, and a merge when a conflict appears.

## 1. Check the basics

```bash
gh auth status        # signed in to GitHub
python3 --version     # 3.9 or newer
node --version
```

## 2. Install the skills

Clone a release tag from the [releases page](https://github.com/jonyfs/pr-reviewer-fixer/releases),
then, from that clone:

```bash
./install.sh --harness claude-code          # shows the plan, changes nothing
./install.sh --harness claude-code --yes    # installs all three skills
```

Use `--harness codex`, `copilot`, `gemini`, `cursor`, `opencode` and others the same way, or `--harness auto` to install wherever a harness is found.

Without a clone, one line downloads the latest release, checks its SHA-256, and runs its installer. It shows the plan first:

```bash
curl -fsSLO https://raw.githubusercontent.com/jonyfs/pr-reviewer-fixer/main/install-remote.sh
bash install-remote.sh --harness auto            # plan only
bash install-remote.sh --harness auto --yes      # install
``` Pick one
skill only with `--skill pr-reviewer`, or a list such as `--skill pr-reviewer,pr-fixer`.

## Review a branch from another repository

Without installing anything in that repository:

```bash
bash remote-review.sh owner/repo feature-branch --base main --test "npm test" --push --open-pr
```

It makes a worktree on `review/feature-branch`, runs the checks, and pushes that branch. A second run keeps fix commits already on the review branch; `--reset` discards them.

**`--test` runs the repository's own code on your machine**, with your permissions. Use it only for repositories you trust. The script prints a warning before it runs. The review and
the fixes then run from this copy of the skills against the worktree. The author's branch is not touched.

## 3. Prepare your repository (once)

```bash
export REVIEW_MARKER_AUTHORS="$(gh api user --jq .login)"
.claude/skills/pr-reviewer/scripts/review-cycle.sh ensure-labels
```

`REVIEW_MARKER_AUTHORS` is the login the reports are written as. Without it, the scripts refuse to
publish, on purpose: anyone could otherwise forge a verdict.

## 4. Open a pull request

Open it as a draft, the way the skills expect:

```bash
gh pr create --draft --title "Add retry to the payment client" --body "..."
```

The agent in your session then runs the loop on its own:

```mermaid
sequenceDiagram
    participant You
    participant Loop as Agent (your session)
    participant GH as GitHub
    You->>GH: Open draft PR
    Loop->>GH: Merge base if conflicts
    Loop->>GH: Review, publish verdict
    alt BLOCKED
        Loop->>GH: Fix, closure comment
        Loop->>GH: Review again
    end
    alt PASSED
        GH-->>You: Marked ready for review
    end
```

## 5. Read the result

Open the pull request. The newest comment from the reviewer starts with `🤖 Written by pr-reviewer`. It is GitHub Markdown, built to be scanned:

- The **alert** at the top says the verdict: a green box for `PASSED`, a red one for `BLOCKED`.
- The **summary table** (`Verdict`, `Counts`, `Head`, `Next`) says how many findings there are and who acts next.
- The **How to read this review** list names the one thing to look at first.
- Each **critical finding** (🔴) is a table row with its id, file and line. Those block the merge.
- **Warnings and notes** are debt, each with a proposed owner.

## 6. Merge, or let the loop continue

- `PASSED`: the pull request is ready for review. Merging is your decision.
- `BLOCKED`: the fixer answers with a closure comment that lists each finding it closed, with its
  test and its commit. The reviewer then checks again.
- After five automatic cycles without a pass, the agent asks you in the session. You answer
  `continue N` or `stop`.

## When something needs you

| You see | What to do |
|---|---|
| `review:needs-human` label | Read the last comment, then decide: push a correction, grant more cycles, or close the PR |
| A merge report that says "escalated" | Decide the one conflict it names, then push |
| A `⛔ BLOCKED` verdict you disagree with | Reply on the PR, or push a fix. The reviewer checks the new head |

Next: the [how it works guide](HOW-IT-WORKS.md) or the [skills reference](SKILLS-REFERENCE.md).
