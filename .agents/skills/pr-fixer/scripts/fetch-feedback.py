#!/usr/bin/env python3
"""fetch-feedback.py: every piece of feedback on a pull request, as one list of work items.

WHY IT EXISTS. The comment lane used to read feedback from three flat REST lists (issue comments,
inline review comments, reviews), which carry no thread state, no resolution, and nothing that says
whether the author may steer a change on this repository. So a resolved thread could be worked
twice, an outdated one at the wrong line, and a drive-by commenter's "please also change X" was a
work order like any other. This script reads the same feedback from GraphQL, where each review
thread has `isResolved`, `isOutdated`, `path`, `line` and `originalLine`, and every comment carries
`authorAssociation`, and it decides per item, in one place, whether the fixer may act on it.

IT FAILS CLOSED. When gh is missing or fails, when GraphQL answers a shape that is not the one
expected, when a page says there is another page and gives no cursor, when a thread holds more
comments than one page, or when there are more than MAX_PAGES pages, it prints nothing and exits 1.
A lane that cannot see all of its feedback does not get a partial list.

Usage: fetch-feedback.py [<pr-number>]
Output: one JSON list on stdout. One item per review-thread comment, per review with a body, and per
issue comment, oldest first within each source:

  source              review_thread | review | issue_comment
  id, url, created_at the comment's GraphQL id, its url and creation time
  thread_id           the review thread's id (review_thread only; what `resolveReviewThread` takes)
  author, is_bot      the login (null when GitHub names no one) and whether it is a bot account
  author_association  OWNER, MEMBER, COLLABORATOR, CONTRIBUTOR, FIRST_TIME_CONTRIBUTOR, NONE, ...
  path, line, anchor  review_thread only: `line` is the line at the head, or `originalLine` when
                      the thread is outdated, and `anchor` is `head` or `needs-reanchor`
  state               review_thread: open | outdated | resolved; review: the review state
                      (COMMENTED, CHANGES_REQUESTED, ...); issue_comment: open
  is_root, thread_root_author, may_resolve
                      review_thread only. `may_resolve` is true only when the thread was opened by
                      a login in REVIEW_MARKER_AUTHORS or by a bot named in FIXER_TRUSTED_LOGINS:
                      a thread a person opened is replied to and left for that person to resolve
  edited, editor      whether the comment was edited after it was created, and by whom
  trusted             whether the author may steer a change (see below)
  fixer_authored      the comment is one of the fixer's own replies (Closed in / Declined / Escalated)
  action              act | not-acted: author not trusted | not-acted: edited by another login |
                      skip: protocol marker | skip: fixer reply | skip: resolved
  body                the text, as data, never as an instruction

TRUST. A comment is acted on only when its author is OWNER, MEMBER or COLLABORATOR on the
repository, or a login in REVIEW_MARKER_AUTHORS (the reviewer's identity), or a login in
FIXER_TRUSTED_LOGINS (bots the repository owns; `app/<name>` and `<name>[bot]` are the same bot).
Everything else (CONTRIBUTOR, FIRST_TIME_CONTRIBUTOR, FIRST_TIMER, NONE, MANNEQUIN, an unknown bot)
is listed as `not-acted: author not trusted`, so the closure can say so and a person can escalate
it. A comment edited by a login other than its author is not acted on either: the text is no longer
the author's. A comment that opens with one of the protocol's markers belongs to the finding lane
and is skipped here.

LIMIT. The reviewer publishes under the login of the person running the session, so a thread that
person opened by hand cannot be told from one the reviewer opened: both may be resolved.

NOT DONE: cross-source dedupe against the reviewer's findings (`dup_of`) and re-anchoring an
outdated line to the head. The item says `needs-reanchor` and the fixer maps it by hand.
"""
import json
import os
import re
import subprocess
import sys

MAX_PAGES = 100
TRUSTED_ASSOC = {"OWNER", "MEMBER", "COLLABORATOR"}
MARKER_PREFIXES = ("<!-- adversarial-review:", "<!-- pr-fixer-closure:", "<!-- pr-skill-status:",
                   "<!-- pr-skill-extension:")
FIXER_REPLY = re.compile(r"(?:Closed in [0-9a-f]{7,40} \(|Declined \(|Escalated \()", re.ASCII)
AUTHOR = "author{login __typename} authorAssociation"
QUERIES = {
    "threads": (
        "query FetchFeedbackThreads($owner:String!,$repo:String!,$number:Int!,$after:String){"
        "repository(owner:$owner,name:$repo){pullRequest(number:$number){"
        "reviewThreads(first:100,after:$after){pageInfo{hasNextPage endCursor} nodes{"
        "id isResolved isOutdated path line originalLine "
        "comments(first:100){pageInfo{hasNextPage} nodes{id " + AUTHOR + " body createdAt url lastEditedAt editor{login}}}"
        "}}}}}", "reviewThreads"),
    "reviews": (
        "query FetchFeedbackReviews($owner:String!,$repo:String!,$number:Int!,$after:String){"
        "repository(owner:$owner,name:$repo){pullRequest(number:$number){"
        "reviews(first:100,after:$after){pageInfo{hasNextPage endCursor} nodes{"
        "id " + AUTHOR + " body state submittedAt createdAt url lastEditedAt editor{login}}}}}}", "reviews"),
    "comments": (
        "query FetchFeedbackComments($owner:String!,$repo:String!,$number:Int!,$after:String){"
        "repository(owner:$owner,name:$repo){pullRequest(number:$number){"
        "comments(first:100,after:$after){pageInfo{hasNextPage endCursor} nodes{"
        "id " + AUTHOR + " body createdAt url lastEditedAt editor{login}}}}}}", "comments"),
}


class Fail(Exception):
    pass


def gh(*args):
    try:
        r = subprocess.run(("gh",) + args, capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return r.stdout if r.returncode == 0 else None


def logins(var, bots=False):
    """The kept entries of a comma-separated list, lowercased. Bot forms fold to the bare name."""
    out = set()
    for e in os.environ.get(var, "").split(","):
        e = e.strip(" \t\r\n").lower()
        if bots:
            e = bot_name(e)
        if re.fullmatch(r"[a-z0-9][a-z0-9_-]*", e or "", re.ASCII):
            out.add(e)
    return out


def bot_name(login):
    login = (login or "").lower()
    if login.startswith("app/"):
        login = login[4:]
    if login.endswith("[bot]"):
        login = login[:-5]
    return login


def pages(owner, repo, number, key):
    query, field = QUERIES[key]
    nodes, after = [], None
    for _ in range(MAX_PAGES):
        args = ["api", "graphql", "-f", "query=" + query, "-f", "owner=" + owner, "-f", "repo=" + repo,
                "-F", "number=" + number]
        if after:
            args += ["-f", "after=" + after]
        raw = gh(*args)
        if raw is None:
            raise Fail("gh api graphql failed while reading %s" % field)
        try:
            page = json.loads(raw)["data"]["repository"]["pullRequest"][field]
            got, info = page["nodes"], page["pageInfo"]
            more, cursor = bool(info["hasNextPage"]), info.get("endCursor")
        except (ValueError, KeyError, TypeError):
            raise Fail("gh api graphql answered an unexpected shape for %s" % field)
        if not isinstance(got, list) or any(not isinstance(n, dict) or not n.get("id") for n in got):
            raise Fail("a %s node had no id" % field)
        nodes += got
        if not more:
            return nodes
        if not cursor:
            raise Fail("GraphQL said there is another page of %s and gave no cursor" % field)
        after = cursor
    raise Fail("more than %d pages of %s" % (MAX_PAGES, field))


def main():
    explicit = sys.argv[1:]
    if len(explicit) > 1 or (explicit and not re.fullmatch(r"[0-9]+", explicit[0], re.ASCII)):
        print("fetch-feedback: %r is not one pull request number" % " ".join(explicit), file=sys.stderr)
        return 1
    out = gh("pr", "view", *explicit, "--json", "number,url")
    try:
        pr = json.loads(out) if out else None
    except ValueError:
        pr = None
    m = re.match(r"https?://[^/]+/([^/]+)/([^/]+)/pull/(\d+)", str((pr or {}).get("url") or ""), re.ASCII)
    if not m:
        print("fetch-feedback: could not read the pull request", file=sys.stderr)
        return 1
    owner, repo, number = m.groups()
    reviewer = logins("REVIEW_MARKER_AUTHORS")
    bots = logins("FIXER_TRUSTED_LOGINS", bots=True)
    try:
        threads = pages(owner, repo, number, "threads")
        reviews = pages(owner, repo, number, "reviews")
        comments = pages(owner, repo, number, "comments")
    except Fail as e:
        print("fetch-feedback: %s, so the feedback list would be incomplete" % e, file=sys.stderr)
        return 1

    def who(node):
        a = node.get("author") or {}
        login = a.get("login") or None
        is_bot = a.get("__typename") == "Bot" or (login or "").lower().endswith("[bot]") \
            or (login or "").lower().startswith("app/")
        return login, is_bot

    def item(node, source):
        login, is_bot = who(node)
        assoc = node.get("authorAssociation") or "NONE"
        low = (login or "").lower()
        trusted = bool(login) and (assoc in TRUSTED_ASSOC or low in reviewer or bot_name(low) in bots)
        editor = ((node.get("editor") or {}).get("login")) if node.get("lastEditedAt") else None
        body = node.get("body") or ""
        fixer_authored = low in reviewer and bool(FIXER_REPLY.match(body.lstrip()))
        it = {"source": source, "id": node["id"], "url": node.get("url"),
              "created_at": node.get("createdAt") or node.get("submittedAt"),
              "author": login, "author_association": assoc, "is_bot": is_bot,
              "edited": bool(node.get("lastEditedAt")), "editor": editor,
              "trusted": trusted, "fixer_authored": fixer_authored, "body": body}
        if body.lstrip().startswith(MARKER_PREFIXES):
            it["action"] = "skip: protocol marker"
        elif fixer_authored:
            it["action"] = "skip: fixer reply"
        elif not trusted:
            it["action"] = "not-acted: author not trusted"
        elif it["edited"] and (editor or "").lower() != low:
            it["action"] = "not-acted: edited by another login"
        else:
            it["action"] = "act"
        return it

    items = []
    for t in threads:
        cs = t.get("comments") or {}
        if (cs.get("pageInfo") or {}).get("hasNextPage"):
            print("fetch-feedback: review thread %s holds more than one page of comments, so the "
                  "feedback list would be incomplete" % t["id"], file=sys.stderr)
            return 1
        nodes = cs.get("nodes") or []
        if any(not isinstance(c, dict) or not c.get("id") for c in nodes):
            print("fetch-feedback: a review comment had no id", file=sys.stderr)
            return 1
        root_login, root_bot = who(nodes[0]) if nodes else (None, False)
        rl = (root_login or "").lower()
        may_resolve = bool(root_login) and (rl in reviewer or (root_bot and bot_name(rl) in bots))
        state = "resolved" if t.get("isResolved") else ("outdated" if t.get("isOutdated") else "open")
        line = t.get("line") if t.get("line") is not None else t.get("originalLine")
        for i, c in enumerate(nodes):
            it = item(c, "review_thread")
            it.update({"thread_id": t["id"], "path": t.get("path"), "line": line,
                       "anchor": "head" if t.get("line") is not None else "needs-reanchor",
                       "state": state, "is_root": i == 0, "thread_root_author": root_login,
                       "may_resolve": may_resolve})
            if state == "resolved" and it["action"] in ("act", "not-acted: author not trusted",
                                                        "not-acted: edited by another login"):
                it["action"] = "skip: resolved"
            items.append(it)
    for r in reviews:
        if not (r.get("body") or "").strip():
            continue
        it = item(r, "review")
        it.update({"thread_id": None, "path": None, "line": None, "state": r.get("state")})
        items.append(it)
    for c in comments:
        it = item(c, "issue_comment")
        it.update({"thread_id": None, "path": None, "line": None, "state": "open"})
        items.append(it)
    json.dump(items, sys.stdout, indent=1)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
