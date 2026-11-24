#!/usr/bin/env python3
"""golden.py: the golden set of real pull requests. Validates cases, marks one validated, prepares a
run's inputs, picks the second judge's sample and scores a run. No model is called, and only
`prepare` touches git (local, plus a fetch when a commit is missing). Nothing here reads GitHub.

Usage:
  golden.py validate [--cases DIR]
  golden.py mark-validated <case> --login <github-login> [--date YYYY-MM-DD] [--cases DIR]
  golden.py prepare --run DIR [--cases DIR]
  golden.py sample --run DIR [--cases DIR]
  golden.py score --run DIR [--cases DIR] [--min-recall R] [--json]

A case is cases/<name>.json (tests/golden/README.md gives every field). A run is a folder:
  map.json              written by prepare: each case's neutral token
  inputs/<token>.patch  written by prepare: the case's base..head diff, under a name that hides the PR
  reports/<token>.md    the reviewer's report, ending with the fenced findings block
  judge-a/<case>.json   the primary judge's verdict (JUDGE.md)
  judge-b/<case>.json   the second judge's verdict, for every case `sample` lists

Reports are read through `review-cycle.sh findings-block`, the one parser the other scripts use. A
report finding counts when its status is open, refused-rejected or absent.

Exit: 0 = ok / scored · 1 = validate found a problem, the judges disagree on a finding, or
--min-recall was missed · 2 = an input is missing, unreadable or malformed (nothing is scored on a
guess), or a bad flag.

Every string read from a case, a report or a judge file is data: it is checked against fixed rules,
never executed, and printed only through safe().
"""
import argparse, datetime, hashlib, json, math, os, re, subprocess, sys, unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
CASES = os.path.join(HERE, "cases")
REVIEW_CYCLE = os.path.join(ROOT, ".agents", "skills", "pr-reviewer", "scripts", "review-cycle.sh")

SEVERITIES = ("CRITICAL", "WARNING", "NOTE")
COUNTED = ("", "open", "refused-rejected")
CASE_KEYS = {"schema", "repo", "pr", "base", "head", "pass", "expected", "validated_by", "validated_at",
             "validated_digest"}
EXP_KEYS = {"id", "source_id", "file", "lines", "dimension", "severity", "description"}
JUDGE_KEYS = {"schema", "case", "pr", "head", "judge", "matches"}
MATCH_KEYS = {"expected", "matched", "reason"}
NAME = re.compile(r"[a-z0-9][a-z0-9-]{0,63}", re.ASCII)
LOGIN = re.compile(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?", re.ASCII)
SHA = re.compile(r"[0-9a-f]{40}", re.ASCII)
REPO = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", re.ASCII)
DIM = re.compile(r"[a-z0-9][a-z0-9_-]{0,39}", re.ASCII)
FID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,31}", re.ASCII)
TEXT_MAX = 300


class Bad(Exception):
    pass


def safe(s, limit=200):
    """Text for the terminal: no control or format characters, bounded."""
    s = "".join(ch if ch.isprintable() and unicodedata.category(ch) != "Cf" else "?" for ch in str(s))
    return s[:limit]


def one_line(v):
    """A non-empty single line of at most TEXT_MAX printable characters."""
    return (isinstance(v, str) and v.strip() != "" and len(v) <= TEXT_MAX
            and all(ch.isprintable() and unicodedata.category(ch) != "Cf" for ch in v))


def load_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except OSError as e:
        raise Bad("cannot read %s (%s)" % (safe(path), e.strerror))
    except ValueError:
        raise Bad("%s is not valid JSON" % safe(path))


def digest(case):
    """What a person validated: everything but the validation fields."""
    core = {k: case.get(k) for k in ("schema", "repo", "pr", "base", "head", "pass", "expected")}
    return hashlib.sha256(json.dumps(core, sort_keys=True, ensure_ascii=True).encode()).hexdigest()


def check_case(name, c):
    """The problems of one case, as a list of strings (empty = well formed)."""
    p = []
    if not NAME.fullmatch(name):
        p.append("the file name must be lowercase letters, digits and dashes")
    if not isinstance(c, dict):
        return p + ["the case is not a JSON object"]
    extra, missing = set(c) - CASE_KEYS, CASE_KEYS - set(c)
    if extra:
        p.append("unknown key(s) %s (a draft from build-cases.py is not a case)" % ", ".join(sorted(safe(k, 40) for k in extra)))
    if missing:
        p.append("missing key(s) %s" % ", ".join(sorted(missing)))
    if c.get("schema") != 1:
        p.append("schema must be 1")
    if not (isinstance(c.get("repo"), str) and REPO.fullmatch(c["repo"])):
        p.append("repo must be OWNER/NAME")
    for k in ("pr", "pass"):
        if not (type(c.get(k)) is int and c[k] >= 1):
            p.append("%s must be a positive integer" % k)
    for k in ("base", "head"):
        if not (isinstance(c.get(k), str) and SHA.fullmatch(c[k])):
            p.append("%s must be a full 40-digit lowercase commit sha" % k)
    exp = c.get("expected")
    if not isinstance(exp, list) or not exp:
        p.append("expected must be a non-empty list")
        exp = []
    ids = []
    for i, e in enumerate(exp):
        w = "expected[%d]" % i
        if not isinstance(e, dict):
            p.append("%s is not an object" % w)
            continue
        if set(e) != EXP_KEYS:
            p.append("%s must have exactly the keys %s" % (w, ", ".join(sorted(EXP_KEYS))))
        fid = e.get("id")
        if not (isinstance(fid, str) and re.fullmatch(r"E[1-9][0-9]{0,2}", fid)):
            p.append("%s: id must be E1, E2, ..." % w)
        else:
            ids.append(fid)
        if not (isinstance(e.get("source_id"), str) and FID.fullmatch(e["source_id"])):
            p.append("%s: source_id must be the verdict's finding id" % w)
        f = e.get("file")
        if not (isinstance(f, str) and one_line(f) and not f.startswith("/") and ".." not in f.split("/")
                and " " not in f):
            p.append("%s: file must be a repository-relative path" % w)
        ln = e.get("lines")
        if not (isinstance(ln, list) and len(ln) == 2 and all(type(x) is int for x in ln) and 1 <= ln[0] <= ln[1]):
            p.append("%s: lines must be [start, end] with 1 <= start <= end" % w)
        if not (isinstance(e.get("dimension"), str) and DIM.fullmatch(e["dimension"])):
            p.append("%s: dimension must be a lowercase word" % w)
        if e.get("severity") not in SEVERITIES:
            p.append("%s: severity must be CRITICAL, WARNING or NOTE" % w)
        if not one_line(e.get("description")):
            p.append("%s: description must be one printable line of 1 to %d characters" % (w, TEXT_MAX))
    if len(ids) != len(set(ids)):
        p.append("expected ids repeat")
    by, at, dg = c.get("validated_by"), c.get("validated_at"), c.get("validated_digest")
    if by == "none":
        if at is not None or dg is not None:
            p.append("an unvalidated case has validated_at and validated_digest null")
    elif isinstance(by, str) and LOGIN.fullmatch(by):
        if not (isinstance(at, str) and re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", at, re.ASCII)):
            p.append("validated_at must be YYYY-MM-DD")
        if dg != digest(c):
            p.append("the case changed after %s validated it (validated_digest differs); review it again "
                     "and run mark-validated, or set validated_by back to none" % safe(by, 40))
    else:
        p.append("validated_by must be none or a GitHub login")
    return p


def case_files(d):
    try:
        names = sorted(f[:-5] for f in os.listdir(d) if f.endswith(".json"))
    except OSError as e:
        raise Bad("cannot list %s (%s)" % (safe(d), e.strerror))
    return names


def load_cases(d):
    """Every case, validated; Bad on the first problem."""
    out = {}
    names = case_files(d)
    if not names:
        raise Bad("no case in %s" % safe(d))
    for n in names:
        c = load_json(os.path.join(d, n + ".json"))
        probs = check_case(n, c)
        if probs:
            raise Bad("case %s: %s" % (safe(n), safe(probs[0], 400)))
        out[n] = c
    return out


def validated(c):
    return c["validated_by"] != "none"


# ---- validate / mark-validated ------------------------------------------------------------------
def cmd_validate(a):
    names, bad = case_files(a.cases), 0
    for n in names:
        try:
            probs = check_case(n, load_json(os.path.join(a.cases, n + ".json")))
        except Bad as e:
            probs = [str(e)]
        for pr in probs:
            bad += 1
            print("golden: %s: %s" % (safe(n), safe(pr, 400)))
    vcount = 0
    for n in names:
        try:
            c = load_json(os.path.join(a.cases, n + ".json"))
            vcount += isinstance(c, dict) and c.get("validated_by") not in (None, "none")
        except Bad:
            pass
    print("golden: %d case(s), %d validated by a person, %s" % (len(names), vcount,
          "ok" if not bad else "%d problem(s)" % bad))
    return 1 if bad or not names else 0


def cmd_mark(a):
    if not LOGIN.fullmatch(a.login or ""):
        raise Bad("--login must be a GitHub login")
    if not NAME.fullmatch(a.case):
        raise Bad("the case name must be lowercase letters, digits and dashes")
    date = a.date or datetime.datetime.now(datetime.timezone.utc).date().isoformat()
    try:
        datetime.date.fromisoformat(date)
    except ValueError:
        raise Bad("--date must be YYYY-MM-DD")
    path = os.path.join(a.cases, a.case + ".json")
    c = load_json(path)
    c2 = dict(c) if isinstance(c, dict) else c
    if isinstance(c2, dict):
        c2.update(validated_by="none", validated_at=None, validated_digest=None)
    probs = check_case(a.case, c2)
    if probs:
        raise Bad("case %s is not well formed, so it cannot be validated: %s" % (safe(a.case), safe(probs[0], 400)))
    c2.update(validated_by=a.login, validated_at=date)
    c2["validated_digest"] = digest(c2)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(c2, f, indent=2, ensure_ascii=True)
        f.write("\n")
    os.replace(tmp, path)
    print("golden: %s validated by %s on %s" % (safe(a.case), safe(a.login), date))
    return 0


# ---- run layout ---------------------------------------------------------------------------------
def token(case):
    return "r" + hashlib.sha256(("golden:" + case).encode()).hexdigest()[:10]


def load_map(run, cases):
    m = load_json(os.path.join(run, "map.json"))
    if not (isinstance(m, dict) and set(m) == {"schema", "cases"} and m["schema"] == 1 and isinstance(m["cases"], dict)):
        raise Bad("map.json must be {\"schema\": 1, \"cases\": {case: token}}")
    for n in cases:
        t = m["cases"].get(n)
        if not (isinstance(t, str) and re.fullmatch(r"r[0-9a-f]{10}", t, re.ASCII)):
            raise Bad("map.json has no token for case %s (run prepare again)" % safe(n))
    return m["cases"]


def hunks(diff):
    """{new-file path: [(first, last)]} of a unified diff's new-file hunks."""
    out, cur = {}, None
    for ln in diff.decode("utf-8", "replace").splitlines():
        if ln.startswith("+++ "):
            p = ln[4:].strip()
            cur = None if p == "/dev/null" else (p[2:] if p.startswith("b/") else p)
            if cur:
                out.setdefault(cur, [])
        elif ln.startswith("@@") and cur:
            m = re.match(r"@@ -[0-9]+(?:,[0-9]+)? \+([0-9]+)(?:,([0-9]+))? @@", ln)
            if m:
                s, k = int(m.group(1)), int(m.group(2) if m.group(2) is not None else 1)
                out[cur].append((s, s + max(k, 1) - 1))
    return out


def outside(case, rng):
    """The expected findings whose lines touch no new-file hunk of the case's diff."""
    return [e for e in case["expected"]
            if not any(s <= e["lines"][1] and e["lines"][0] <= f for s, f in rng.get(e["file"], []))]


def cmd_prepare(a):
    cases = load_cases(a.cases)
    os.makedirs(os.path.join(a.run, "inputs"), exist_ok=True)
    for d in ("reports", "judge-a", "judge-b"):
        os.makedirs(os.path.join(a.run, d), exist_ok=True)
    m = {}
    for n, c in cases.items():
        for sha in (c["base"], c["head"]):
            if subprocess.run(("git", "-C", ROOT, "cat-file", "-e", sha + "^{commit}"),
                              capture_output=True).returncode != 0:
                subprocess.run(("git", "-C", ROOT, "fetch", "--quiet", "origin", sha), capture_output=True)
        r = subprocess.run(("git", "-C", ROOT, "diff", "--no-ext-diff", "--no-textconv", c["base"], c["head"]),
                           capture_output=True)
        if r.returncode != 0 or not r.stdout:
            raise Bad("case %s: git cannot diff %s..%s" % (safe(n), c["base"][:12], c["head"][:12]))
        for e in outside(c, hunks(r.stdout)):
            raise Bad("case %s: %s %s:%d-%d is not inside a hunk of %s..%s" % (
                safe(n), e["id"], safe(e["file"]), e["lines"][0], e["lines"][1], c["base"][:12], c["head"][:12]))
        t = token(n)
        with open(os.path.join(a.run, "inputs", t + ".patch"), "wb") as f:
            f.write(r.stdout)
        m[n] = t
    with open(os.path.join(a.run, "map.json"), "w", encoding="utf-8") as f:
        json.dump({"schema": 1, "cases": m}, f, indent=2, sort_keys=True)
        f.write("\n")
    print("golden: %d input(s) in %s" % (len(m), safe(os.path.join(a.run, "inputs"))))
    return 0


def sample(cases, seed):
    """The second judge's cases: max(3, ceil(20%)), at most all, chosen by a hash of the seed."""
    names = sorted(cases)
    k = min(len(names), max(3, math.ceil(0.2 * len(names))))
    return sorted(sorted(names, key=lambda n: hashlib.sha256((seed + "\0" + n).encode()).hexdigest())[:k])


def seed_of(run):
    return os.path.basename(os.path.normpath(os.path.abspath(run)))


def cmd_sample(a):
    cases = load_cases(a.cases)
    for n in sample(cases, seed_of(a.run)):
        print(n)
    return 0


# ---- reports and judges -------------------------------------------------------------------------
def report_findings(path):
    """{id: {severity, file, line}} of the counted findings, via review-cycle.sh findings-block."""
    if not os.path.isfile(path):
        raise Bad("missing report %s" % safe(path))
    try:
        r = subprocess.run(("bash", REVIEW_CYCLE, "findings-block", "--report", path), capture_output=True,
                           text=True, stdin=subprocess.DEVNULL, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        raise Bad("cannot run review-cycle.sh findings-block")
    if r.returncode != 0:
        raise Bad("%s has no readable findings block (review-cycle.sh findings-block refused it)" % safe(path))
    try:
        blk = json.loads(r.stdout)
    except ValueError:
        raise Bad("review-cycle.sh findings-block printed no JSON for %s" % safe(path))
    out = {}
    for e in blk.get("entries") or []:
        fid = str(e.get("id") or "")
        if str(e.get("status") or "") not in COUNTED:
            continue
        if not FID.fullmatch(fid) or fid in out:
            raise Bad("%s: finding id %r is malformed or repeated" % (safe(path), safe(fid, 40)))
        out[fid] = {"severity": str(e.get("severity") or "").upper()}
    return out


def check_judge(path, name, case, which, findings):
    """The judge's {expected id: matched id or None}; Bad when the file breaks a rule."""
    j = load_json(path)
    w = "%s judge-%s" % (safe(name), which)
    if not isinstance(j, dict) or set(j) != JUDGE_KEYS:
        raise Bad("%s: must be an object with exactly the keys %s" % (w, ", ".join(sorted(JUDGE_KEYS))))
    if j["schema"] != 1:
        raise Bad("%s: schema must be 1" % w)
    if j["case"] != name or j["pr"] != case["pr"] or j["head"] != case["head"]:
        raise Bad("%s: case, pr and head must be the case's own (%s, %d, %s)" % (w, safe(name), case["pr"], case["head"]))
    if j["judge"] != which:
        raise Bad("%s: judge must be %r" % (w, which))
    ms = j["matches"]
    if not isinstance(ms, list):
        raise Bad("%s: matches must be a list" % w)
    want = [e["id"] for e in case["expected"]]
    got, used = {}, {}
    for i, m in enumerate(ms):
        if not isinstance(m, dict) or set(m) != MATCH_KEYS:
            raise Bad("%s: matches[%d] must have exactly the keys expected, matched, reason" % (w, i))
        eid, mid = m["expected"], m["matched"]
        if not isinstance(eid, str) or eid not in want:
            raise Bad("%s: matches[%d] names expected id %r, which the case does not have" % (w, i, safe(eid, 40)))
        if eid in got:
            raise Bad("%s: expected id %s is judged twice" % (w, eid))
        if not isinstance(mid, str):
            raise Bad("%s: %s: matched must be a report finding id or \"none\"" % (w, eid))
        if mid != "none":
            if mid not in findings:
                raise Bad("%s: %s: matched %r is not a counted finding of the report" % (w, eid, safe(mid, 40)))
            if mid in used:
                raise Bad("%s: report finding %s is matched to both %s and %s; match it once" % (w, safe(mid, 40), used[mid], eid))
            used[mid] = eid
        if not one_line(m["reason"]):
            raise Bad("%s: %s: reason must be one printable line of 1 to %d characters" % (w, eid, TEXT_MAX))
        got[eid] = None if mid == "none" else mid
    missing = [x for x in want if x not in got]
    if missing:
        raise Bad("%s: expected id(s) %s are not judged" % (w, ", ".join(missing)))
    return got


def ratio(a, b):
    return round(a / b, 3) if b else None


def cmd_score(a):
    cases = load_cases(a.cases)
    tokens = load_map(a.run, cases)
    picked = sample(cases, seed_of(a.run))
    groups = {"validated": {}, "unvalidated": {}}
    rows, disagreements, compared, agreed = [], [], 0, 0
    unmatched = {"CRITICAL": 0, "WARNING": 0, "NOTE": 0, "other": 0}
    downgraded = 0
    for n, c in cases.items():
        findings = report_findings(os.path.join(a.run, "reports", tokens[n] + ".md"))
        pa = os.path.join(a.run, "judge-a", n + ".json")
        if not os.path.isfile(pa):
            raise Bad("case %s has no primary judge file judge-a/%s.json" % (safe(n), safe(n)))
        ja = check_judge(pa, n, c, "a", findings)
        pb = os.path.join(a.run, "judge-b", n + ".json")
        if os.path.isfile(pb):
            jb = check_judge(pb, n, c, "b", findings)
            for eid in ja:
                compared += 1
                if ja[eid] == jb[eid]:
                    agreed += 1
                else:
                    disagreements.append({"case": n, "expected": eid, "judge_a": ja[eid] or "none",
                                          "judge_b": jb[eid] or "none"})
        elif n in picked:
            raise Bad("case %s is in the second judge's sample and has no judge-b/%s.json" % (safe(n), safe(n)))
        g = groups["validated" if validated(c) else "unvalidated"]
        hit = 0
        for e in c["expected"]:
            m = ja[e["id"]]
            for key in ("all", "severity:" + e["severity"], "dimension:" + e["dimension"]):
                t = g.setdefault(key, [0, 0])
                t[1] += 1
                t[0] += m is not None
            if m is not None:
                hit += 1
                got = findings[m]["severity"]
                if got not in SEVERITIES or SEVERITIES.index(got) > SEVERITIES.index(e["severity"]):
                    downgraded += 1
        matched_ids = {v for v in ja.values() if v}
        um = 0
        for fid, f in findings.items():
            if fid not in matched_ids:
                um += 1
                unmatched[f["severity"] if f["severity"] in SEVERITIES else "other"] += 1
        rows.append({"case": n, "validated": validated(c), "expected": len(c["expected"]), "matched": hit,
                     "report_findings": len(findings), "unmatched": um})
    res = {"cases": rows, "sample": picked, "downgraded": downgraded, "unmatched": unmatched,
           "agreement": {"compared": compared, "agreed": agreed, "rate": ratio(agreed, compared),
                         "disagreements": disagreements}}
    for gname, g in groups.items():
        res[gname] = {k: {"matched": v[0], "expected": v[1], "recall": ratio(v[0], v[1])} for k, v in sorted(g.items())}
    overall_v = res["validated"].get("all", {}).get("recall")
    overall_u = res["unvalidated"].get("all", {}).get("recall")
    if a.json:
        print(json.dumps(res, indent=2, sort_keys=True))
    else:
        print("%-24s %-11s %9s %8s %9s" % ("case", "validated", "matched", "report", "unmatched"))
        for r in rows:
            print("%-24s %-11s %4d/%-4d %8d %9d" % (safe(r["case"], 24), "yes" if r["validated"] else "no (cand.)",
                                                    r["matched"], r["expected"], r["report_findings"], r["unmatched"]))
        for gname in ("validated", "unvalidated"):
            g = res[gname]
            if not g:
                print("%s: no case" % gname)
                continue
            print("%s recall %s (%d/%d)%s" % (gname, g["all"]["recall"], g["all"]["matched"], g["all"]["expected"],
                  "  CANDIDATES ONLY: no person has checked these expected findings" if gname == "unvalidated" else ""))
            for k, v in g.items():
                if k != "all":
                    print("  %-28s %s (%d/%d)" % (safe(k, 28), v["recall"], v["matched"], v["expected"]))
        print("unmatched report findings (not judged wrong; the set holds only verified findings): "
              "%d CRITICAL, %d WARNING, %d NOTE" % (unmatched["CRITICAL"], unmatched["WARNING"], unmatched["NOTE"]))
        print("matched at a lower severity than expected: %d" % downgraded)
        ag = res["agreement"]
        print("judge agreement: %s (%d/%d expected findings in %d sampled case(s))" % (
            ag["rate"], ag["agreed"], ag["compared"], len(picked)))
        for d in disagreements:
            print("DISAGREEMENT %s %s: judge-a %s, judge-b %s" % (safe(d["case"]), d["expected"],
                                                                  safe(d["judge_a"], 40), safe(d["judge_b"], 40)))
    bad = bool(disagreements)
    if a.min_recall is not None:
        bad = bad or overall_v is None or overall_v < a.min_recall
    return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    v = sub.add_parser("validate")
    m = sub.add_parser("mark-validated")
    m.add_argument("case")
    m.add_argument("--login", required=True)
    m.add_argument("--date")
    pr = sub.add_parser("prepare")
    sa = sub.add_parser("sample")
    sc = sub.add_parser("score")
    for p in (pr, sa, sc):
        p.add_argument("--run", required=True)
    sc.add_argument("--min-recall", type=float)
    sc.add_argument("--json", action="store_true")
    for p in (v, m, pr, sa, sc):
        p.add_argument("--cases", default=CASES)
    a = ap.parse_args()
    a.cases = os.path.abspath(a.cases)
    try:
        return {"validate": cmd_validate, "mark-validated": cmd_mark, "prepare": cmd_prepare,
                "sample": cmd_sample, "score": cmd_score}[a.cmd](a)
    except Bad as e:
        print("golden: " + str(e), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
