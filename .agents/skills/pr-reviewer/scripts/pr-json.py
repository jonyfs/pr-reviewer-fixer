#!/usr/bin/env python3
"""pr-json.py: the pull request as `gh pr view` prints it, minus every comment that was edited.

WHY IT EXISTS. A verdict marker is an HTML comment, and its author can rewrite the comment after the
fact. `review-cycle.sh` and the gate decide from markers, so both read the pull request through this
one script, and a comment edited after it was created never reaches them. `gh pr view --json
comments` carries no edit time (only `includesCreatedEdit`); `lastEditedAt` exists on the GraphQL
`IssueComment` object, so this asks GraphQL, a page at a time.

IT FAILS CLOSED. When gh is missing or fails, when GraphQL answers something that is not the shape
expected, when a page is truncated, or when GraphQL lists fewer comments than `gh pr view` did, it
prints nothing and exits 1. Callers read that as "could not read the pull request", which is never
the same as approved.

Usage: pr-json.py [<pr-number>]
Output: one JSON object with number, headRefOid, labels, comments, state, isDraft, url,
`commentsDroppedEdited` (how many comments were removed for having been edited) and
`editedComments` (those comments, author, last editor and body only, never read as a verdict;
kept so an edit cannot erase a BLOCKED marker from the history or lower the highest `pass=` while it
keeps the number, and so an edit by someone other than the author is seen).
"""
import json
import re
import subprocess
import sys

FIELDS = "number,headRefOid,labels,comments,state,isDraft,url"
QUERY = (
    "query($owner:String!,$repo:String!,$number:Int!,$after:String){"
    "repository(owner:$owner,name:$repo){pullRequest(number:$number){"
    "comments(first:100,after:$after){pageInfo{hasNextPage endCursor} nodes{id lastEditedAt editor{login}}}}}}"
)
MAX_PAGES = 100


def gh(*args):
    try:
        r = subprocess.run(("gh",) + args, capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return r.stdout if r.returncode == 0 else None


def fail(msg):
    print("pr-json: " + msg, file=sys.stderr)
    return 1


def main():
    # One pull request number in ASCII digits, or none for the branch's own. Anything else is
    # refused: dropping it would read a different pull request than the caller named.
    explicit = sys.argv[1:]
    if len(explicit) > 1 or (explicit and not re.fullmatch(r"[0-9]+", explicit[0], re.ASCII)):
        return fail("%r is not one pull request number" % " ".join(explicit))
    out = gh("pr", "view", *explicit, "--json", FIELDS)
    if out is None:
        return 1
    try:
        pr = json.loads(out)
    except json.JSONDecodeError:
        return fail("gh pr view did not answer JSON")
    m = re.match(r"https?://[^/]+/([^/]+)/([^/]+)/pull/(\d+)", str(pr.get("url") or ""), re.ASCII)
    if not m:
        return fail("the pull request has no usable url, so its comment edits cannot be checked")
    owner, repo, number = m.groups()
    comments = pr.get("comments") or []

    seen, edited, editors, after = set(), set(), {}, None
    for _ in range(MAX_PAGES):
        args = ["api", "graphql", "-f", "query=" + QUERY, "-f", "owner=" + owner,
                "-f", "repo=" + repo, "-F", "number=" + number]
        if after:
            args += ["-f", "after=" + after]
        raw = gh(*args)
        if raw is None:
            return fail("gh api graphql failed, so comment edits cannot be checked")
        try:
            page = json.loads(raw)["data"]["repository"]["pullRequest"]["comments"]
            nodes, info = page["nodes"], page["pageInfo"]
            more, cursor = bool(info["hasNextPage"]), info.get("endCursor")
        except (ValueError, KeyError, TypeError):
            return fail("gh api graphql answered an unexpected shape")
        for n in nodes:
            if not isinstance(n, dict) or not n.get("id"):
                return fail("a GraphQL comment node had no id")
            seen.add(n["id"])
            if n.get("lastEditedAt"):
                edited.add(n["id"])
                # The login of the last edit. None when GitHub names no one (a deleted account),
                # which readers take as someone other than the author.
                editors[n["id"]] = ((n.get("editor") or {}).get("login") or None)
        if not more:
            break
        if not cursor:
            return fail("GraphQL said there is another page and gave no cursor")
        after = cursor
    else:
        return fail("more than %d pages of comments" % MAX_PAGES)

    ids = {c.get("id") for c in comments if isinstance(c, dict)}
    if not ids.issubset(seen):
        return fail("GraphQL listed fewer comments than gh pr view, so the list is truncated")

    kept = [c for c in comments if isinstance(c, dict) and c.get("id") not in edited]
    pr["comments"] = kept
    pr["commentsDroppedEdited"] = len(comments) - len(kept)
    # An edited comment is never read as a verdict. It is kept aside, author, editor and body only,
    # for two purposes: an edit may hide a BLOCKED marker, and BLOCKED history only ever tightens a
    # rule; and its `pass=` still counts toward the highest pass, so an edit that keeps the number
    # does not lower the cycle count. `editor` lets readers refuse an edit by someone other than the
    # author, which could rewrite the number.
    pr["editedComments"] = [{"author": c.get("author"), "editor": {"login": editors.get(c.get("id"))}, "body": c.get("body")}
                          for c in comments if isinstance(c, dict) and c.get("id") in edited]
    sys.stdout.write(json.dumps(pr))
    return 0


if __name__ == "__main__":
    sys.exit(main())
