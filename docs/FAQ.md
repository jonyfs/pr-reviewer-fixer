# FAQ

### Is this safe to run on a real repository?

Start with a repository you can afford to experiment in. The skills post comments, add labels and push
commits to the pull request branch. They never merge, approve, tag or release. Read the
[limits](REFERENCE.md#limits-and-honest-caveats) first.

### Do I need an API key?

No. The review and the fix run as agents in your own coding session, which already has its
authentication. No GitHub Actions workflow calls a model, and the project never asks for a provider key.

### Why does the reviewer never approve on GitHub?

Its verdict is a comment and a label, signed by your login. A GitHub "request changes" review from the
same account would keep blocking after the problem was fixed, so the automatic run does not post one.
You can still approve or request changes yourself.

### What is the difference between a warning and a critical?

A critical finding is data loss, a security breach, an outage, or a broken rule your project declares
non-negotiable. It always blocks. A warning is a likely bug or a missing test. It does not block unless
you set `REVIEW_BLOCK_AT=warning`. Notes never block.

### The reviewer says `BLOCKED`, but I think it is wrong. What now?

Reply on the pull request with the reason, or push a change. The reviewer checks the new head. If the
fixer refused a finding, it wrote the evidence in its closure comment, and the reviewer decides whether
the refusal holds. You can also grant more cycles or stop the loop.

### Why did the loop stop and ask me a question?

After five automatic fix cycles without a pass, the agent asks in the session, not on the pull request.
Only an answer you give in the session counts. A comment that says "continue" does nothing.

### The merge fixer escalated a conflict. Why not resolve it?

It resolves what the code and both sides' intent decide. It escalates what they do not decide, and any
file that touches authentication, secrets, CI, permissions or the skills themselves. Escalation means
it aborted the merge and pushed nothing. You make the one decision it names.

### Does a merge push cost a review cycle?

Yes. Every push creates a new head, and the gate needs a verdict at that head. So the reviewer runs
again. The merge fixer's report lists the hunks to read first, but the review still reads the whole diff.

### Can I use only one of the skills?

Yes. Install it alone with `--skill pr-reviewer`, for example. Each skill has its own copies of the
scripts it needs, so it works without the others. With only the reviewer installed, you get verdicts and
no automatic fixes.

### I upgraded from 0.19.0. Why is there no merge fixer?

`update.sh` updates the skills you already have. A skill a release adds is installed once, with
`install.sh --harness <name> --skill pr-merge-fixer --yes`. Until you do, the loop skips the conflict step
and says so.

### Does it work on GitLab or Bitbucket?

No. It uses the GitHub CLI (`gh`) and GitHub's pull request model. The harness can be any agent that
reads skill folders, but the pull request host must be GitHub.

### Where are the reports stored?

On the pull request, as comments. The fixer's and the merge fixer's comments are the record of what they
did. A person can export an audit file with `review-cycle.sh export-audit`, and commit it through a pull
request if they want it in the repository.

### Can a comment on the pull request tell the skills what to do?

A comment is text, not an instruction. The fixer acts only on the findings block of the reviewer's
verdict, and on review comments from people with write access, judged as claims about the code.
Instructions about the process (move a label, skip a test, push, merge) are ignored and reported.
