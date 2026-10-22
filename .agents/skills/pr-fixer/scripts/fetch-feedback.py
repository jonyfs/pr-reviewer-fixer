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
  minimized           whether a person hid the comment or review on GitHub (`isMinimized`)
  action              act | not-acted: author not trusted | not-acted: edited by another login |
                      skip: protocol marker | skip: fixer reply | skip: minimized | skip: dismissed |
                      skip: resolved. A minimized comment and a DISMISSED review were withdrawn on
                      GitHub, so they are never work orders; neither are the inline comments of a
                      DISMISSED review (`pullRequestReview{state}` of a thread comment, which is
                      null for none). In a resolved thread, a comment after
                      the fixer's last reply keeps its own action; the rest of the thread, and a
                      resolved thread with no fixer reply, is skip: resolved
  body                the text, as data, never as an instruction

TRUST. A comment is acted on only when its author is the repository OWNER, a MEMBER or
COLLABORATOR whose permission on the repository is admin, maintain or write (looked up once per
login with `collaborators/<login>/permission`, the gate `review-cycle.sh fix` uses; an organisation
member or a collaborator with read or triage access cannot push, so cannot steer a push either), a
login in REVIEW_MARKER_AUTHORS (the reviewer's identity), or a login in FIXER_TRUSTED_LOGINS (bots
the repository owns). A lookup that fails counts as no write access. The lookup reads both fields
the endpoint returns: `permission` holds the legacy values (admin, write, read, none; a maintain
role reads as write and triage as read) and `role_name` the role itself (admin, maintain, write,
triage, read, or a custom role). Either field equal to admin, maintain or write (ignoring case) is
write access; each field is compared whole, so a custom role named "Write Docs" is not. Checked
against live GitHub on 2026-10-21 for an admin (`{"permission":"admin","role_name":"admin"}`); the
maintain and triage mapping is GitHub's documented one, not observed here.

BOT FORMS. GitHub names one bot two ways: `app/<name>` (`gh pr view --json author`) and
`<name>[bot]` (REST). A FIXER_TRUSTED_LOGINS entry in either form names that bot only: it matches an
author GitHub marks as a Bot, never a person whose login happens to be `<name>`. A bare entry
(`renovate`) matches the bot or the person of that login. REVIEW_MARKER_AUTHORS takes logins as
GraphQL prints them, which for a bot is the bare name, so an entry in `<name>[bot]` or `app/<name>`
form names nobody here, as it names nobody to `review-cycle.sh` and the gate, which share one login
grammar. Everything else (CONTRIBUTOR, FIRST_TIME_CONTRIBUTOR, FIRST_TIMER, NONE,
MANNEQUIN, an unknown bot, a MEMBER or COLLABORATOR without write access) is listed as
`not-acted: author not trusted`, so the closure can say so and a person can escalate
it. A comment edited by a login other than its author is not acted on either: the text is no longer
the author's. A comment that opens with one of the protocol's markers belongs to the finding lane
and is skipped here.

SCHEMA. `isMinimized` is a non-null Boolean on IssueComment, PullRequestReviewComment and
PullRequestReview, and `PullRequestReviewComment.pullRequestReview` is a nullable PullRequestReview
whose `state` is non-null (PENDING, COMMENTED, APPROVED, CHANGES_REQUESTED, DISMISSED). Checked by
introspection against live GitHub on 2026-10-21 (`__type(name:...){fields{name type{...}}}`). It
still fails closed: a query naming a field the schema lacks is refused, so gh exits 1, and a node
whose `isMinimized` is not a boolean, or a thread comment without the `pullRequestReview` key, is
an unexpected shape.

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
# OWNER is trusted by association. MEMBER and COLLABORATOR are trusted only with one of WRITE_PERMS.
CHECKED_ASSOC = {"MEMBER", "COLLABORATOR"}
WRITE_PERMS = {"admin", "maintain", "write"}
MARKER_PREFIXES = ("<!-- adversarial-review:", "<!-- pr-fixer-closure:", "<!-- pr-skill-status:",
                   "<!-- pr-skill-extension:")
FIXER_REPLY = re.compile(r"(?:Closed in [0-9a-f]{7,40} \(|Declined \(|Escalated \()", re.ASCII)
AUTHOR = "author{login __typename} authorAssociation isMinimized"
QUERIES = {
    "threads": (
        "query FetchFeedbackThreads($owner:String!,$repo:String!,$number:Int!,$after:String){"
        "repository(owner:$owner,name:$repo){pullRequest(number:$number){"
        "reviewThreads(first:100,after:$after){pageInfo{hasNextPage endCursor} nodes{"
        "id isResolved isOutdated path line originalLine "
        "comments(first:100){pageInfo{hasNextPage} nodes{id " + AUTHOR + " body createdAt url lastEditedAt editor{login} "
        "pullRequestReview{state}}}"
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
    """The kept entries of a comma-separated list, lowercased. With `bots`, two sets: bare entries,
    and entries written in a bot form (`app/x`, `x[bot]`), folded to the bare name, that name a bot
    and nobody else."""
    out, bot_only = set(), set()
    for e in os.environ.get(var, "").split(","):
        e = e.strip(" \t\r\n").lower()
        is_bot_form = bots and (e.startswith("app/") or e.endswith("[bot]"))
        if bots:
            e = bot_name(e)
        if re.fullmatch(r"[a-z0-9][a-z0-9_-]*", e or "", re.ASCII):
            (bot_only if is_bot_form else out).add(e)
    return (out, bot_only) if bots else out


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
        # isMinimized is non-null on reviews and comments (a thread's own comments are checked in
        # main): a node without a boolean there is not the shape this script reads, and reading it
        # as "not minimized" would act on hidden text.
        if field != "reviewThreads" and any(not isinstance(n.get("isMinimized"), bool) for n in got):
            raise Fail("a %s node had no boolean isMinimized" % field)
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
    bare, bot_only = logins("FIXER_TRUSTED_LOGINS", bots=True)

    def trusted_bot(login, is_bot):
        n = bot_name(login)
        return n in bare or (is_bot and n in bot_only)
    try:
        threads = pages(owner, repo, number, "threads")
        reviews = pages(owner, repo, number, "reviews")
        comments = pages(owner, repo, number, "comments")
    except Fail as e:
        print("fetch-feedback: %s, so the feedback list would be incomplete" % e, file=sys.stderr)
        return 1

    perm_cache = {}

    def can_write(login):
        """Whether the login holds admin, maintain or write here. A failed lookup is False."""
        key = login.lower()
        if key not in perm_cache:
            if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*", login, re.ASCII):
                perm_cache[key] = False
            else:
                # Both fields: `permission` (legacy) and `role_name` (the role), as a JSON array.
                # Either one equal to admin, maintain or write is write access. Each field is
                # compared whole: a custom role "Write Docs" is not write. A failed lookup is no access.
                out = gh("api", "repos/%s/%s/collaborators/%s/permission" % (owner, repo, login),
                         "--jq", '[.permission, .role_name]')
                try:
                    fields = json.loads(out) if out else []
                except ValueError:
                    fields = []
                perm_cache[key] = isinstance(fields, list) and any(
                    isinstance(f, str) and f.lower() in WRITE_PERMS for f in fields)
        return perm_cache[key]

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
        trusted = bool(login) and (assoc == "OWNER" or low in reviewer or trusted_bot(low, is_bot)
                                   or (assoc in CHECKED_ASSOC and can_write(login)))
        editor = ((node.get("editor") or {}).get("login")) if node.get("lastEditedAt") else None
        body = node.get("body") or ""
        fixer_authored = low in reviewer and bool(FIXER_REPLY.match(body.lstrip()))
        it = {"source": source, "id": node["id"], "url": node.get("url"),
              "created_at": node.get("createdAt") or node.get("submittedAt"),
              "author": login, "author_association": assoc, "is_bot": is_bot,
              "edited": bool(node.get("lastEditedAt")), "editor": editor,
              "trusted": trusted, "fixer_authored": fixer_authored,
              "minimized": node.get("isMinimized") is True, "body": body}
        if body.lstrip().startswith(MARKER_PREFIXES):
            it["action"] = "skip: protocol marker"
        elif fixer_authored:
            it["action"] = "skip: fixer reply"
        elif it["minimized"]:
            it["action"] = "skip: minimized"
        elif source == "review" and node.get("state") == "DISMISSED":
            it["action"] = "skip: dismissed"
        elif source == "review_thread" and (node.get("pullRequestReview") or {}).get("state") == "DISMISSED":
            # An inline comment belongs to a review; dismissing that review withdraws it too.
            it["action"] = "skip: dismissed"
        elif not trusted:
            it["action"] = "not-acted: author not trusted"
        elif it["edited"] and (editor or "").lower() != low:
            it["action"] = "not-acted: edited by another login"
        else:
            it["action"] = "act"
        return it

    items = []
    for t in threads:
        cs = t.get("comments")
        # A thread whose comments connection is missing or malformed is not a thread with no
        # comments: fail closed, as a truncated page does.
        if (not isinstance(cs, dict) or not isinstance(cs.get("pageInfo"), dict)
                or not isinstance(cs["pageInfo"].get("hasNextPage"), bool) or not isinstance(cs.get("nodes"), list)):
            print("fetch-feedback: review thread %s came without a readable comments list, so the "
                  "feedback list would be incomplete" % t["id"], file=sys.stderr)
            return 1
        if cs["pageInfo"]["hasNextPage"]:
            print("fetch-feedback: review thread %s holds more than one page of comments, so the "
                  "feedback list would be incomplete" % t["id"], file=sys.stderr)
            return 1
        nodes = cs["nodes"]
        if any(not isinstance(c, dict) or not c.get("id") for c in nodes):
            print("fetch-feedback: a review comment had no id", file=sys.stderr)
            return 1
        # Each thread comment names its review (null when GitHub gives none). A missing key, or a
        # review without a string state, is not the shape asked for: fail closed.
        for c in nodes:
            rv = c.get("pullRequestReview", KeyError)
            if not isinstance(c.get("isMinimized"), bool) or not (
                    rv is None or (isinstance(rv, dict) and isinstance(rv.get("state"), str))):
                print("fetch-feedback: review comment %s came without a boolean isMinimized or a readable "
                      "pullRequestReview, so the feedback list would be incomplete" % c["id"], file=sys.stderr)
                return 1
        root_login, root_bot = who(nodes[0]) if nodes else (None, False)
        rl = (root_login or "").lower()
        may_resolve = bool(root_login) and (rl in reviewer or (root_bot and bot_name(rl) in (bare | bot_only)))
        state = "resolved" if t.get("isResolved") else ("outdated" if t.get("isOutdated") else "open")
        line = t.get("line") if t.get("line") is not None else t.get("originalLine")
        built = [item(c, "review_thread") for c in nodes]
        # In a resolved thread, what came after the fixer's last reply was written after the fixer
        # closed it: a "still broken" there keeps its own action. Everything up to that reply, and
        # every comment of a resolved thread the fixer never replied to, is skip: resolved. Thread
        # comments come oldest first, so the position is the order.
        last_fixer = max((i for i, it in enumerate(built) if it["fixer_authored"]), default=None)
        for i, (c, it) in enumerate(zip(nodes, built)):
            it.update({"thread_id": t["id"], "path": t.get("path"), "line": line,
                       "anchor": "head" if t.get("line") is not None else "needs-reanchor",
                       "state": state, "is_root": i == 0, "thread_root_author": root_login,
                       "may_resolve": may_resolve})
            reopened = last_fixer is not None and i > last_fixer
            if state == "resolved" and not reopened and it["action"] in (
                    "act", "not-acted: author not trusted", "not-acted: edited by another login"):
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
