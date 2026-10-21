import json, os, sys
d, args = sys.argv[1], sys.argv[2:]
p = os.path.join(d, "pr.json")
def load(): return json.load(open(p))
def save(x): json.dump(x, open(p, "w"))
def known(name):
    k = os.path.join(d, "known-labels")
    return (not os.path.exists(k)) or name in open(k).read().split()
def with_ids(pr):
    # Real `gh pr view` gives every comment an id and the pull request a url. Fixtures carry neither.
    pr.setdefault("url", "https://github.com/o/r/pull/%s" % pr.get("number", 0))
    for i, c in enumerate(pr.get("comments", [])):
        c.setdefault("id", "IC_%d" % i)
        c.setdefault("url", "%s#issuecomment-%d" % (pr["url"], 1000 + i))
    return pr
if args[:2] == ["pr", "view"]:
    if not os.path.exists(p): sys.exit(1)
    sys.stdout.write(json.dumps(with_ids(load()))); sys.exit(0)
if args[:2] == ["api", "user"]:
    if os.path.exists(os.path.join(d, "user-fail")): sys.exit(1)  # a token with no user behind it
    print(os.environ.get("FAKE_LOGIN", "github-actions")); sys.exit(0)
if args[:1] == ["api"] and len(args) > 1 and args[1].split("?")[0].endswith("/events"):
    if not os.path.exists(p) or os.path.exists(os.path.join(d, "events-fail")): sys.exit(1)
    ev = load().get("apiEvents", [])
    if os.path.exists(os.path.join(d, "events-split")) and len(ev) > 1:
        print(json.dumps(ev[:1]) + json.dumps(ev[1:])); sys.exit(0)  # --paginate: one array per page
    print(json.dumps(ev)); sys.exit(0)
if args[:1] == ["api"] and len(args) > 1 and args[1].endswith("/commits"):
    if not os.path.exists(p): sys.exit(1)
    print(json.dumps(load().get("apiCommits", []))); sys.exit(0)
if args[:1] == ["api"] and len(args) > 1 and "/collaborators/" in args[1] and args[1].endswith("/permission"):
    login = args[1].split("/collaborators/")[1].split("/")[0]
    perms = load().get("permissions", {})
    if login not in perms: sys.exit(1)
    print(perms[login]); sys.exit(0)
if args[:2] == ["api", "graphql"]:
    # Serves the comment pages pr-json.py asks for. Files in the state dir steer it:
    #   graphql-fail       the call exits 1
    #   edited-ids         one comment id per line whose lastEditedAt is set
    #   page-size          comments per page (default 100); `after` is the index of the next one
    #   graphql-truncate   the last page is cut off and says there is no next page
    #   edited-by          "<id> <login>" per line: who edited that comment (default: its author)
    if not os.path.exists(p) or os.path.exists(os.path.join(d, "graphql-fail")): sys.exit(1)
    q = next((a[6:] for a in args if a.startswith("query=")), "")
    ff = next((k for k in ("Threads", "Reviews", "Comments") if "query FetchFeedback" + k + "(" in q), None)
    if ff:
        # fetch-feedback.py. pr.json "reviewThreads" and "reviews" hold the nodes as GraphQL gives
        # them; issue comments come from "comments" (authorAssociation defaults to NONE). Files:
        #   ff-fail-<threads|reviews|comments>   that query exits 1
        #   ff-nocursor-<...>                    the first page says there is more and gives no cursor
        #   ff-badshape-<...>                    the answer lacks the connection
        #   ff-page-size                         nodes per page (default 100)
        key = ff.lower(); field = {"threads": "reviewThreads", "reviews": "reviews", "comments": "comments"}[key]
        if os.path.exists(os.path.join(d, "ff-fail-" + key)): sys.exit(1)
        if os.path.exists(os.path.join(d, "ff-badshape-" + key)):
            print(json.dumps({"data": {"repository": {"pullRequest": {}}}})); sys.exit(0)
        if key == "comments":
            nodes = [dict({"authorAssociation": "NONE", "lastEditedAt": None, "editor": None}, **c)
                     for c in with_ids(load())["comments"]]
        else:
            nodes = load().get(field, [])
        size = int(open(os.path.join(d, "ff-page-size")).read()) if os.path.exists(os.path.join(d, "ff-page-size")) else 100
        after = next((a.split("=", 1)[1] for a in args if a.startswith("after=")), None)
        start = int(after) if after else 0
        chunk, more = nodes[start:start + size], start + size < len(nodes)
        cursor = str(start + size) if more else None
        if os.path.exists(os.path.join(d, "ff-nocursor-" + key)): more, cursor = True, None
        print(json.dumps({"data": {"repository": {"pullRequest": {field: {
            "pageInfo": {"hasNextPage": more, "endCursor": cursor}, "nodes": chunk}}}}}))
        sys.exit(0)
    if any(a.startswith("query=") and "timelineItems" in a for a in args):
        # The CommentDeletedEvent query. `deleted-events` holds "<author> <deleter>" lines ("-" is a
        # login GitHub does not name); `graphql-deleted-fail` makes this call alone exit 1, and
        # `graphql-deleted-badshape` answers without the timelineItems field.
        if os.path.exists(os.path.join(d, "graphql-deleted-fail")): sys.exit(1)
        if os.path.exists(os.path.join(d, "graphql-deleted-badshape")):
            print(json.dumps({"data": {"repository": {"pullRequest": {}}}})); sys.exit(0)
        f = os.path.join(d, "deleted-events")
        lines = [l.split() for l in open(f).read().splitlines() if l.strip()] if os.path.exists(f) else []
        nul = lambda l: None if l == "-" else l
        nodes = [{"id": "CDE_%d" % i, "createdAt": "2026-10-16T00:%02d:00Z" % i,
                  "deletedCommentAuthor": ({"login": nul(a)} if nul(a) else None), "actor": ({"login": nul(b)} if nul(b) else None)}
                 for i, (a, b) in enumerate(lines)]
        print(json.dumps({"data": {"repository": {"pullRequest": {"timelineItems": {
            "pageInfo": {"hasNextPage": False, "endCursor": None}, "nodes": nodes}}}}}))
        sys.exit(0)
    after = next((a.split("=", 1)[1] for a in args if a.startswith("after=")), None)
    comments = with_ids(load())["comments"]
    size = int(open(os.path.join(d, "page-size")).read()) if os.path.exists(os.path.join(d, "page-size")) else 100
    edited = set(open(os.path.join(d, "edited-ids")).read().split()) if os.path.exists(os.path.join(d, "edited-ids")) else set()
    start = int(after) if after else 0
    chunk = comments[start:start + size]
    more = start + size < len(comments)
    if os.path.exists(os.path.join(d, "graphql-truncate")):
        chunk, more = chunk[:-1], False
    # edited-by: "<id> <login>" lines naming who edited a comment; by default its author did.
    by = dict(l.split(None, 1) for l in open(os.path.join(d, "edited-by")).read().splitlines() if l.strip()) if os.path.exists(os.path.join(d, "edited-by")) else {}
    # A login of "-" stands for GitHub naming no editor (a deleted account): the login is null.
    nodes = [{"id": c["id"], "lastEditedAt": ("2026-10-15T00:00:00Z" if c["id"] in edited else None),
              "editor": ({"login": (lambda l: None if l == "-" else l)(by.get(c["id"], ((c.get("author") or {}).get("login"))))} if c["id"] in edited else None)} for c in chunk]
    print(json.dumps({"data": {"repository": {"pullRequest": {"comments": {
        "pageInfo": {"hasNextPage": more, "endCursor": str(start + size) if more else None}, "nodes": nodes}}}}}))
    sys.exit(0)
if args[:2] == ["pr", "edit"]:
    # Real gh takes one positional (the pull request) and rejects a second before any API call:
    # "accepts at most 1 arg(s), received 2". A label list split on a space produces exactly that.
    valued = {"--add-label", "--remove-label", "--body", "-b", "--body-file", "-F", "--title", "-t",
              "--base", "-B", "--milestone", "--add-assignee", "--remove-assignee",
              "--add-reviewer", "--remove-reviewer", "--add-project", "--remove-project", "--repo", "-R"}
    positional, j = [], 2
    while j < len(args):
        if args[j] in valued: j += 2
        elif args[j].startswith("-"): j += 1
        else: positional.append(args[j]); j += 1
    if len(positional) > 1:
        print(f"accepts at most 1 arg(s), received {len(positional)}", file=sys.stderr); sys.exit(1)
    pr = load(); names = [l["name"] for l in pr["labels"]]
    i = 3
    while i < len(args):
        if args[i] == "--add-label":
            if not known(args[i+1]):
                print(f"could not add label: '{args[i+1]}' not found", file=sys.stderr); sys.exit(1)
            if args[i+1] not in names: names.append(args[i+1])
        elif args[i] == "--remove-label":
            names = [n for n in names if n != args[i+1]]
        i += 2
    pr["labels"] = [{"name": n} for n in names]; save(pr); sys.exit(0)
if args[:2] == ["pr", "diff"]:
    dp = os.path.join(d, "diff.patch")
    if not os.path.exists(dp): sys.exit(1)
    sys.stdout.write(open(dp).read()); sys.exit(0)
if args[:2] == ["pr", "comment"]:
    body = sys.stdin.read()
    if len(body) > 65536:
        print("body is too long (maximum is 65536 characters)", file=sys.stderr); sys.exit(1)
    pr = load()
    pr["comments"].append({"body": body, "author": {"login": os.environ.get("FAKE_LOGIN", "github-actions")}})
    save(pr); sys.exit(0)
if args[:2] == ["pr", "ready"]:
    if os.path.exists(os.path.join(d, "no-ready")):
        print("could not mark ready: not permitted", file=sys.stderr); sys.exit(1)
    pr = load(); pr["isDraft"] = False; save(pr); sys.exit(0)
if args[:2] == ["label", "create"]:
    sys.exit(0)
print("fake gh: unhandled " + " ".join(args), file=sys.stderr); sys.exit(1)
