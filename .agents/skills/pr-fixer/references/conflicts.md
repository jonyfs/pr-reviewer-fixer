---
Summary: Playbook for the conflict lane of pr-fixer: classify each conflict, merge the base into the head, resolve per hunk with evidence, verify, and know when to escalate.
Tags: [#pr #fix #conflict #merge #reference]
---

# Conflict Playbook

Trigger: `mergeable` is `CONFLICTING` or `mergeStateStatus` is `DIRTY`, found by a person or by
`scripts/triage-pr.sh` when the review loop agent scans a PR. The conflict lane runs first and alone, because
it moves history and every other lane must build on its result.

## 1. Take the cycle and look before touching anything

1. Run `scripts/review-cycle.sh fix` right before the first edit.
2. Bring the base in: `git fetch origin <base>` then `git merge origin/<base>`. This is the default
   strategy, and the only one: it needs no force. A rebase of a pushed branch is never pushed (see
   [cycles-and-races.md](cycles-and-races.md)); where the project requires linear history, hand
   the rebase to a person. The review loop agent never rebases.
3. List the conflicted files: `git diff --name-only --diff-filter=U`. More than
   `max_conflict_files` (default 15): `git merge --abort` and escalate.
4. Read the intent of both sides before the first hunk: the PR description, the PR's own commit
   messages, and the base commits that touched each file (`git log origin/<base> -- <file>` since
   the merge base).

## 2. Classify every conflicted file

| Class | How to recognise it | Resolution |
|---|---|---|
| Generated file or lockfile | Matches `regen_paths`, or is a lockfile (`package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, `poetry.lock`, `Cargo.lock`, `go.sum`) | Never hand-merge. Take either side, run the configured regeneration command (for a lockfile, the project's lock command), stage the regenerated output |
| Pure rename or move | One side moved or renamed the file, the other edited it | Apply the edit at the new path; check that no reference to the old path is left |
| Textual overlap | Both sides changed nearby lines with compatible meaning (an import list, two added cases) | Keep both changes, hunk by hunk, in the order the file's own structure asks for |
| Semantic conflict | Both sides changed what the same code means (a signature, a default, a condition) | Resolve only when the code and both intents decide it; otherwise escalate |
| Vendored or binary | Under a vendor directory, or not text | Never merge by hand. Take the side the project's update process produced and say which, or escalate |

## 3. Resolve per hunk, with evidence

For each hunk, write down in one line which side wins or how both combine, and why, citing the
commit message or PR text that shows the intent. `git checkout --ours` or `--theirs` is allowed
for a whole file only when the class table says so (generated, vendored). Never resolve with
`-X ours` or `-X theirs` on the whole merge: that produces trees that compile in parts and fail in
CI.

## 4. Verify, push, hand back

1. Run the narrowest build and test that cover the touched files (the affected package or test
   files, then the build if the change crosses packages). Never push on failure.
2. Commit the merge with a message that lists each conflicted file, its class, and the resolution.
3. Re-check the remote head, push, run `scripts/review-cycle.sh stale`.
4. Post one closure comment for the cycle with the per-file table. The re-review is mandatory:
   a merge can change behaviour even when every hunk looked mechanical, and the head moved, so it
   counts as a cycle.

## Escalate instead of resolving

- Long divergence: the branch is far behind the base, the merge base is old, and a clean
  resolution is not achievable in one focused commit.
- A conflict inside a CRITICAL fix: the fixer's own correction and the base disagree about the
  same guarded code.
- A semantic conflict that the code alone does not decide.
- A conflict in security-sensitive files: authentication, authorisation, cryptography, secrets
  handling, CI workflows, permissions, or the skills themselves (`.agents/skills/**`).
  `push-guard.sh` refuses a merge whose own changes touch a sensitive path (workflows and
  `.github/scripts/**`, actions, CODEOWNERS, the skill folders `install.sh` writes and `.claude/**`
  at any depth, `.mcp.json`, agent instruction files such as `AGENTS.md`) unless a person opted that class in
  with `PUSH_GUARD_ALLOW_SENSITIVE`.
- More than `max_conflict_files` conflicted files.

Escalation means: `git merge --abort`, no push, and a stopped line naming the files, their class
and the one decision a person must make.
