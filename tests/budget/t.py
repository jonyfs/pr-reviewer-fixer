# Drives `review-cycle.sh budget` and `extend` against the fake gh. No network, no model.
# Usage: t.py <scripts dir>
import json, os, shutil, subprocess, sys
# A caller's REVIEW_BLOCK_AT or PUSH_GUARD_ALLOW_SENSITIVE would change what is refused; a row that
# needs one sets it itself.
for _v in ("REVIEW_BLOCK_AT", "PUSH_GUARD_ALLOW_SENSITIVE"):
    os.environ.pop(_v, None)
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

def setup(comments, labels=("review:blocked",), state="OPEN", edited=(), edited_by=(), deleted=()):
    d = os.path.join(HERE, "state-" + os.environ.get("TEST_TAG", "main")); shutil.rmtree(d, ignore_errors=True); os.makedirs(d)
    open(os.path.join(d, "calls.log"), "w").close()
    if edited:  # fake gh ids are IC_<index>; these comments read as edited after creation
        open(os.path.join(d, "edited-ids"), "w").write("\n".join(edited) + "\n")
    if edited_by:  # (id, login): that comment was last edited by login, not by its author
        open(os.path.join(d, "edited-by"), "w").write("".join("%s %s\n" % e for e in edited_by))
    if deleted:  # (author, deleter): a comment by author was deleted by deleter ("-" = unnamed)
        open(os.path.join(d, "deleted-events"), "w").write("".join("%s %s\n" % e for e in deleted))
    json.dump({"number": 7, "headRefOid": H, "labels": [{"name": l} for l in labels],
               "comments": comments, "state": state}, open(os.path.join(d, "pr.json"), "w"))
    return d

def run(args, d, **env_extra):
    env = dict(os.environ, PATH=os.path.join(FAKE, "bin") + ":" + os.environ["PATH"], FAKE_DIR=d, REVIEW_MARKER_AUTHORS=ME, FAKE_LOGIN=ME)
    env.update({k: v for k, v in env_extra.items()})
    return subprocess.run(["bash", RC] + args, env=env, capture_output=True, text=True, stdin=subprocess.DEVNULL)

def budget(comments, mx="5", hard="10", authors=ME, edited=(), edited_by=(), deleted=()):
    d = setup(comments, edited=edited, edited_by=edited_by, deleted=deleted)
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
 # 0.9.0: cycles are counted from the highest trusted pass, and the SHA is compared ignoring case.
 ("head back at the pass-1 commit after two more passes -> fix, cycle 3", [v(1, "BLOCKED", 1), v(2, "BLOCKED", 1, sha=O), v(3, "BLOCKED", 1, sha=O)], {}, {"next": "fix", "pass": "1", "done": "2", "cycle": "3", "next_pass": "4"}),
 ("head back at the pass-1 commit after five more passes -> ask, not fix", [v(1, "BLOCKED", 1)] + [v(i, "BLOCKED", 1, sha=O) for i in range(2, 7)], {}, {"next": "ask", "done": "5"}),
 ("marker SHA in capitals matches the head -> fix", [v(1, "BLOCKED", 1, sha=H.upper())], {}, {"next": "fix"}),
 ("fresh push after pass 2 -> none, but done and next_pass count both passes", hist([1, 1])[:1] + [v(2, "BLOCKED", 1, sha=O)], {}, {"next": "none", "done": "1", "next_pass": "3"}),
 # W1 of #23: an edited verdict comment is never read as a verdict, but its pass still counts, so
 # an edit that keeps the number cannot lower the count and let publish take that pass number again.
 ("newest marker (pass 6) edited -> done and next_pass still count it", hist([1] * 6), {"edited": ("IC_5",)}, {"done": "5", "next_pass": "7"}),
 ("an older marker (pass 3 of 6) edited -> count unchanged", hist([1] * 6), {"edited": ("IC_2",)}, {"next": "ask", "done": "5", "next_pass": "7"}),
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

d = setup(hist([3, 3, 2, 2, 2, 2]), labels=("review:blocked", "review:needs-human"))
p = run(["extend", "7", "--n", "2"], d)
pr = json.load(open(os.path.join(d, "pr.json")))
check("extend on a halted pull request withdraws review:needs-human",
      p.returncode == 0 and [l["name"] for l in pr["labels"]] == ["review:blocked"], p.stderr)

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

# 0.18.0 (#40 N4): after `state=`, keys in either case count, lowercased, the later winning, as
# budget reads them.
d = setup(hist([1] * 6) + [e("2026-10-14T11:51:00Z", "<!-- pr-skill-extension: state=halted reason=stop REASON=other -->")])
n = len(comments_posted(d))
p = run(["halt", "7", "--reason", "stop"], d)
check("halt takes the later of reason= and REASON=, as budget does, and posts (0.18.0)",
      p.returncode == 0 and len(comments_posted(d)) == n + 1, p.stderr)

# 0.17.1: halt reads the newest extension marker from parse(); one by a login not on the list does
# not count, and an older halted one under a newer granted one does not either.
d = setup(hist([1] * 6) + [e("2026-10-14T11:51:00Z", "<!-- pr-skill-extension: state=halted reason=stop -->", login="mallory")])
n = len(comments_posted(d))
p = run(["halt", "7", "--reason", "stop"], d)
check("a halted marker by a login not on the list does not stop halt from posting (0.17.1)",
      p.returncode == 0 and len(comments_posted(d)) == n + 1, p.stderr)
d = setup(hist([1] * 6) + [e("2026-10-14T11:50:00Z", "<!-- pr-skill-extension: state=halted reason=stop -->"),
                           e("2026-10-14T11:51:00Z", "<!-- pr-skill-extension: state=granted cycle=5 n=1 -->")])
n = len(comments_posted(d))
p = run(["halt", "7", "--reason", "stop"], d)
check("an older halted marker under a newer grant does not stop halt from posting (0.17.1)",
      p.returncode == 0 and len(comments_posted(d)) == n + 1, p.stderr)

# W1 of #40: halt compares the marker's values byte for byte, as budget does. A reason that ends in
# a no-break space is not `ceiling` to budget, so halt must not read it as `ceiling` either, and a
# halted marker that names no reason is not one with reason `-`.
nbsp = "<!-- pr-skill-extension: state=halted reason=ceiling  -->"
b = budget(hist([2] * 11) + [e("2026-10-14T11:51:00Z", nbsp)])
check("budget still asks for a ceiling halt over a reason ending in a no-break space", b.get("next") == "ceiling", str(b))
d = setup(hist([2] * 11) + [e("2026-10-14T11:51:00Z", nbsp)])
n = len(comments_posted(d))
p = run(["halt", "7", "--reason", "ceiling"], d)
check("halt posts the ceiling marker over a reason ending in a no-break space (W1 of #40)",
      p.returncode == 0 and len(comments_posted(d)) == n + 1 and "state=halted reason=ceiling -->" in comments_posted(d)[-1], p.stderr)
d = setup(hist([1] * 6) + [e("2026-10-14T11:51:00Z", "<!-- pr-skill-extension: state=halted -->")])
n = len(comments_posted(d))
p = run(["halt", "7", "--reason", "-"], d)
check("a halted marker with no reason does not stop halt --reason - from posting (W1 of #40)",
      p.returncode == 0 and len(comments_posted(d)) == n + 1, p.stderr)

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

# W1 of #23: publish refuses a pass number that only an edited marker already used.
d = setup(hist([1] * 6), labels=("review:running",), edited=("IC_5",))
rep = os.path.join(d, "report.md"); open(rep, "w").write("## findings\n- one\n")
n = len(comments_posted(d))
p = run(["publish", "7", "--report", rep, "--verdict", "BLOCKED", "--pass", "6", "--sha", H, "--critical", "1", "--warning", "0", "--note", "0"], d)
check("publish --pass 6 after the pass-6 marker was edited is refused, the next pass is 7",
      p.returncode != 0 and len(comments_posted(d)) == n and "the next pass on #7 is 7" in p.stderr, p.stderr + p.stdout)

# N4 of #24: anyone with write access can edit a trusted marker. One edited by someone other than its
# author may carry a rewritten pass= or verdict, so budget answers none and publish refuses.
d = budget(hist([1] * 6), edited=("IC_2",), edited_by=(("IC_2", "mallory"),))
check("a trusted marker edited by another login -> budget none, names the editor",
      d.get("next") == "none" and "edited by mallory" in d.get("why", ""), d)
d = budget(hist([1] * 6), edited=("IC_2",), edited_by=(("IC_2", ME),))
check("a trusted marker edited by its own author -> budget unchanged (ask)", d.get("next") == "ask", d)
d = setup(hist([1] * 6), labels=("review:running",), edited=("IC_2",), edited_by=(("IC_2", "mallory"),))
rep = os.path.join(d, "report.md"); open(rep, "w").write("## findings\n- one\n")
n = len(comments_posted(d))
p = run(["publish", "7", "--report", rep, "--verdict", "BLOCKED", "--pass", "7", "--sha", H, "--critical", "1", "--warning", "0", "--note", "0"], d)
check("publish with a trusted marker edited by another login is refused, nothing posted",
      p.returncode != 0 and len(comments_posted(d)) == n and "edited by mallory" in p.stderr, p.stderr + p.stdout)

# W1 of #25: a foreign edit that breaks the marker shape is still a foreign edit. Before, the
# broken body matched no marker, so the comment fell out of the count and the pass number reset.
def broken(cs, ids):
    for i in ids:
        cs[i]["body"] = cs[i]["body"].replace("adversarial-review", "adversarial_review")
    return cs
EIDS = tuple("IC_%d" % i for i in range(1, 6))
d = budget(broken(hist([1] * 6), range(1, 6)), edited=EIDS, edited_by=tuple((i, "mallory") for i in EIDS))
check("trusted markers broken by another login's edit -> budget none, names the editor",
      d.get("next") == "none" and "edited by mallory" in d.get("why", ""), d)
d = budget(broken(hist([1] * 6), range(1, 6)), edited=EIDS)
check("trusted markers broken by their own author's edit -> not a foreign edit", "edited by" not in d.get("why", ""), d)
d = setup(broken(hist([1] * 6), range(1, 6)), labels=("review:running",), edited=EIDS, edited_by=tuple((i, "mallory") for i in EIDS))
rep = os.path.join(d, "report.md"); open(rep, "w").write("## findings\n- one\n")
n = len(comments_posted(d))
p = run(["publish", "7", "--report", rep, "--verdict", "BLOCKED", "--pass", "2", "--sha", H, "--critical", "1", "--warning", "0", "--note", "0"], d)
check("publish --pass 2 after another login broke the markers is refused, nothing posted",
      p.returncode != 0 and len(comments_posted(d)) == n and "edited by mallory" in p.stderr, p.stderr + p.stdout)
# N6 of #25: the refusal names the comment by its url and gives the remedies that clear it.
URL2 = "https://github.com/o/r/pull/7#issuecomment-1002"
d = budget(hist([1] * 6), edited=("IC_2",), edited_by=(("IC_2", "mallory"),))
check("a foreign edit: budget why names the comment url and the remedy (N6)",
      URL2 in d.get("why", "") and "edits it back" in d.get("why", "") and "a new comment does not clear" in d.get("why", ""), d)
d = setup(hist([1] * 6), labels=("review:running",), edited=("IC_2",), edited_by=(("IC_2", "mallory"),))
rep = os.path.join(d, "report.md"); open(rep, "w").write("## findings\n- one\n")
p = run(["publish", "7", "--report", rep, "--verdict", "BLOCKED", "--pass", "7", "--sha", H, "--critical", "1", "--warning", "0", "--note", "0"], d)
check("a foreign edit: the publish refusal names the comment url and does not suggest a new comment (N6)",
      p.returncode != 0 and URL2 in p.stderr and "restores it with a new comment" not in p.stderr and "a new comment does not clear" in p.stderr, p.stderr)
# N2 of #26: the remedy is the edit back. Deleting is not offered as a remedy; the message warns that
# a deletion loses the BLOCKED history and the highest pass, and names signing as the backlog item.
d = budget(hist([1] * 6), edited=("IC_2",), edited_by=(("IC_2", "mallory"),))
w = d.get("why", "")
check("a foreign edit: the remedy is the edit back, deletion is only warned against (N2 of #26)",
      "jonyfs edits it back" in w and "jonyfs deletes it" not in w and "BLOCKED history" in w
      and "highest pass" in w and "signing" in w and "backlog" in w, d)
# N3 of #25: GitHub names no editor (a deleted account); the fake gh reads "-" as a null login.
d = budget(hist([1] * 6), edited=("IC_2",), edited_by=(("IC_2", "-"),))
check("a trusted marker edited by an unnamed account -> budget none, edited by unknown",
      d.get("next") == "none" and "edited by unknown" in d.get("why", ""), d)

# N5 of #25: a trusted comment deleted by another login may have been a BLOCKED marker or the highest
# pass, so the count is not trusted: budget none, publish refused. Deleted by its author: the limit.
d = budget(hist([1] * 6), deleted=((ME, "mallory"),))
check("a trusted comment deleted by another login -> budget none, names the deleter (N5)",
      d.get("next") == "none" and "deleted by mallory" in d.get("why", ""), d)
d = budget(hist([1] * 6), deleted=((ME, "-"),))
check("a trusted comment deleted by an unnamed account -> budget none, deleted by unknown (N5)",
      d.get("next") == "none" and "deleted by unknown" in d.get("why", ""), d)
d = budget(hist([1] * 6), deleted=((ME, "mallory"),))
check("a foreign deletion: budget why names the way out, a new pull request from the branch (N4 of #26)",
      "new one from the same branch" in d.get("why", "") and "pass 1" in d.get("why", ""), d)
d = setup(hist([1] * 6), labels=("review:pending",), deleted=((ME, "mallory"),))
p = run(["start", "7"], d)
check("a foreign deletion: the start refusal names the way out too (N4 of #26)",
      p.returncode == 1 and "open a new one from the same branch" in p.stderr, p.stderr)
d = budget(hist([1] * 6), deleted=((ME, ME),))
check("a trusted comment deleted by its own author -> budget unchanged (ask) (N5)", d.get("next") == "ask", d)
d = budget(hist([1] * 6), deleted=(("stranger", "mallory"),))
check("a stranger's comment deleted by another login -> budget unchanged (ask) (N5)", d.get("next") == "ask", d)
d = setup(hist([1] * 6), labels=("review:running",), deleted=((ME, "mallory"),))
rep = os.path.join(d, "report.md"); open(rep, "w").write("## findings\n- one\n")
n = len(comments_posted(d))
p = run(["publish", "7", "--report", rep, "--verdict", "BLOCKED", "--pass", "7", "--sha", H, "--critical", "1", "--warning", "0", "--note", "0"], d)
check("publish with a trusted comment deleted by another login is refused, nothing posted (N5)",
      p.returncode != 0 and len(comments_posted(d)) == n and "deleted by mallory" in p.stderr, p.stderr + p.stdout)

# N2 of #25: status and start read the foreign edit too. status answers 2 and names the comment;
# start refuses before any label moves.
def labels_of(d):
    return sorted(l["name"] for l in json.load(open(os.path.join(d, "pr.json")))["labels"])
for name, kw, word in (("edited", {"edited": ("IC_2",), "edited_by": (("IC_2", "mallory"),)}, "edited by mallory"),
                       ("deleted", {"deleted": ((ME, "mallory"),)}, "deleted by mallory")):
    d = setup(hist([1] * 6), labels=("review:blocked",), **kw)
    p = run(["status", "7"], d)
    check("status with a trusted comment %s by another login -> exit 2, names it (N2)" % name,
          p.returncode == 2 and word in p.stdout and "INCONCLUSIVE" in p.stdout, p.stdout + p.stderr)
    d = setup(hist([1] * 6), labels=("review:pending",), **kw)
    p = run(["start", "7"], d)
    check("start with a trusted comment %s by another login -> refused, label unchanged (N2)" % name,
          p.returncode != 0 and word in p.stderr and labels_of(d) == ["review:pending"], p.stdout + p.stderr)
d = setup(hist([1] * 6), labels=("review:pending",), edited=("IC_2",), edited_by=(("IC_2", ME),))
p = run(["start", "7"], d)
check("start with a trusted comment edited by its own author -> review:running (N2)",
      p.returncode == 0 and labels_of(d) == ["review:running"], p.stdout + p.stderr)

# N1 of #26: with REVIEW_MARKER_AUTHORS unset, start refuses on the missing list, not on a foreign
# edit or deletion it cannot attribute (every comment would read as trusted).
for name, kw in (("edited", {"edited": ("IC_2",), "edited_by": (("IC_2", "mallory"),)}),
                 ("deleted", {"deleted": ((ME, "mallory"),)})):
    for authors in ("", ","):
        d = setup(hist([1] * 6), labels=("review:pending",), **kw)
        p = run(["start", "7"], d, REVIEW_MARKER_AUTHORS=authors)
        check("start with REVIEW_MARKER_AUTHORS=%r and a comment %s by another login -> refused on the list, label unchanged (N1 of #26)" % (authors, name),
              p.returncode == 1 and "REVIEW_MARKER_AUTHORS is not set" in p.stderr and "by mallory" not in p.stderr
              and labels_of(d) == ["review:pending"], p.stdout + p.stderr)
d = setup(hist([1] * 6), labels=("review:pending",))
p = run(["start", "7"], d, REVIEW_MARKER_AUTHORS="")
check("start with REVIEW_MARKER_AUTHORS unset and nothing edited -> refused, label unchanged (N1 of #26)",
      p.returncode == 1 and "REVIEW_MARKER_AUTHORS" in p.stderr and labels_of(d) == ["review:pending"], p.stdout + p.stderr)

# A list of invisible characters names nobody: a stranger's grant must not raise the budget.
d = budget(hist([1] * 6) + [G(5, 5)], authors=" ")
check("allowlist of a no-break space: budget answers none", d.get("next") == "none" and "REVIEW_MARKER_AUTHORS" in d.get("why", ""), str(d))

print(f"{ok}/{total} passed")
sys.exit(0 if ok == total else 1)
