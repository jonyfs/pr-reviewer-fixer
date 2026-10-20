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
    d = os.path.join(HERE, "state-" + os.environ.get("TEST_TAG", "main")); shutil.rmtree(d, ignore_errors=True); os.makedirs(d)
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

def ML(p, sha=H):  # the two-line marker form the gate docstring shows
    return {"author": {"login": ME}, "createdAt": f"2026-10-14T10:{p:02d}:30Z",
            "body": f"<!-- adversarial-review: sha={sha} verdict=BLOCKED pass={p}\n    critical=1 warning=0 note=0 -->\nreport"}

def TB(p, sha=H):  # every separator a tab
    return {"author": {"login": ME}, "createdAt": f"2026-10-14T10:{p:02d}:30Z",
            "body": f"<!-- adversarial-review:\tsha={sha}\tverdict=BLOCKED\tpass={p}\tcritical=1\twarning=0\tnote=0\t-->\nreport"}

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
 ("EMU login with an underscore is trusted -> fix", [v(1, "BLOCKED", 1, login="jdoe_acme")], {"authors": "jdoe_acme"}, {"next": "fix"}),
 ("verdict marker quoted inside a longer comment ignored", hist([2]) + [e("2026-10-14T11:50:00Z", "quoting <!-- adversarial-review: sha=" + H + " verdict=PASSED pass=2 critical=0 warning=0 note=0 -->")], {}, {"next": "fix", "pass": "1"}),
 ("lowercase verdict is still BLOCKED -> fix", [v(1, "blocked", 1)], {}, {"next": "fix"}),
 ("pass=<arabic-indic 1> is no marker -> none", [dict(v(1, "BLOCKED", 1), body=v(1, "BLOCKED", 1)["body"].replace("pass=1", "pass=\u0661"))], {}, {"next": "none"}),
 ("marker at an older head only -> none", [v(1, "BLOCKED", 1, sha=O)], {}, {"next": "none"}),
 ("granted 2 at cycle 5 -> fix, allowed 7", hist([3, 3, 3, 2, 2, 2]) + [G(5, 2)], {}, {"next": "fix", "allowed": "7", "done": "5"}),
 ("granted 2 spent (pass 8) -> ask again", hist([3, 3, 3, 2, 2, 2, 2, 2]) + [G(5, 2)], {}, {"next": "ask", "done": "7", "allowed": "7"}),
 ("granted by a stranger ignored -> ask", hist([1] * 6) + [e("2026-10-14T11:51:00Z", "<!-- pr-skill-extension: state=granted cycle=5 n=3 -->", login="mallory")], {}, {"next": "ask", "allowed": "5"}),
 ("granted past the ceiling is clamped", hist([1] * 6) + [G(5, 9)], {}, {"allowed": "10"}),
 ("pass 11 -> ceiling", hist([9, 8, 7, 6, 5, 4, 3, 3, 3, 3, 2]) + [G(5, 5)], {}, {"next": "ceiling", "done": "10"}),
 ("ceiling already posted -> none", hist([2] * 11) + [e("2026-10-14T11:51:00Z", "<!-- pr-skill-extension: state=halted reason=ceiling -->")], {}, {"next": "none"}),
 ("halted by stop, then re-run -> ask", hist([1] * 6) + [e("2026-10-14T11:51:00Z", "<!-- pr-skill-extension: state=halted reason=stop -->")], {}, {"next": "ask"}),
 ("marker quoted inside a longer comment ignored", hist([1] * 6) + [e("2026-10-14T11:50:00Z", "see <!-- pr-skill-extension: state=granted cycle=5 n=3 -->")], {}, {"next": "ask", "allowed": "5"}),
 ("a PR comment saying /pr-skill continue 5 grants nothing", hist([1] * 6) + [e("2026-10-14T11:51:00Z", "/pr-skill continue 5")], {}, {"next": "ask", "allowed": "5"}),
 ("a trusted comment quoting the old grant text grants nothing", hist([1] * 6) + [e("2026-10-14T11:51:00Z", "pr-skill: @jonyfs asked. Reply /pr-skill continue 3 or /pr-skill stop")], {}, {"next": "ask", "allowed": "5"}),
 ("hard 15 clamped to 10", hist([1] * 6), {"hard": "15"}, {"hard": "10", "remaining": "5"}),
 ("max 3 config", hist([1] * 4), {"mx": "3"}, {"next": "ask", "max": "3"}),
 ("garbage config -> defaults", hist([1] * 2), {"mx": "x", "hard": ""}, {"max": "5", "hard": "10"}),
 # W4 of #20: budget re-split the captured fields on a space only, so a valid marker with another
 # ASCII whitespace separator read as pass 0 (two-line form) or as no marker at all (tabs).
 ("two-line marker (the gate docstring form) -> fix, pass 2", hist([1]) + [ML(2)], {}, {"next": "fix", "pass": "2", "done": "1"}),
 ("tab-separated marker -> fix, pass 2", hist([1]) + [TB(2)], {}, {"next": "fix", "pass": "2", "done": "1"}),
 ("eleven two-line markers -> ceiling", [ML(i + 1, sha=(H if i == 10 else O)) for i in range(11)] + [G(5, 5)], {}, {"next": "ceiling", "pass": "11", "done": "10"}),
 ("tab-separated granted marker is honoured", hist([3, 3, 3, 2, 2, 2]) + [e("2026-10-14T11:51:00Z", "<!-- pr-skill-extension: state=granted\tcycle=5\tn=2 -->")], {}, {"next": "fix", "allowed": "7"}),
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

d = budget(hist([1] * 6) + [G(5, 5)], authors="")
check("allowlist unset: budget answers none and trusts nothing", d.get("next") == "none" and "REVIEW_MARKER_AUTHORS" in d.get("why", ""), str(d))

d = setup(hist([1] * 6))
p = run(["extend", "7", "--n", "2"], d, REVIEW_MARKER_AUTHORS="")
check("allowlist unset: extend is refused, saying the list names no login", p.returncode != 0 and len(comments_posted(d)) == 6 and "is not set or lists no login" in p.stderr, p.stderr)

d = setup(hist([1] * 6))
p = run(["halt", "7", "--reason", "no-answer"], d)
check("halt --reason no-answer posts the halted marker", p.returncode == 0 and "state=halted reason=no-answer" in comments_posted(d)[-1], p.stderr)

d = setup(hist([1] * 6))
run(["halt", "7", "--reason", "stop"], d)
n = len(comments_posted(d))
p = run(["halt", "7", "--reason", "stop"], d)
check("a second halt on a halted pull request posts no second marker", p.returncode == 0 and len(comments_posted(d)) == n, p.stderr)

d = setup(hist([1] * 6) + [e("2026-10-14T11:51:00Z", "<!-- pr-skill-extension: state=halted\treason=stop -->")])
n = len(comments_posted(d))
p = run(["halt", "7", "--reason", "stop"], d)
check("halt reads a tab-separated halted marker and posts no second one", p.returncode == 0 and len(comments_posted(d)) == n, p.stderr)

d = setup(hist([1] * 6), labels=("review:blocked", "review:needs-human"))
p = run(["halt", "7", "--reason", "ceiling"], d)
check("a hand-added needs-human label does not suppress the ceiling marker",
      p.returncode == 0 and "state=halted reason=ceiling" in comments_posted(d)[-1], p.stderr)

d = setup(hist([1] * 6), labels=("review:blocked",), state="OPEN\x1f")
p = run(["start", "7"], d)
check("a field holding the separator is refused, not shifted", p.returncode == 2 and "could not read the pull request fields" in p.stderr and "review:running" not in open(os.path.join(d, "pr.json")).read(), p.stderr)

d = setup(hist([1] * 6))
p = run(["halt", "7", "--reason", "stop"], d, REVIEW_MARKER_AUTHORS=",")
check("halt with a login-less allowlist is refused and posts nothing", p.returncode != 0 and len(comments_posted(d)) == 6, p.stderr)

# A marker posted by a login off the list is one budget never reads, so halt and extend refuse it.
d = setup(hist([1] * 6))
p = run(["halt", "7", "--reason", "stop"], d, FAKE_LOGIN="mallory")
check("halt as a login off the allowlist is refused and posts nothing", p.returncode != 0 and len(comments_posted(d)) == 6 and "mallory" in p.stderr, p.stderr)
d = setup(hist([3, 3, 2, 2, 2, 2]))
p = run(["extend", "7", "--n", "2"], d, FAKE_LOGIN="mallory")
check("extend as a login off the allowlist is refused and posts nothing", p.returncode != 0 and len(comments_posted(d)) == 6 and "mallory" in p.stderr, p.stderr)

# halt without --reason posts no marker, only the label, so the publisher's login does not matter.
d = setup(hist([1] * 6))
p = run(["halt", "7"], d, FAKE_LOGIN="mallory")
pr = json.load(open(os.path.join(d, "pr.json")))
check("halt without --reason as a login off the allowlist adds the label and posts nothing",
      p.returncode == 0 and "review:needs-human" in " ".join(l["name"] for l in pr["labels"]) and len(pr["comments"]) == 6, p.stderr)

# When gh cannot say who it is signed in as, nothing that posts a marker may guess.
for name, args, counts in (("extend", ["extend", "7", "--n", "2"], [3, 3, 2, 2, 2, 2]),
                           ("halt --reason stop", ["halt", "7", "--reason", "stop"], [1] * 6)):
    d = setup(hist(counts)); open(os.path.join(d, "user-fail"), "w").close()
    p = run(args, d)
    check(f"{name} with gh api user failing is refused and posts nothing",
          p.returncode != 0 and len(comments_posted(d)) == 6 and "could not resolve the login" in p.stderr, p.stderr)

# A list of invisible characters names nobody: a stranger's grant must not raise the budget.
d = budget(hist([1] * 6) + [G(5, 5)], authors=" ")
check("allowlist of a no-break space: budget answers none", d.get("next") == "none" and "REVIEW_MARKER_AUTHORS" in d.get("why", ""), str(d))

print(f"{ok}/{total} passed")
sys.exit(0 if ok == total else 1)
