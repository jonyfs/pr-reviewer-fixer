import json, os, subprocess, sys, datetime
d = os.environ["FAKE_DIR"]; args = sys.argv[1:]
clock = int(open(os.path.join(d, "clock")).read())
iso = lambda t: datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
pr = json.load(open(os.path.join(d, "pr.json")))
sched = json.load(open(os.path.join(d, "scheduled.json")))
def visible():
    x = dict(pr); x["comments"] = pr["comments"] + [dict(c, createdAt=iso(c["at"])) for c in sched if c["at"] <= clock]
    return x
open(os.path.join(d, "calls.log"), "a").write(" ".join(args) + "\n")
if args[:2] == ["pr", "view"]:
    out = json.dumps(visible())
    if "--jq" in args:
        q = args[args.index("--jq") + 1]
        out = subprocess.run(["jq", "-r", q], input=out, capture_output=True, text=True).stdout
    sys.stdout.write(out); sys.exit(0)
if args[:2] == ["pr", "comment"]:
    body = open(args[args.index("--body-file") + 1]).read()
    pr["comments"].append({"body": body, "author": {"login": "github-actions"}, "createdAt": iso(clock)})
    json.dump(pr, open(os.path.join(d, "pr.json"), "w")); sys.exit(0)
if args[:1] == ["api"] and args[1].endswith("/permission"):
    login = args[1].split("/")[-2]
    perms = json.load(open(os.path.join(d, "perms.json")))
    if login not in perms: sys.exit(1)
    print(perms[login]); sys.exit(0)
print("fake gh: unhandled " + " ".join(args), file=sys.stderr); sys.exit(1)
