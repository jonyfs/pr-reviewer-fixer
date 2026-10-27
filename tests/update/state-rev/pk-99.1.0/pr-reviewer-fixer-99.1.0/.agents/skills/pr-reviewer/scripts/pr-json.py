#!/usr/bin/env python3
"""pr-json.py: the pull request as `gh pr view` prints it, minus every comment that was edited.

WHY IT EXISTS. A verdict marker is an HTML comment, and its author can rewrite the comment after the
fact. `review-cycle.sh` and the gate decide from markers, so both read the pull request through this
one script, and a comment edited after it was created never reaches them. `gh pr view --json
comments` carries no edit time (only `includesCreatedEdit`); `lastEditedAt` exists on the GraphQL
`IssueComment` object, so this asks GraphQL, a page at a time.

THE LAST EDITOR. GitHub's schema calls `IssueComment.editor` only "the actor who edited the
comment", without saying which edit. So the last editor is read from the edit history instead: the
first and the last entry of `userContentEdits` are both fetched, and the one with the later
`editedAt` names the editor, whichever order GitHub lists them in. `editor` is used only when the
history is empty. When the newest entry is older than `lastEditedAt` (the last revision was deleted
from the history), the editor is unknown and read as someone other than the author. A live check on 2026-10-26 (three comments, each edited twice by one login) found
`lastEditedAt` equal to the newest history entry and `editor` equal to its editor; a comment edited
by two logins in turn was not available to check `editor` alone, which is why it is not relied on.

IT FAILS CLOSED. When gh is missing or fails, when GraphQL answers something that is not the shape
expected, when a page is truncated, or when GraphQL lists fewer comments than `gh pr view` did, it
prints nothing and exits 1. Callers read that as "could not read the pull request", which is never
the same as approved.

Usage: pr-json.py [<pr-number>]
Output: one JSON object with number, headRefOid, labels, comments, state, isDraft, url, title,
body (read by scan-hidden.py, never by a marker reader), author and isCrossRepository (read by the
fix guard in review-cycle.sh),
`commentsDroppedEdited` (how many comments were removed for having been edited) and
`editedComments` (those comments, author, last editor, body, id and url only, never read as a verdict;
kept so an edit cannot erase a BLOCKED marker from the history or lower the highest `pass=` while it
keeps the number, and so an edit by someone other than the author is seen), and `deletedComments`
(every CommentDeletedEvent on the timeline: the deleted comment's author, the login that deleted it,
the time and the event id; the body is gone, so a deletion by someone other than the author is
treated as a possible deleted marker).
"""
import json
import re
import subprocess
import sys

FIELDS = "number,headRefOid,labels,comments,state,isDraft,url,title,body,author,isCrossRepository"
QUERY = (
    "query($owner:String!,$repo:String!,$number:Int!,$after:String){"
    "repository(owner:$owner,name:$repo){pullRequest(number:$number){"
    "comments(first:100,after:$after){pageInfo{hasNextPage endCursor} nodes{id lastEditedAt editor{login} ue1:userContentEdits(first:1){nodes{editedAt editor{login}}} ue2:userContentEdits(last:1){nodes{editedAt editor{login}}}}}}}}"
)
# A trusted comment can also be deleted, by its author or by anyone with write access, and a deleted
# BLOCKED marker would drop out of the history and the pass count. The timeline keeps a
# CommentDeletedEvent for each deletion, naming who deleted it and who wrote it.
DELETED_QUERY = (
    "query($owner:String!,$repo:String!,$number:Int!,$after:String){"
    "repository(owner:$owner,name:$repo){pullRequest(number:$number){"
    "timelineItems(first:100,after:$after,itemTypes:[COMMENT_DELETED_EVENT]){pageInfo{hasNextPage endCursor} "
    "nodes{... on CommentDeletedEvent{id createdAt actor{login} deletedCommentAuthor{login}}}}}}}"
)
# The first page of both connections in one call: most pull requests fit in it, so most reads cost
# one GraphQL round trip instead of two. A connection with more pages goes on with its own query.
FIRST_QUERY = (
    "query PrJsonFirst($owner:String!,$repo:String!,$number:Int!){"
    "repository(owner:$owner,name:$repo){pullRequest(number:$number){"
    "comments(first:100){pageInfo{hasNextPage endCursor} nodes{id lastEditedAt editor{login} ue1:userContentEdits(first:1){nodes{editedAt editor{login}}} ue2:userContentEdits(last:1){nodes{editedAt editor{login}}}}} "
    "timelineItems(first:100,itemTypes:[COMMENT_DELETED_EVENT]){pageInfo{hasNextPage endCursor} "
    "nodes{... on CommentDeletedEvent{id createdAt actor{login} deletedCommentAuthor{login}}}}}}}"
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

    raw = gh("api", "graphql", "-f", "query=" + FIRST_QUERY, "-f", "owner=" + owner,
             "-f", "repo=" + repo, "-F", "number=" + number)
    if raw is None:
        return fail("gh api graphql failed, so comment edits and deletions cannot be checked")
    try:
        first = json.loads(raw)["data"]["repository"]["pullRequest"]
        if not isinstance(first, dict):
            raise TypeError("no pullRequest object")
    except (ValueError, KeyError, TypeError):
        return fail("gh api graphql answered an unexpected shape")

    seen, edited, editors, after = set(), set(), {}, None
    for i in range(MAX_PAGES):
        if i:
            raw = gh("api", "graphql", "-f", "query=" + QUERY, "-f", "owner=" + owner,
                     "-f", "repo=" + repo, "-F", "number=" + number, "-f", "after=" + after)
            if raw is None:
                return fail("gh api graphql failed, so comment edits cannot be checked")
        try:
            page = (json.loads(raw)["data"]["repository"]["pullRequest"] if i else first)["comments"]
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
                # The login of the last edit: the later of the first and last history entries, or
                # `editor` when the history is empty. None when GitHub names no one (a deleted
                # account), which readers take as someone other than the author.
                hist = [e for k in ("ue1", "ue2") for e in (((n.get(k) or {}).get("nodes")) or [])
                        if isinstance(e, dict) and isinstance(e.get("editedAt"), str)]
                last = max(hist, key=lambda e: e["editedAt"]) if hist else n
                login = ((last.get("editor") or {}).get("login") or None)
                # A history whose newest entry is older than lastEditedAt lost the last edit (a
                # revision can be deleted from it): that editor is unknown, read as foreign.
                if hist and isinstance(n.get("lastEditedAt"), str) and n["lastEditedAt"] > last["editedAt"]:
                    login = None
                editors[n["id"]] = login
        if not more:
            break
        if not cursor:
            return fail("GraphQL said there is another page and gave no cursor")
        after = cursor
    else:
        return fail("more than %d pages of comments" % MAX_PAGES)

    # The deletions, paged and checked the same way. Any failure here is a failure of the whole read.
    deleted, after = [], None
    for i in range(MAX_PAGES):
        if i:
            raw = gh("api", "graphql", "-f", "query=" + DELETED_QUERY, "-f", "owner=" + owner,
                     "-f", "repo=" + repo, "-F", "number=" + number, "-f", "after=" + after)
            if raw is None:
                return fail("gh api graphql failed, so comment deletions cannot be checked")
        try:
            page = (json.loads(raw)["data"]["repository"]["pullRequest"] if i else first)["timelineItems"]
            nodes, info = page["nodes"], page["pageInfo"]
            more, cursor = bool(info["hasNextPage"]), info.get("endCursor")
        except (ValueError, KeyError, TypeError):
            return fail("gh api graphql answered an unexpected shape for comment deletions")
        for n in nodes:
            if not isinstance(n, dict) or not n.get("id"):
                return fail("a GraphQL comment deletion node had no id")
            # A login of None means GitHub names no one (a deleted account): readers take a None
            # deleter as someone other than the author, and a None author as nobody trusted.
            deleted.append({"author": {"login": (n.get("deletedCommentAuthor") or {}).get("login") or None},
                            "actor": {"login": (n.get("actor") or {}).get("login") or None},
                            "createdAt": n.get("createdAt"), "id": n["id"]})
        if not more:
            break
        if not cursor:
            return fail("GraphQL said there is another page of deletions and gave no cursor")
        after = cursor
    else:
        return fail("more than %d pages of comment deletions" % MAX_PAGES)

    ids = {c.get("id") for c in comments if isinstance(c, dict)}
    if not ids.issubset(seen):
        return fail("GraphQL listed fewer comments than gh pr view, so the list is truncated")

    kept = [c for c in comments if isinstance(c, dict) and c.get("id") not in edited]
    pr["comments"] = kept
    pr["commentsDroppedEdited"] = len(comments) - len(kept)
    # An edited comment is never read as a verdict. It is kept aside (author, editor, body, and the id
    # and url that let a refusal name it),
    # for two purposes: an edit may hide a BLOCKED marker, and BLOCKED history only ever tightens a
    # rule; and its `pass=` still counts toward the highest pass, so an edit that keeps the number
    # does not lower the cycle count. `editor` lets readers refuse an edit by someone other than the
    # author, which could rewrite the number.
    pr["editedComments"] = [{"author": c.get("author"), "editor": {"login": editors.get(c.get("id"))}, "body": c.get("body"),
                             "id": c.get("id"), "url": c.get("url")}
                          for c in comments if isinstance(c, dict) and c.get("id") in edited]
    # Every deletion of a comment on the pull request, author, deleter, time and event id only.
    pr["deletedComments"] = deleted
    sys.stdout.write(json.dumps(pr))
    return 0


if __name__ == "__main__":
    sys.exit(main())
