import json, os, sys
d, args = sys.argv[1], sys.argv[2:]
p = os.path.join(d, "pr.json")
def load(): return json.load(open(p))
def save(x): json.dump(x, open(p, "w"))
def known(name):
    k = os.path.join(d, "known-labels")
    return (not os.path.exists(k)) or name in open(k).read().split()
if args[:2] == ["pr", "view"]:
    if not os.path.exists(p): sys.exit(1)
    sys.stdout.write(open(p).read()); sys.exit(0)
if args[:2] == ["pr", "edit"]:
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
if args[:2] == ["pr", "comment"]:
    body = sys.stdin.read()
    if len(body) > 65536:
        print("body is too long (maximum is 65536 characters)", file=sys.stderr); sys.exit(1)
    pr = load()
    pr["comments"].append({"body": body, "author": {"login": os.environ.get("FAKE_LOGIN", "github-actions")}})
    save(pr); sys.exit(0)
if args[:2] == ["label", "create"]:
    sys.exit(0)
print("fake gh: unhandled " + " ".join(args), file=sys.stderr); sys.exit(1)
