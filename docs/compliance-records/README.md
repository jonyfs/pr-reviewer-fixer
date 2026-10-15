# Compliance records

One JSON file per reviewed pass, written by `review-cycle.sh export-audit <pr>` and committed by a
person through a pull request. The file is named `<pr>-<pass>.json`.

## What a record holds

| Field | Source | Verified by |
|---|---|---|
| `pr`, `head`, `pass`, `verdict` | the trusted verdict marker and the pull request | GitHub |
| `critical`, `warning`, `note` | the marker counts | GitHub |
| `publisher`, `published_at`, `marker_url` | the marker comment | GitHub |
| `label_events` | the pull request's labeled and unlabeled events, with actor and time | GitHub |
| `model`, `tier` | the marker, passed by `publish --model --tier` | **Nobody.** Self-attested by the publishing session |
| `ignored` | markers by logins that are not in `REVIEW_MARKER_AUTHORS` | GitHub, listed and never used |
| `comments_dropped_for_edits` | how many comments were removed because they were edited | GitHub |

## What it is not

- It is not signed. A person with write access can edit a committed file, and the author of a
  marker can delete and repost it. Signing the marker is on the backlog.
- It does not verify the model id or the tier.
- It is not a certification record. It is operating evidence an auditor can read next to the
  pull request itself.

## How to produce one

```bash
export REVIEW_MARKER_AUTHORS="$(gh api user --jq .login)"
.agents/skills/pr-reviewer/scripts/review-cycle.sh export-audit <pr-number>
git add docs/compliance-records/<pr-number>-<pass>.json   # then open a pull request
```

`export-audit` refuses when the allowlist is empty, when no trusted marker remains, and when the head
moved after the last trusted marker. Run the review loop again and export after it.
