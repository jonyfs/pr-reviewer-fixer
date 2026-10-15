# Drives the extension-wait `run:` step of a stage template against a fake gh and a fake clock.
import json, os, shutil, subprocess, sys, datetime, yaml
T = os.path.dirname(os.path.abspath(__file__))
tpl = sys.argv[1]
y = yaml.safe_load(open(tpl))
env_tpl = y["env"]; script = [s for s in y["jobs"]["extension-wait"]["steps"] if s.get("id") == "wait"][0]["run"]
H = "a" * 40; T0 = 1791979200  # 2026-10-14T12:00:00Z
iso = lambda t: datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
def v(p, c, sha):
    body = f"<!-- adversarial-review: sha={sha} verdict={'BLOCKED' if c else 'PASSED'} pass={p} critical={c} warning=0 note=0 -->\nreport\n"
    if sha == H:
        body += "```findings\nversion: 1\nfindings:\n  - id: C1\n    severity: CRITICAL\n    claim: \"Token accepted after expiry\"\n    status: open\n```\n"
    return {"author": {"login": "github-actions"}, "createdAt": iso(T0 - 3600 + p * 60), "body": body}
def hist(counts): return [v(i + 1, c, H if i == len(counts) - 1 else "b" * 40) for i, c in enumerate(counts)]
def reply(at, login, text): return {"at": T0 + at, "author": {"login": login}, "body": text + "\nthanks"}
def run(name, comments, sched, perms, labels=("review:blocked",), check=None):
    d = os.path.join(T, "state", name.replace(" ", "_")[:40]); shutil.rmtree(d, ignore_errors=True); os.makedirs(d)
    open(os.path.join(d, "clock"), "w").write(str(T0))
    json.dump({"headRefOid": H, "author": {"login": "alice"}, "labels": [{"name": l} for l in labels], "comments": comments}, open(os.path.join(d, "pr.json"), "w"))
    json.dump(sched, open(os.path.join(d, "scheduled.json"), "w")); json.dump(perms, open(os.path.join(d, "perms.json"), "w"))
    wd = os.path.join(d, "wd"); sd = os.path.join(wd, ".agents/skills/pr-reviewer/scripts"); os.makedirs(sd)
    open(os.path.join(sd, "review-cycle.sh"), "w").write("#!/usr/bin/env bash\necho \"#7 at aaaaaaa: BLOCKED (review owed)\"\nexit 1\n"); os.chmod(os.path.join(sd, "review-cycle.sh"), 0o755)
    env = dict(os.environ, PATH=os.path.join(T, "bin") + ":" + os.environ["PATH"], FAKE_DIR=d, PR="7", GITHUB_REPOSITORY="o/r",
               REVIEW_MARKER_AUTHORS="github-actions", MAX_RC="5", HARD_RC="10", WAIT_S="300",
               MARKER_JQ=env_tpl["MARKER_JQ"], BUDGET_JQ=env_tpl["BUDGET_JQ"], OPEN_AWK=env_tpl["OPEN_AWK"],
               GITHUB_OUTPUT=os.path.join(d, "out"), GITHUB_STEP_SUMMARY=os.path.join(d, "summary"), RUNNER_TEMP=d)
    p = subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", script], cwd=wd, env=env, capture_output=True, text=True)
    pr = json.load(open(os.path.join(d, "pr.json")))
    posted = [c["body"] for c in pr["comments"][len(comments):]]
    out = dict(l.split("=", 1) for l in open(os.path.join(d, "out")).read().split()) if os.path.exists(os.path.join(d, "out")) else {}
    elapsed = int(open(os.path.join(d, "clock")).read()) - T0
    calls = open(os.path.join(d, "calls.log")).read()
    ok, why = check(p.returncode, posted, out, elapsed, calls)
    return ok, why, p.stderr
W = {"maint": "maintain", "adm": "admin", "wr": "write", "reader": "read"}
B6 = hist([3, 3, 2, 2, 1, 1])
cases = [
 ("authorized continue 2 -> granted", B6, [reply(40, "wr", "/pr-skill continue 2")], W,
  lambda rc, posted, out, el, calls: (rc == 0 and len(posted) == 2 and "state=asked cycle=5" in posted[0] and "<!-- pr-skill-extension: state=granted n=2 -->" in posted[1] and out.get("granted") == "true" and out.get("allowed") == "7", f"rc={rc} out={out} n={len(posted)}")),
 ("question carries marker fields, progress, grammar", B6, [reply(20, "adm", "/pr-skill stop")], W,
  lambda rc, posted, out, el, calls: (all(s in posted[0] for s in ["asked_at=2026-10-14T12:00:00Z", "expires_at=2026-10-14T12:05:00Z", "suggested=1", "pass 1: 3, pass 2: 3", "C1: Token accepted after expiry", "/pr-skill continue N", "from 1 to 5"]), posted[0][:400])),
 ("authorized stop -> halted reason=stop", B6, [reply(20, "adm", "/pr-skill stop")], W,
  lambda rc, posted, out, el, calls: (rc == 0 and posted[-1].startswith("<!-- pr-skill-extension: state=halted reason=stop -->") and "Stopped by @adm after cycle 5" in posted[-1] and out.get("granted") == "false", posted[-1][:200])),
 ("no answer -> halted after 300 s", B6, [], W,
  lambda rc, posted, out, el, calls: (rc == 0 and "state=halted reason=no-answer-in-300s" in posted[-1] and "No answer within 5 minutes after cycle 5. 1 CRITICAL still open: C1: Token accepted after expiry. The pull request stays review:blocked and needs a person." in posted[-1] and 300 <= el <= 315, f"el={el} {posted[-1][:300]}")),
 ("read-only login ignored, nothing posted for it", B6, [reply(10, "reader", "/pr-skill continue 3")], W,
  lambda rc, posted, out, el, calls: (len(posted) == 2 and "reason=no-answer-in-300s" in posted[-1], [p[:60] for p in posted])),
 ("unknown login (no permission) ignored", B6, [reply(10, "mallory", "/pr-skill continue 3"), reply(30, "maint", "/pr-skill continue 1")], W,
  lambda rc, posted, out, el, calls: ("state=granted n=1" in posted[-1] and "by @maint" in posted[-1], posted[-1][:120])),
 ("N above remaining ignored", B6, [reply(10, "wr", "/pr-skill continue 9")], W,
  lambda rc, posted, out, el, calls: ("reason=no-answer-in-300s" in posted[-1], posted[-1][:80])),
 ("first valid reply wins", B6, [reply(10, "wr", "/pr-skill continue 1"), reply(11, "adm", "/pr-skill stop")], W,
  lambda rc, posted, out, el, calls: ("state=granted n=1" in posted[-1] and len(posted) == 2, posted[-1][:80])),
 ("text not on the first line ignored", B6, [reply(10, "wr", "please\n/pr-skill continue 1")], W,
  lambda rc, posted, out, el, calls: ("reason=no-answer" in posted[-1], posted[-1][:80])),
 ("reply after the deadline ignored", B6, [reply(320, "wr", "/pr-skill continue 1")], W,
  lambda rc, posted, out, el, calls: ("reason=no-answer" in posted[-1], posted[-1][:80])),
 ("ceiling -> halted, no question", hist([2] * 11), [], W,
  lambda rc, posted, out, el, calls: (len(posted) == 1 and posted[0].startswith("<!-- pr-skill-extension: state=halted reason=ceiling -->") and el == 0, posted[0][:160])),
 ("label mismatch reported, never relabelled", B6, [reply(5, "wr", "/pr-skill stop")], W,
  lambda rc, posted, out, el, calls: ("found review:fixing where review:blocked was expected" in posted[-1] and "pr edit" not in calls, posted[-1][:400])),
 ("expired question settled from old replies", B6 + [{"author": {"login": "github-actions"}, "createdAt": iso(T0 - 600), "body": f"<!-- pr-skill-extension: state=asked cycle=5 asked_at={iso(T0-600)} expires_at={iso(T0-300)} suggested=1 -->\nq"}],
  [reply(-500, "wr", "/pr-skill continue 2")], W,
  lambda rc, posted, out, el, calls: (len(posted) == 1 and "state=granted n=2" in posted[0] and el == 0, [p[:60] for p in posted])),
]
fixups = {"label mismatch reported, never relabelled": ("review:fixing",)}
okn = 0
for name, comments, sched, perms, check in cases:
    ok, why, err = run(name, comments, sched, perms, labels=fixups.get(name, ("review:blocked",)), check=check)
    okn += ok
    print(("PASS" if ok else "FAIL"), "|", name, "" if ok else f"-- {why} {err[-300:]}")
print(f"{okn}/{len(cases)} passed")
