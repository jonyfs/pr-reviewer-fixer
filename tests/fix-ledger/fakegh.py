# Fake gh for tests/fix-ledger/run.sh. Read-only: it answers the three reads fix-ledger.sh makes and
# exits 1 on anything else, so a write call fails the run as well as showing in calls.log.
#   pr view <n> --json ...    pr-<n>.json, the whole object (gh would trim it to the fields)
#   api graphql ...           the first page pr-json.py asks for: every comment of pr-<n>.json with
#                             `lastEditedAt` set when its id is a key of the PR's "edited" map (the
#                             value is the editor's login), and its "deleted" list as
#                             CommentDeletedEvent nodes ({"author": a, "actor": b})
#   pr list ...               list.json
# A missing pr-<n>.json makes the call exit 1, as gh does for a pull request it cannot read.
import json, os, sys
d, args = sys.argv[1], sys.argv[2:]


def load(n):
    p = os.path.join(d, "pr-%s.json" % n)
    if not os.path.exists(p):
        print("GraphQL: Could not resolve to a PullRequest with the number of %s." % n, file=sys.stderr)
        sys.exit(1)
    pr = json.load(open(p))
    pr.setdefault("url", "https://github.com/o/r/pull/%s" % n)
    for i, c in enumerate(pr.get("comments", [])):
        c.setdefault("id", "IC_%s_%d" % (n, i))
        c.setdefault("url", "%s#issuecomment-%d" % (pr["url"], 1000 + i))
    return pr


if args[:2] == ["pr", "view"] and len(args) > 2:
    print(json.dumps(load(args[2])))
    sys.exit(0)
if args[:2] == ["api", "graphql"]:
    n = next((a.split("=", 1)[1] for a in args if a.startswith("number=")), None)
    pr = load(n)
    edited = pr.get("edited", {})
    nodes = []
    for c in pr.get("comments", []):
        e = edited.get(c["id"])
        nodes.append({"id": c["id"], "lastEditedAt": "2026-11-02T00:00:00Z" if e else None,
                      "editor": {"login": e} if e else None,
                      "ue1": {"nodes": [{"editedAt": "2026-11-02T00:00:00Z", "editor": {"login": e}}] if e else []},
                      "ue2": {"nodes": [{"editedAt": "2026-11-02T00:00:00Z", "editor": {"login": e}}] if e else []}})
    deleted = [{"id": "CDE_%d" % i, "createdAt": "2026-11-02T00:00:00Z", "deletedCommentAuthor": {"login": x["author"]},
                "actor": {"login": x["actor"]}} for i, x in enumerate(pr.get("deleted", []))]
    page = {"pageInfo": {"hasNextPage": False, "endCursor": None}}
    print(json.dumps({"data": {"repository": {"pullRequest": {
        "comments": dict(page, nodes=nodes), "timelineItems": dict(page, nodes=deleted)}}}}))
    sys.exit(0)
if args[:2] == ["pr", "list"]:
    p = os.path.join(d, "list.json")
    if not os.path.exists(p):
        sys.exit(1)
    print(open(p).read())
    sys.exit(0)
print("fake gh: unhandled %s" % " ".join(args), file=sys.stderr)
sys.exit(1)
