#!/usr/bin/env python3
"""build-cases.py: draft golden-set cases from merged pull requests. Read-only on GitHub, no model.

Usage:
  REVIEW_MARKER_AUTHORS=<login>[,<login>...] \\
  build-cases.py --prs 60-94[,97,...] --out DIR [--repo OWNER/NAME]

For each pull request it reads the comments through the reviewer's pr-json.py (an edited comment is
never read) and keeps only verdict and closure markers written by a login on REVIEW_MARKER_AUTHORS
(the gate's own `MARKER`, `allowlist` and `marker_author_allowed`, imported from
gate-pr-review-state.py). A pull request is skipped, and named, when it is not merged, when it has no
trusted verdict, or when a trusted marker comment was edited or a trusted comment was edited or
deleted by someone else (review-metrics.sh scorecard leaves the same ones out).

A candidate expected finding is one the FIRST trusted pass raised, at severity CRITICAL or WARNING
or NOTE, that a later trusted pass marked `verified`, with a trusted fixer closure for a cycle in
between: a fixer closed it and the reviewer confirmed the fix. Findings raised at a later pass are
left out, because the case is pinned to the first pass's head (`sha=` of that marker) and its base:
the merge base of that head with the base branch as it stood when that verdict was posted (the
newest first-parent commit of origin/<base branch> not after the verdict, fetched into the local
clone it must be run in; when the base branch no longer exists, its tip at merge time). It fetches
that branch and any missing commit by sha; it pushes nothing. A pull request whose base..head does
not hold exactly its own commits up to the first-pass head (GitHub's list) is refused, so a stale or
wrong base never reaches a draft. golden.py prepare refuses a case whose expected lines are not
inside its base..head diff.

Ids are compared, not trusted: an id verified later at another file or dimension than the first pass
gave it is left out and named (`draft_dropped_ids`).

Each findings block is read through `review-cycle.sh findings-block`, the one parser the other
scripts use, and every field of an entry (id, severity, status, file, line, dimension, claim) is
taken from what it prints.

Output: one draft per pull request with at least one candidate, DIR/pr-<n>.draft.json. A draft
carries the reviewer's claim (`draft_claim`) so the person or agent finishing it can write the
one-sentence `description` from the claim and the fix diff; golden.py validate refuses a draft (an
unknown key, an empty description), so a draft is never scored by mistake. Nothing is written to
the repository, and nothing on GitHub is changed. Text read from GitHub is data: it is parsed by the
fixed marker and block rules, written into JSON (escaped), and printed only through safe().

Exit 0 = every listed pull request was read · 2 = a refusal (no allowlist, bad flag, a base that
fails the commit check) or gh could not read one (the others are still written).
"""
import argparse, datetime, importlib.util, json, os, re, subprocess, sys, tempfile, unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.normpath(os.path.join(HERE, "..", "..", ".agents", "skills", "pr-reviewer", "scripts"))
# The closure marker, anchored at the start of the comment. The opener is written in two pieces so
# this file holds no literal comment opener.
CLOSURE = re.compile(r"\A<" r"!-- pr-fixer-closure: cycle=([0-9]+) head=([0-9a-f]{7,40}) "
                     r"closed=([0-9]+) refused=([0-9]+) debt=([0-9]+) -->", re.ASCII)


def safe(s, limit=200):
    s = "".join(ch if ch.isprintable() and unicodedata.category(ch) != "Cf" else "?" for ch in str(s))
    return s[:limit]


def die(msg, code=2):
    print("build-cases: " + msg, file=sys.stderr)
    sys.exit(code)


def run(cmd, timeout=120):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return 127, ""
    return r.returncode, r.stdout


def load_gate():
    path = os.path.join(SCRIPTS, "gate-pr-review-state.py")
    try:
        spec = importlib.util.spec_from_file_location("gate_pr_review_state", path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
    except Exception as e:
        die("cannot load the trust rules from %s (%s)" % (path, type(e).__name__))
    for a in ("MARKER", "allowlist", "marker_author_allowed"):
        if not hasattr(mod, a):
            die("cannot load the trust rules from %s (no %s)" % (path, a))
    return mod


def entries_of(body):
    fd, tmp = tempfile.mkstemp(prefix="golden-", suffix=".md")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(body)
        rc, out = run(("bash", os.path.join(SCRIPTS, "review-cycle.sh"), "findings-block", "--report", tmp))
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass
    try:
        blk = json.loads(out) if rc == 0 else None
    except ValueError:
        blk = None
    if not isinstance(blk, dict):
        return None
    ents = blk.get("entries") or []
    return ents if isinstance(ents, list) and all(isinstance(e, dict) for e in ents) else None


def line_range(v):
    m = re.fullmatch(r"\s*([0-9]+)\s*(?:[-–]\s*([0-9]+))?\s*", str(v or ""))
    if not m:
        return None
    a = int(m.group(1))
    b = int(m.group(2)) if m.group(2) else a
    return [a, b] if 1 <= a <= b else None


def prs_arg(v):
    out = []
    for part in v.split(","):
        m = re.fullmatch(r"([0-9]+)(?:-([0-9]+))?", part.strip())
        if not m:
            die("--prs takes numbers and ranges such as 60-94,97 (not %r)" % safe(part))
        a, b = int(m.group(1)), int(m.group(2) or m.group(1))
        if b < a or b - a > 500:
            die("--prs range %s is backwards or too long" % safe(part))
        out.extend(range(a, b + 1))
    return sorted(set(out))


def select(pr, gate):
    """((first pass, verdicts, candidates, dropped ids), None), or ({}, why the pull request is
    skipped). It reads only the object pr-json.py printed, and review-cycle.sh findings-block."""
    if str(pr.get("state") or "").upper() != "MERGED":
        return {}, "not merged"
    verdicts, closures = {}, {}
    for c in pr.get("comments") or []:
        body = str(c.get("body") or "")
        vm, cm = gate.MARKER.match(body), CLOSURE.match(body)
        if not (vm or cm) or not gate.marker_author_allowed(c):
            continue
        if vm:
            verdicts[int(vm.group(3))] = {"sha": vm.group(1).lower(), "body": body,
                                          "at": str(c.get("createdAt") or "")}
        if cm:
            closures[int(cm.group(1))] = cm.group(2).lower()

    def login(x, k):
        return str(((x or {}).get(k) or {}).get("login") or "").lower()
    if [c for c in pr.get("editedComments") or [] if gate.marker_author_allowed(c)
            and (gate.MARKER.match(str(c.get("body") or "")) or CLOSURE.match(str(c.get("body") or ""))
                 or login(c, "editor") != login(c, "author"))]:
        return {}, "a trusted marker comment was edited, or a trusted comment was edited by someone else"
    if [c for c in pr.get("deletedComments") or [] if gate.marker_author_allowed(c)
            and login(c, "actor") != login(c, "author")]:
        return {}, "a trusted comment was deleted by someone other than its author"
    if not verdicts:
        return {}, "no trusted verdict"
    passes = sorted(verdicts)
    first = passes[0]
    listed = {}
    for p in passes:
        ents = entries_of(verdicts[p]["body"])
        if ents is None:
            return {}, "pass %d: the findings block could not be read" % p
        for e in ents:
            if e.get("id"):
                listed.setdefault(e["id"], {})[p] = e
    cands, dropped = [], []
    for fid, hist in listed.items():
        if first not in hist:
            continue
        raised = hist[first]
        later = [p for p in hist if p > first and str(hist[p].get("status") or "") == "verified"]
        between = sorted(c for c in closures if first <= c < min(later)) if later else []
        if not between:
            continue
        # Ids are compared, not trusted: the entry verified later must name the same file and dimension
        # as the one raised at the first pass, or the id was reused for another finding.
        ver = hist[min(later)]
        if (str(ver.get("file") or "") != str(raised.get("file") or "")
                or str(ver.get("dimension") or "").lower() != str(raised.get("dimension") or "").lower()):
            dropped.append(fid)
            continue
        rng = line_range(raised.get("line"))
        sev = str(raised.get("severity") or "").upper()
        if not rng or sev not in ("CRITICAL", "WARNING", "NOTE") or not raised.get("file"):
            continue
        path = str(raised["file"])
        cands.append({"source_id": fid, "file": path[2:] if path.startswith("./") else path,
                      "lines": rng, "dimension": str(raised.get("dimension") or "none").strip().lower(),
                      "severity": sev, "draft_claim": str(raised.get("claim") or ""),
                      "draft_verified_claim": str(ver.get("claim") or ""),
                      "draft_verified_at_pass": min(later), "draft_fix_head": closures[between[-1]]})
    if not cands:
        return {}, "no first-pass finding verified after a fixer closure" + (
            " (id(s) %s verified at another file or dimension, left out)" % ", ".join(dropped) if dropped else "")
    return (first, verdicts, cands, dropped), None


def base_of(root, branch, oid, head, at, pr_oids):
    """(the first pass's base, None), or (None, why). The base branch's first-parent history: the
    merge commits land there at merge time, so the newest one not after the verdict is the branch as
    the first pass saw it. A gone branch (a deleted release branch) falls back to its tip at merge
    time (`oid`).

    The local origin/<branch> ref is fetched first and read only when that fetch worked: a stale ref
    gives an older base and a wider diff. The result is then checked: base..head must hold exactly
    the pull request's own commits (`pr_oids`, from GitHub) that the first-pass head reaches."""
    rc4, tip = run(("git", "-C", root, "fetch", "--quiet", "origin",
                    "+refs/heads/%s:refs/remotes/origin/%s" % (branch, branch)))
    if rc4 == 0:
        rc4, tip = run(("git", "-C", root, "rev-list", "-1", "--first-parent", "--before=" + at,
                        "refs/remotes/origin/" + branch, "--"))
    tip = tip.strip() if rc4 == 0 and re.fullmatch(r"[0-9a-f]{40}", tip.strip()) else oid
    rc3, mb = run(("git", "-C", root, "merge-base", tip, head))
    base = mb.strip()
    if rc3 or not re.fullmatch(r"[0-9a-f]{40}", base):
        return None, "git could not resolve the first-pass head's base"
    if head not in pr_oids:
        return None, "the first-pass head %s is not among the pull request's commits" % head[:12]
    rc5, reach = run(("git", "-C", root, "rev-list", head, "--"))
    rc6, span = run(("git", "-C", root, "rev-list", "--count", base + ".." + head, "--"))
    if rc5 or rc6 or not span.strip().isdigit():
        return None, "git could not count base..head"
    want = len(set(pr_oids) & set(reach.split()))
    if int(span) != want:
        return None, ("base %s gives %d commit(s) in base..head, but the pull request has %d up to the "
                      "first-pass head: the base is stale or wrong" % (base[:12], int(span), want))
    return base, None


def build(n, repo, gate):
    rc, out = run((sys.executable, "-I", os.path.join(SCRIPTS, "pr-json.py"), str(n)))
    try:
        pr = json.loads(out) if rc == 0 else None
    except ValueError:
        pr = None
    if not isinstance(pr, dict):
        return None, "gh could not read it"
    sel, why = select(pr, gate)
    if not sel:
        return {}, why
    first, verdicts, cands, dropped = sel
    rc, full = run(("gh", "api", "repos/%s/commits/%s" % (repo, verdicts[first]["sha"]), "--jq", ".sha"))
    head = full.strip()
    # The base is what the first pass saw: the merge base of its head with the base branch as it was
    # when that verdict was posted (the newest base-branch commit not after the comment's time). The
    # base branch's tip at merge time is wrong for a pull request whose changes reached the base by
    # another route before it merged.
    at = verdicts[first]["at"]
    rc2, view = run(("gh", "pr", "view", str(n), "-R", repo, "--json", "baseRefName,baseRefOid",
                     "--jq", ".baseRefName + \" \" + .baseRefOid"))
    branch, _, oid = view.strip().partition(" ")
    if rc2 or not re.fullmatch(r"[A-Za-z0-9._/-]+", branch) or not re.fullmatch(r"[0-9TZ:.+-]+", at):
        return None, "gh could not read the base branch or the verdict's time"
    root = os.path.normpath(os.path.join(HERE, "..", ".."))
    if rc or not re.fullmatch(r"[0-9a-f]{40}", head):
        return None, "gh could not resolve the first-pass head"
    for sha in (head, oid):
        if re.fullmatch(r"[0-9a-f]{40}", sha) and run(("git", "-C", root, "cat-file", "-e", sha + "^{commit}"))[0]:
            run(("git", "-C", root, "fetch", "--quiet", "origin", sha))
    # The pull request's own commits, for the base check. The REST list stops at 250 commits, so a
    # list that long may be cut short and is refused.
    rc5, oids = run(("gh", "api", "--paginate", "repos/%s/pulls/%d/commits" % (repo, n), "--jq", ".[].sha"))
    pr_oids = oids.split() if rc5 == 0 else []
    if not pr_oids or len(pr_oids) >= 250 or not all(re.fullmatch(r"[0-9a-f]{40}", x) for x in pr_oids):
        return None, "gh could not list the pull request's commits (or it has 250 or more)"
    base, why = base_of(root, branch, oid, head, at, pr_oids)
    if base is None:
        return None, why
    cands.sort(key=lambda x: (x["file"], x["lines"][0], x["source_id"]))
    for i, c in enumerate(cands, 1):
        c["id"] = "E%d" % i
        c["description"] = ""
    return {"schema": 1, "repo": repo, "pr": n, "base": base, "head": head, "pass": first,
            "draft_dropped_ids": dropped, "expected": cands, "validated_by": "none", "validated_at": None, "validated_digest": None,
            "draft_built_at": datetime.date.today().isoformat()}, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--prs", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--repo", default="jonyfs/pr-reviewer-fixer")
    a = ap.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", a.repo):
        die("--repo must be OWNER/NAME")
    gate = load_gate()
    if not gate.allowlist():
        die("REVIEW_MARKER_AUTHORS is unset or holds no login; nobody's markers can be trusted")
    os.environ["GH_REPO"] = a.repo
    os.makedirs(a.out, exist_ok=True)
    bad = 0
    for n in prs_arg(a.prs):
        case, why = build(n, a.repo, gate)
        if case is None:
            bad = 1
            print("build-cases: #%d: %s" % (n, safe(why)), file=sys.stderr)
        elif not case:
            print("build-cases: #%d skipped: %s" % (n, safe(why)))
        else:
            p = os.path.join(a.out, "pr-%d.draft.json" % n)
            with open(p, "w", encoding="utf-8") as f:
                json.dump(case, f, indent=2, ensure_ascii=True)
                f.write("\n")
            print("build-cases: #%d: %d candidate(s) -> %s" % (n, len(case["expected"]), safe(p)))
    return 2 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
