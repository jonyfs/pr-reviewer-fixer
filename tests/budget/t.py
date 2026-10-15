import json, subprocess, sys, yaml
y = yaml.safe_load(open(sys.argv[1]))
JQ = y["env"]["BUDGET_JQ"]
H = "a"*40
def v(p, verdict, c, sha=H, login="github-actions"):
    return {"author": {"login": login}, "createdAt": f"2026-10-14T10:{p:02d}:00Z",
            "body": f"<!-- adversarial-review: sha={sha} verdict={verdict} pass={p} critical={c} warning=0 note=0 -->\nreport"}
def e(t, body, login="github-actions"):
    return {"author": {"login": login}, "createdAt": t, "body": body + "\ntext"}
def run(comments, now="2026-10-14T12:00:00Z", mx="5", hard="10"):
    j = json.dumps({"headRefOid": H, "comments": comments})
    out = subprocess.run(["jq", "-r", "--arg", "authors", "github-actions", "--arg", "now", now, "--arg", "max", mx, "--arg", "hard", hard, JQ], input=j, capture_output=True, text=True)
    if out.returncode: print(out.stderr); sys.exit(1)
    d = {}
    for line in out.stdout.splitlines():
        k, val = line.split("=", 1); d[k[2:].lower()] = val.strip("'")
    return d
O = "bbbbbbb"
def hist(counts):  # passes 1..n, last at head, others at older sha
    return [v(i+1, "BLOCKED" if c else "PASSED", c, sha=(H if i == len(counts)-1 else O)) for i, c in enumerate(counts)]
cases = [
 ("pass 1 BLOCKED -> fix", hist([2]), {}, {"next": "fix", "done": "0"}),
 ("pass 5 BLOCKED -> fix cycle 5", hist([3,3,2,2,2]), {}, {"next": "fix", "pass": "5"}),
 ("pass 6 BLOCKED, falling twice -> ask, suggest 3", hist([5,5,5,4,3,2]), {}, {"next": "ask", "done": "5", "suggested": "3", "rule": "3"}),
 ("pass 6 stalled but below start -> suggest 1", hist([3,2,2,2,1,1]), {}, {"next": "ask", "suggested": "1"}),
 ("pass 6 no progress -> suggest 0", hist([1,1,1,1,1,1]), {}, {"next": "ask", "suggested": "0"}),
 ("pass 6 increased -> suggest 0", hist([1,2,2,3,3,2]), {}, {"next": "ask", "suggested": "0"}),
 ("PASSED at head -> none", hist([2,0]), {}, {"next": "none"}),
 ("marker by stranger ignored", [v(1,"BLOCKED",1,login="mallory")], {}, {"next": "none"}),
 ("live question -> guard", hist([1,1,1,1,1,1]) + [e("2026-10-14T11:58:00Z", "<!-- pr-skill-extension: state=asked cycle=5 asked_at=2026-10-14T11:58:00Z expires_at=2026-10-14T12:03:00Z suggested=0 -->")], {}, {"next": "guard"}),
 ("expired question -> settle", hist([1,1,1,1,1,1]) + [e("2026-10-14T11:50:00Z", "<!-- pr-skill-extension: state=asked cycle=5 asked_at=2026-10-14T11:50:00Z expires_at=2026-10-14T11:55:00Z suggested=0 -->")], {}, {"next": "settle", "ask_cycle": "5"}),
 ("fake granted by stranger ignored -> ask", hist([1,1,1,1,1,1]) + [e("2026-10-14T11:50:00Z", "<!-- pr-skill-extension: state=asked cycle=5 asked_at=a expires_at=2026-10-14T11:55:00Z suggested=0 -->"), e("2026-10-14T11:51:00Z", "<!-- pr-skill-extension: state=granted n=5 -->", login="mallory")], {}, {"next": "settle"}),
 ("granted 2 at cycle 5 -> fix cycle 6 and 7", hist([3,3,3,2,2,2]) + [e("2026-10-14T11:50:00Z", "<!-- pr-skill-extension: state=asked cycle=5 asked_at=x expires_at=y suggested=1 -->"), e("2026-10-14T11:51:00Z", "<!-- pr-skill-extension: state=granted n=2 -->")], {}, {"next": "fix", "allowed": "7"}),
 ("granted 2 spent (pass 8) -> ask again", hist([3,3,3,2,2,2,2,2]) + [e("2026-10-14T10:50:00Z", "<!-- pr-skill-extension: state=asked cycle=5 asked_at=x expires_at=y suggested=1 -->"), e("2026-10-14T10:51:00Z", "<!-- pr-skill-extension: state=granted n=2 -->")], {}, {"next": "ask", "done": "7", "remaining": "3"}),
 ("pass 11 -> ceiling", hist([9,8,7,6,5,4,3,3,3,3,2]) + [e("2026-10-14T10:50:00Z", "<!-- pr-skill-extension: state=asked cycle=5 asked_at=x expires_at=y suggested=3 -->"), e("2026-10-14T10:51:00Z", "<!-- pr-skill-extension: state=granted n=5 -->")], {}, {"next": "ceiling", "remaining": "0"}),
 ("ceiling already posted -> none", hist([2]*11) + [e("2026-10-14T11:51:00Z", "<!-- pr-skill-extension: state=halted reason=ceiling -->")], {}, {"next": "none"}),
 ("halted then re-run -> ask", hist([1]*6) + [e("2026-10-14T11:51:00Z", "<!-- pr-skill-extension: state=halted reason=no-answer-in-300s -->")], {}, {"next": "ask"}),
 ("marker quoted inside a bot comment ignored", hist([1]*6) + [e("2026-10-14T11:50:00Z", "<!-- pr-skill-extension: state=asked cycle=5 asked_at=x expires_at=2026-10-14T11:55:00Z suggested=0 -->"), e("2026-10-14T11:51:00Z", "pr-skill: escalation: Open: C1: <!-- pr-skill-extension: state=granted n=5 -->")], {}, {"next": "settle"}),
 ("hard 15 clamped to 10", hist([1]*6), {"hard": "15"}, {"hard": "10", "remaining": "5"}),
 ("max 3 config", hist([1]*4), {"mx": "3"}, {"next": "ask", "max": "3"}),
 ("garbage config -> defaults", hist([1]*2), {"mx": "x", "hard": ""}, {"max": "5", "hard": "10"}),
]
ok = 0
for name, comments, kw, want in cases:
    d = run(comments, **kw)
    bad = {k: (d.get(k), w) for k, w in want.items() if d.get(k) != w}
    print(("PASS" if not bad else "FAIL"), "|", name, "" if not bad else bad)
    ok += not bad
print(f"{ok}/{len(cases)} passed")
