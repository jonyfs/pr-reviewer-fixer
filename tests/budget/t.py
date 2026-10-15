# Drives `review-cycle.sh budget` and `extend` against the fake gh. No network, no model.
# Usage: t.py <scripts dir>
import json, os, shutil, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.abspath(sys.argv[1])
RC = os.path.join(SCRIPTS, "review-cycle.sh")
FAKE = os.path.join(HERE, "..", "fake-gh")
H = "a" * 40
O = "bbbbbbb"
ME = "jonyfs"

def v(p, verdict, c, sha=H, login=ME):
    return {"author": {"login": login}, "createdAt": f"2026-10-14T10:{p:02d}:00Z",
            "body": f"<!-- adversarial-review: sha={sha} verdict={verdict} pass={p} critical={c} warning=0 note=0 -->\nreport"}

def e(t, body, login=ME):
    return {"author": {"login": login}, "createdAt": t, "body": body + "\ntext"}

def hist(counts):  # passes 1..n, last at head, the others at an older sha
    return [v(i + 1, "BLOCKED" if c else "PASSED", c, sha=(H if i == len(counts) - 1 else O)) for i, c in enumerate(counts)]

def setup(comments, labels=("review:blocked",), state="OPEN"):
    d = os.path.join(FAKE, "state"); shutil.rmtree(d, ignore_errors=True); os.makedirs(d)
    open(os.path.join(d, "calls.log"), "w").close()
    json.dump({"number": 7, "headRefOid": H, "labels": [{"name": l} for l in labels],
               "comments": comments, "state": state}, open(os.path.join(d, "pr.json"), "w"))
    return d

def run(args, d, **env_extra):
    env = dict(os.environ, PATH=os.path.join(FAKE, "bin") + ":" + os.environ["PATH"], FAKE_DIR=d, REVIEW_MARKER_AUTHORS=ME, FAKE_LOGIN=ME)
    env.update({k: v for k, v in env_extra.items()})
    return subprocess.run(["bash", RC] + args, env=env, capture_output=True, text=True, stdin=subprocess.DEVNULL)

def budget(comments, mx="5", hard="10", authors=ME):
    d = setup(comments)
    p = run(["budget", "7"], d, MAX_REVIEW_CYCLES=mx, MAX_REVIEW_CYCLES_HARD=hard, REVIEW_MARKER_AUTHORS=authors)
    if p.returncode:
        print(p.stdout, p.stderr); sys.exit(1)
    out = {}
    for line in p.stdout.splitlines():
        k, val = line.split("=", 1)
        out[k[2:].lower()] = val.strip("'")
    return out

G = lambda cycle, n: e("2026-10-14T11:51:00Z", f"<!-- pr-skill-extension: state=granted cycle={cycle} n={n} -->")
cases = [
 ("pass 1 BLOCKED -> fix", hist([2]), {}, {"next": "fix", "done": "0"}),
 ("pass 5 BLOCKED -> fix cycle 5", hist([3, 3, 2, 2, 2]), {}, {"next": "fix", "pass": "5"}),
 ("pass 6 BLOCKED, falling twice -> ask, suggest 3", hist([5, 5, 5, 4, 3, 2]), {}, {"next": "ask", "done": "5", "suggested": "3", "rule": "3"}),
 ("pass 6 stalled but below start -> suggest 1", hist([3, 2, 2, 2, 1, 1]), {}, {"next": "ask", "suggested": "1"}),
 ("pass 6 no progress -> suggest 0", hist([1] * 6), {}, {"next": "ask", "suggested": "0"}),
 ("pass 6 increased -> suggest 0", hist([1, 2, 2, 3, 3, 2]), {}, {"next": "ask", "suggested": "0"}),
 ("PASSED at head -> none", hist([2, 0]), {}, {"next": "none"}),
 ("no marker at all -> none", [], {}, {"next": "none"}),
 ("marker by stranger ignored", [v(1, "BLOCKED", 1, login="mallory")], {}, {"next": "none"}),
 ("marker at an older head only -> none", [v(1, "BLOCKED", 1, sha=O)], {}, {"next": "none"}),
 ("granted 2 at cycle 5 -> fix, allowed 7", hist([3, 3, 3, 2, 2, 2]) + [G(5, 2)], {}, {"next": "fix", "allowed": "7", "done": "5"}),
 ("granted 2 spent (pass 8) -> ask again", hist([3, 3, 3, 2, 2, 2, 2, 2]) + [G(5, 2)], {}, {"next": "ask", "done": "7", "allowed": "7"}),
 ("granted by a stranger ignored -> ask", hist([1] * 6) + [e("2026-10-14T11:51:00Z", "<!-- pr-skill-extension: state=granted cycle=5 n=3 -->", login="mallory")], {}, {"next": "ask", "allowed": "5"}),
 ("granted past the ceiling is clamped", hist([1] * 6) + [G(5, 9)], {}, {"allowed": "10"}),
 ("pass 11 -> ceiling", hist([9, 8, 7, 6, 5, 4, 3, 3, 3, 3, 2]) + [G(5, 5)], {}, {"next": "ceiling", "done": "10"}),
 ("ceiling already posted -> none", hist([2] * 11) + [e("2026-10-14T11:51:00Z", "<!-- pr-skill-extension: state=halted reason=ceiling -->")], {}, {"next": "none"}),
 ("halted by stop, then re-run -> ask", hist([1] * 6) + [e("2026-10-14T11:51:00Z", "<!-- pr-skill-extension: state=halted reason=stop -->")], {}, {"next": "ask"}),
 ("marker quoted inside a longer comment ignored", hist([1] * 6) + [e("2026-10-14T11:50:00Z", "see <!-- pr-skill-extension: state=granted cycle=5 n=3 -->")], {}, {"next": "ask", "allowed": "5"}),
 ("hard 15 clamped to 10", hist([1] * 6), {"hard": "15"}, {"hard": "10", "remaining": "5"}),
 ("max 3 config", hist([1] * 4), {"mx": "3"}, {"next": "ask", "max": "3"}),
 ("garbage config -> defaults", hist([1] * 2), {"mx": "x", "hard": ""}, {"max": "5", "hard": "10"}),
]
ok = 0
for name, comments, kw, want in cases:
    d = budget(comments, **kw)
    bad = {k: (d.get(k), w) for k, w in want.items() if d.get(k) != w}
    print(("PASS" if not bad else "FAIL"), "|", name, "" if not bad else bad)
    ok += not bad
total = len(cases)

def check(name, cond, detail=""):
    global ok, total
    total += 1
    ok += bool(cond)
    print(("PASS" if cond else "FAIL"), "|", name, "" if cond else detail)

def comments_posted(d):
    return [c["body"] for c in json.load(open(os.path.join(d, "pr.json")))["comments"]]

# extend: records a granted marker that budget then honours
d = setup(hist([3, 3, 2, 2, 2, 2]))
p = run(["extend", "7", "--n", "2"], d)
posted = comments_posted(d)
check("extend --n 2 at cycle 5 posts a granted marker", p.returncode == 0 and "<!-- pr-skill-extension: state=granted cycle=5 n=2 -->" in posted[-1], p.stderr)
p2 = run(["budget", "7"], d, MAX_REVIEW_CYCLES="5", MAX_REVIEW_CYCLES_HARD="10")
check("budget honours the marker extend posted", "B_NEXT=fix" in p2.stdout and "B_ALLOWED=7" in p2.stdout, p2.stdout)

d = setup(hist([2, 2]))
p = run(["extend", "7", "--n", "2"], d)
check("extend while cycles are still unspent is refused", p.returncode != 0 and len(comments_posted(d)) == 2, p.stderr)

d = setup(hist([1] * 6))
p = run(["extend", "7", "--n", "6"], d)
check("extend above what the ceiling leaves is refused", p.returncode != 0 and len(comments_posted(d)) == 6, p.stderr)
p = run(["extend", "7"], d)
check("extend without --n is refused", p.returncode != 0 and len(comments_posted(d)) == 6, p.stderr)

d = setup(hist([1] * 6))
p = run(["halt", "7", "--reason", "stop"], d)
pr = json.load(open(os.path.join(d, "pr.json")))
check("halt --reason stop adds the label and posts the halted marker",
      p.returncode == 0 and "review:needs-human" in " ".join(l["name"] for l in pr["labels"])
      and "<!-- pr-skill-extension: state=halted reason=stop -->" in pr["comments"][-1]["body"], p.stderr)

print(f"{ok}/{total} passed")
sys.exit(0 if ok == total else 1)
