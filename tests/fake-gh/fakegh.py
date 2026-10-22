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
# ---- releases, for tests/release/run.sh (.github/scripts/release.sh) ---------------------------------
# State files: releases.json (a list of {tag_name, draft, target_commitish, assets: [{name, b64}],
# title, notes, latest}), refs.json (a list of git refs as matching-refs gives them) and tags.json
# (annotated tag sha -> its object). Files that steer it:
#   rel-page-size          releases and refs per page (default 100); without --paginate gh reads one
#   rel-fail-<what>        that call exits 1 with an HTTP error: list, refs, tag, download, upload,
#                          edit, create
def _jq(flt, obj):
    import subprocess
    r = subprocess.run(["jq", "-r", flt], input=json.dumps(obj), capture_output=True, text=True)
    sys.stdout.write(r.stdout); sys.stderr.write(r.stderr)
    if r.returncode: sys.exit(r.returncode)
def _opt(name):
    return next((args[i + 1] for i, a in enumerate(args[:-1]) if a == name), None)
def _rel_fail(what):
    if os.path.exists(os.path.join(d, "rel-fail-" + what)):
        print("HTTP 502: Bad Gateway (fake rel-fail-%s)" % what, file=sys.stderr); sys.exit(1)
def _rels():
    f = os.path.join(d, "releases.json")
    return json.load(open(f)) if os.path.exists(f) else []
def _save_rels(x): json.dump(x, open(os.path.join(d, "releases.json"), "w"))
def _pages(items):
    f = os.path.join(d, "rel-page-size")
    size = int(open(f).read()) if os.path.exists(f) else 100
    pages = [items[i:i + size] for i in range(0, len(items), size)] or [[]]
    return pages if "--paginate" in args else pages[:1]
def _assets_from(paths):
    import base64
    return [{"name": os.path.basename(f), "b64": base64.b64encode(open(f, "rb").read()).decode()} for f in paths]
if args[:1] == ["api"] and len(args) > 1 and "/releases" in args[1].split("?")[0]:
    _rel_fail("list")
    flt = _opt("--jq") or "."
    for page in _pages([dict(r, assets=[{"name": a["name"]} for a in r.get("assets", [])]) for r in _rels()]):
        _jq(flt, page)
    sys.exit(0)
if args[:1] == ["api"] and len(args) > 1 and "/git/matching-refs/" in args[1]:
    _rel_fail("refs")
    prefix = "refs/" + args[1].split("/git/matching-refs/", 1)[1]
    f = os.path.join(d, "refs.json")
    refs = [r for r in (json.load(open(f)) if os.path.exists(f) else []) if r["ref"].startswith(prefix)]
    for page in _pages(refs):
        _jq(_opt("--jq") or ".", page)
    sys.exit(0)
if args[:1] == ["api"] and len(args) > 1 and "/git/tags/" in args[1]:
    _rel_fail("tag")
    f = os.path.join(d, "tags.json")
    tags = json.load(open(f)) if os.path.exists(f) else {}
    sha = args[1].rsplit("/", 1)[1]
    if sha not in tags:
        print("HTTP 404: Not Found", file=sys.stderr); sys.exit(1)
    _jq(_opt("--jq") or ".", tags[sha]); sys.exit(0)
if args[:1] == ["release"]:
    import base64
    sub, tag = args[1], args[2]
    _rel_fail(sub)
    rels = _rels()
    rel = next((r for r in rels if r["tag_name"] == tag), None)
    files = []
    j = 3
    while j < len(args):
        if args[j] in ("--pattern", "-p", "--dir", "-D", "--target", "--title", "-t", "--notes-file", "-F"):
            j += 2
        elif args[j].startswith("-"):
            j += 1
        else:
            files.append(args[j]); j += 1
    if sub == "create":
        if rel is not None:
            print("HTTP 422: Validation Failed (tag_name already_exists)", file=sys.stderr); sys.exit(1)
        latest = next((a for a in args if a.startswith("--latest")), None)
        rels.append({"tag_name": tag, "draft": False, "target_commitish": _opt("--target"),
                     "title": _opt("--title"), "notes": open(_opt("--notes-file")).read(),
                     "latest": latest, "assets": _assets_from(files)})
        f = os.path.join(d, "refs.json")
        refs = json.load(open(f)) if os.path.exists(f) else []
        refs.append({"ref": "refs/tags/" + tag, "object": {"type": "commit", "sha": _opt("--target")}})
        json.dump(refs, open(f, "w")); _save_rels(rels); sys.exit(0)
    if rel is None:
        print("release not found", file=sys.stderr); sys.exit(1)
    if sub == "view":
        # Only the 0.13.0 workflow used `release view`; tests/release/run.sh drives that copy for the
        # red half of its rows, so the fake answers it the way gh does.
        _jq(_opt("--jq") or ".", {"isDraft": rel["draft"], "targetCommitish": rel["target_commitish"],
                                  "assets": [{"name": x["name"]} for x in rel.get("assets", [])]})
        sys.exit(0)
    if sub == "download":
        pats = [args[i + 1] for i, a in enumerate(args[:-1]) if a in ("--pattern", "-p")]
        out = _opt("--dir") or _opt("-D") or "."
        import fnmatch
        for a in rel.get("assets", []):
            if any(fnmatch.fnmatch(a["name"], pt) for pt in pats):
                open(os.path.join(out, a["name"]), "wb").write(base64.b64decode(a["b64"]))
        sys.exit(0)
    if sub == "upload":
        new = _assets_from(files)
        names = {a["name"] for a in new}
        if "--clobber" not in args and names & {a["name"] for a in rel.get("assets", [])}:
            print("asset exists", file=sys.stderr); sys.exit(1)
        rel["assets"] = [a for a in rel.get("assets", []) if a["name"] not in names] + new
        _save_rels(rels); sys.exit(0)
    if sub == "edit":
        if "--draft=false" in args: rel["draft"] = False
        if _opt("--title") is not None: rel["title"] = _opt("--title")
        if _opt("--notes-file") is not None: rel["notes"] = open(_opt("--notes-file")).read()
        rel["latest"] = next((a for a in args if a.startswith("--latest")), rel.get("latest"))
        _save_rels(rels); sys.exit(0)
def _colour_json(text):
    # Like gh 2.103.0: CLICOLOR_FORCE=1 colours JSON output even into a pipe, and NO_COLOR does not
    # undo it. Every token gets an escape code, so a parser that does not refuse it reads nothing.
    if os.environ.get("CLICOLOR_FORCE") == "1" and not any(a == "--jq" for a in args):
        return "".join("\033[1;37m%s\033[m" % ch if ch in "[]{}:," else ch for ch in text)
    return text
# ---- the pull request's file list, for path-floor.sh --pr ------------------------------------------
# `files.json` holds the entries as the REST endpoint gives them ({filename, status, previous_filename}).
# `pr view --json changedFiles` answers pr.json's "changedFiles", or the length of files.json. Files:
#   files-fail          the files call exits 1
#   files-page-size     entries per page (default 100); with --paginate each page is its own array
_fpath = next((a for a in args[1:] if not a.startswith("-")), "")  # skip --paginate before the path
if args[:1] == ["api"] and _fpath.split("?")[0].endswith("/files") and "/pulls/" in _fpath:
    f = os.path.join(d, "files.json")
    if not os.path.exists(f) or os.path.exists(os.path.join(d, "files-fail")):
        print("HTTP 502: Bad Gateway (fake files-fail)", file=sys.stderr); sys.exit(1)
    items = json.load(open(f))
    if not isinstance(items, list):  # a non-list answer goes out verbatim, so the script's own check fires
        sys.stdout.write(open(f).read()); sys.exit(0)
    fs = os.path.join(d, "files-page-size")
    size = int(open(fs).read()) if os.path.exists(fs) else 100
    pages = [items[i:i + size] for i in range(0, len(items), size)] or [[]]
    if "--paginate" not in args: pages = pages[:1]
    sys.stdout.write(_colour_json("".join(json.dumps(pg) for pg in pages)) + "\n"); sys.exit(0)
if args[:2] == ["pr", "view"]:
    if not os.path.exists(p): sys.exit(1)
    pr = with_ids(load())
    f = os.path.join(d, "files.json")
    if "changedFiles" not in pr and os.path.exists(f): pr["changedFiles"] = len(json.load(open(f)))
    sys.stdout.write(_colour_json(json.dumps(pr))); sys.exit(0)
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
    # The real endpoint answers {"permission": <legacy>, "role_name": <role>}: maintain reads as
    # write and triage as read in the legacy field. A fixture names the role, or gives both fields
    # as an object (a custom role, whose name can hold spaces). The --jq runs through real jq, as
    # gh runs it, so a filter is tested as written.
    role = perms[login]
    obj = role if isinstance(role, dict) else \
        {"permission": {"maintain": "write", "triage": "read"}.get(role, role), "role_name": role}
    jq = next((args[i + 1] for i, a in enumerate(args[:-1]) if a == "--jq"), "")
    if not jq: print(json.dumps(obj)); sys.exit(0)
    import subprocess
    r = subprocess.run(["jq", "-r", jq], input=json.dumps(obj), capture_output=True, text=True)
    sys.stdout.write(r.stdout); sys.exit(r.returncode)
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
        # them; issue comments come from "comments" (authorAssociation defaults to NONE and
        # isMinimized to false, as GraphQL never leaves it out). Files:
        #   ff-fail-<threads|reviews|comments>   that query exits 1
        #   ff-nocursor-<...>                    the first page says there is more and gives no cursor
        #   ff-badshape-<...>                    the answer lacks the connection
        #   ff-page-size                         nodes per page (default 100)
        key = ff.lower(); field = {"threads": "reviewThreads", "reviews": "reviews", "comments": "comments"}[key]
        if os.path.exists(os.path.join(d, "ff-fail-" + key)): sys.exit(1)
        if os.path.exists(os.path.join(d, "ff-badshape-" + key)):
            print(json.dumps({"data": {"repository": {"pullRequest": {}}}})); sys.exit(0)
        if key == "comments":
            nodes = [dict({"authorAssociation": "NONE", "lastEditedAt": None, "editor": None, "isMinimized": False}, **c)
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
    text = open(dp).read()
    # Like gh 2.102.0: CLICOLOR_FORCE=1 colours a redirected diff unless --color=never is given.
    never = "--color=never" in args or any(a == "--color" and b == "never" for a, b in zip(args, args[1:]))
    if os.environ.get("CLICOLOR_FORCE") == "1" and not never:
        # gh colours the header, ---/+++ and +/- lines; rename, similarity, mode and @@ lines stay plain.
        col = lambda ln: ("\033[1;37m%s\033[m" % ln) if ln.startswith(("diff --git", "index ", "--- ", "+++ ", "+", "-")) else ln
        text = "".join(col(ln) + "\n" for ln in text.split("\n")[:-1]) if text.endswith("\n") else text
    sys.stdout.write(text); sys.exit(0)
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
