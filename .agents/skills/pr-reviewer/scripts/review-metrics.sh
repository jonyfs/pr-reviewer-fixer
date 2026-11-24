#!/usr/bin/env bash
#
# review-metrics.sh: how stable and how useful the reviewer's findings are, with no server and no model.
#
# Usage:
#   review-metrics.sh agreement [--min X] [--json] [--out FILE] <report> <report> [<report>...]
#   review-metrics.sh scorecard (--prs 21,25 | --since YYYY-MM-DD) [--limit N] [--min-accept X]
#                               [--min-blocking N] [--json] [--out FILE]
#
# AGREEMENT (self-agreement, catalog item 96). k >= 2 verdict reports of the same pull request and the
# same head, written by k fresh-context reviewers that did not see each other (the loop agent runs them;
# this script never calls a model, see references/review-metrics.md). Each report's findings block is
# read through `review-cycle.sh findings-block`, the one parser the other scripts use; the `pr:`,
# `head:`, `dimension:` and `claim:` fields it does not print are read from the same block by the same
# line rules, and a report whose ids differ between the two readings is refused. Only entries that
# count (status open, refused-rejected or none) are compared: a verified entry carried forward is not
# a finding of this review.
#
#   Fingerprint: sha256 of file, dimension and normalized claim; the line, the id and the severity are
#   left out. The file loses a leading `./`. The dimension is lowercased, and anything but
#   [a-z0-9_-] (or a missing one) reads as `other` / `none`. The claim is NFKC-normalized and
#   casefolded; line references (`line 47`, `lines 4-7`, `:47`, and `L47` right after `#`, `:`, `(`
#   or `[`, or as a range `L4-L7`) are removed; what is left is its runs of letters or digits and its
#   comparison operators (`<`, `<=`, `>`, `>=`, `==`, `!=`, `===`, `!==`), joined by one space. Nothing
#   fuzzier: two claims match only when they say the same words in the same order.
#   Overlap: Jaccard |A n B| / |A u B| of two reports' fingerprint sets, and 1.0 when both are empty.
#   Overall: the mean over every pair (`mean_pairwise`, the number --min is checked against), and the
#   share of the union found in all k reports (`all_k`). Per dimension: the mean pairwise Jaccard of
#   the fingerprints of that dimension, over the pairs where at least one report has one (a pair that
#   both left the dimension empty says nothing about it). A dimension, or the overall, below --min
#   (default 0.5) is unstable.
#   Exit 0 when nothing is unstable, 1 when something is, 2 for a refusal: fewer than two reports, a
#   report that cannot be read or has no findings block, a missing or different `pr:` or `head:`
#   (heads match when, of every two, one is a prefix of the other, 7 hex digits at least), a bad flag.
#
# SCORECARD (per-unit scorecard, catalog item 97). For each pull request (--prs, or the pull requests
# merged since --since, as fix-ledger.sh lists them), the trusted verdict markers and closure markers.
# A finding is an id; it is raised at the first trusted pass whose findings block has it, and is
# attributed to that entry's `dimension` (the lens) and that marker's `model`/`tier` (`unrecorded`
# when the marker has none). Its outcome is read from the newest trusted pass that lists it, in order:
#   verified   `verified` on a later pass, with a trusted fixer closure for a cycle in between
#   resolved   `verified` on a later pass with no trusted closure in between (someone else fixed it)
#   refused    `refused-accepted`: the fixer refused it and the reviewer accepted the refusal
#   fixed      a non-blocking finding only: `not-applicable` with a trusted closure between the pass
#              before its final not-applicable run and the first pass of that run; or open, then no
#              longer listed by the next pass, with a trusted closure between the two (the fixer fixed
#              it, the reviewer dropped it or marked it not-applicable). An upper bound: a NOTE the
#              fixer refused or declared debt that a later pass dropped or withdrew reads the same
#   withdrawn  `not-applicable` and not fixed; a blocking `not-applicable` is always withdrawn, since
#              the contract marks a fixed blocking finding verified (an upper bound: an owner's fix
#              outside a fixer cycle reads the same)
#   debt       still open when the pull request's newest trusted verdict is PASSED (declared debt)
#   open       still open (or refused-rejected) under a BLOCKED newest verdict
# Blocking: every CRITICAL, and a WARNING raised under a marker with `block_at=warning`. Accepted rate:
# blocking findings verified, fixed or resolved, over blocking (a valid finding someone fixed). A unit
# with at least --min-blocking (3) blocking findings and an accepted rate below --min-accept (0.5) is
# flagged `low_acceptance`, a candidate to retune or retire. Cost: the verdict marker has no cost
# field, so it is printed as "not recorded" and never estimated.
#
# TRUST. As fix-ledger.sh: pull requests are read through pr-json.py (an edited comment is never read),
# a marker counts only from a login on REVIEW_MARKER_AUTHORS (the gate's own `allowlist`,
# `marker_author_allowed` and `MARKER`, imported from gate-pr-review-state.py), and a pull request
# where a trusted comment holding a marker was edited, or a trusted comment was edited or deleted by
# someone else, is left out of every count and named. An unset or login-less list is exit 2 before
# any gh call. Report and comment text is data: only the fixed marker formats and the findings block
# are parsed, nothing read is executed, and no claim text is printed (a fingerprint is a short hash).
#
# OUTPUT. A table, or one JSON object with --json, to stdout or to --out FILE (written whole; nothing
# else is written). Read-only on GitHub. Scorecard exit codes: 0 when every pull request was read, 2
# for a refusal or when gh could not read one (the others are still counted and printed).
#
# Needs python3 3.9+; the scorecard also needs gh.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "review-metrics: python3 is not installed, INCONCLUSIVE" >&2; exit 2; }
RM_HERE="$HERE" exec python3 -I - "$@" <<'PY'
import collections, datetime, hashlib, importlib.util, itertools, json, os, re, subprocess, sys, tempfile, unicodedata

HERE = os.environ["RM_HERE"]
ARGS = sys.argv[1:]
# The closure marker, anchored at the start of the comment as protocol filter F3 reads it. The opener
# is written in two pieces so this file holds no literal comment opener.
CLOSURE = re.compile(r"\A<" r"!-- pr-fixer-closure: cycle=([0-9]+) head=([0-9a-f]{7,40}) "
                     r"closed=([0-9]+) refused=([0-9]+) debt=([0-9]+) -->", re.ASCII)
COUNTED = ("", "open", "refused-rejected")
COST = "not recorded"


def die(msg, code=2):
    print("review-metrics: " + msg, file=sys.stderr)
    sys.exit(code)


def run(cmd, timeout=120):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return 127, ""
    return r.returncode, r.stdout


def safe(s, limit=200):
    """A path or name for the terminal: no control or format characters, bounded. Every free-text
    field the table prints goes through it (a report's name, a finding's file, a unit); the others are
    numbers, hashes or regex-bound (dimension, model, tier), and the suite checks that none of them
    carries an ESC."""
    s = "".join(ch if ch.isprintable() and unicodedata.category(ch) != "Cf" else "?" for ch in str(s))
    return s[:limit]


def dimension(v):
    v = (v or "").strip().lower()
    if not v:
        return "none"
    return v if re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,39}", v, re.ASCII) else "other"


# ---- arguments ----------------------------------------------------------------------------------
def number(flag, v, lo=0.0, hi=1.0):
    try:
        x = float(v)
    except ValueError:
        x = None
    if x is None or not re.fullmatch(r"[0-9]+(\.[0-9]+)?", v, re.ASCII) or not lo <= x <= hi:
        die("%s takes a number from %g to %g" % (flag, lo, hi))
    return x


def parse_args(argv):
    if not argv or argv[0] not in ("agreement", "scorecard"):
        die("usage: review-metrics.sh agreement [--min X] [--json] [--out FILE] <report> <report>... | "
            "scorecard (--prs N,M | --since YYYY-MM-DD) [--limit N] [--min-accept X] [--min-blocking N] [--json] [--out FILE]")
    o = {"cmd": argv[0], "json": False, "out": None, "min": 0.5, "files": [], "prs": None, "since": None,
         "limit": 200, "min_accept": 0.5, "min_blocking": 3}
    flags = {"agreement": {"--min", "--json", "--out"},
             "scorecard": {"--prs", "--since", "--limit", "--min-accept", "--min-blocking", "--json", "--out"}}[o["cmd"]]
    rest, i = argv[1:], 0
    while i < len(rest):
        a = rest[i]
        if not a.startswith("--"):
            if o["cmd"] != "agreement":
                die("scorecard takes no file argument (%r)" % safe(a))
            o["files"].append(a)
            i += 1
            continue
        if a == "--":
            o["files"] += rest[i + 1:]
            break
        if a not in flags:
            die("%s does not take %r" % (o["cmd"], safe(a)))
        if a == "--json":
            o["json"] = True
            i += 1
            continue
        if i + 1 >= len(rest):
            die("%s needs a value" % a)
        v = rest[i + 1]
        i += 2
        if a == "--min":
            o["min"] = number(a, v)
        elif a == "--min-accept":
            o["min_accept"] = number(a, v)
        elif a in ("--min-blocking", "--limit"):
            if not re.fullmatch(r"[1-9][0-9]{0,5}", v, re.ASCII):
                die("%s takes a positive whole number" % a)
            o[a[2:].replace("-", "_")] = int(v)
        elif a == "--out":
            if not v:
                die("--out needs a file")
            o["out"] = v
        elif a == "--prs":
            if not re.fullmatch(r"[0-9]+(,[0-9]+)*", v, re.ASCII):
                die("--prs takes pull request numbers separated by commas, such as 21,25")
            o["prs"] = sorted({int(x) for x in v.split(",")})
        elif a == "--since":
            try:
                if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", v, re.ASCII):
                    raise ValueError
                datetime.date.fromisoformat(v)
            except ValueError:
                die("--since takes a date as YYYY-MM-DD")
            o["since"] = v
    if o["cmd"] == "scorecard" and (o["prs"] is None) == (o["since"] is None):
        die("scorecard takes exactly one of --prs 21,25 or --since YYYY-MM-DD")
    if o["cmd"] == "agreement" and len(o["files"]) < 2:
        die("agreement needs at least two reports of the same pull request and head (k >= 2)")
    return o


def emit(o, text):
    if o["out"]:
        try:
            with open(o["out"], "w", encoding="utf-8") as f:
                f.write(text)
        except OSError as e:
            die("cannot write %s (%s)" % (safe(o["out"]), e.strerror))
    else:
        sys.stdout.write(text)


# ---- the findings block -------------------------------------------------------------------------
def findings_block(path):
    """(rc, json) from review-cycle.sh findings-block: rc 0 with a block, 1 without, 2 unreadable."""
    rc, out = run(("bash", os.path.join(HERE, "review-cycle.sh"), "findings-block", "--report", path))
    if rc:
        return rc, None
    try:
        return 0, json.loads(out)
    except ValueError:
        return 2, None


def block_extras(text):
    """The fields findings-block does not print, read from the same block by the same line rules:
    top-level `pr:` and `head:`, and per entry (in order) `dimension:` and `claim:`."""
    lines = [ln[:-1] if ln.endswith("\r") else ln for ln in text.split("\n")]
    last = max((i for i, ln in enumerate(lines) if ln.strip(" \t")), default=None)
    first = next((i for i, ln in enumerate(lines) if ln == "```findings"), None)
    meta, entries, section, e = {}, [], None, None
    if last is None or first is None:
        return meta, entries
    for ln in lines[first + 1:last]:
        if re.match(r"\s*(#|$)", ln):
            continue
        top = re.match(r"([A-Za-z_][A-Za-z0-9_-]*):[ \t]*(.*?)[ \t]*$", ln)
        if top:
            section, e = top.group(1), None
            if section in ("pr", "head"):
                meta[section] = top.group(2).strip("\"'")
            continue
        if section == "findings":
            s = re.match(r"\s*-\s+id:\s*(\S+)", ln)
            if s:
                e = {"id": s.group(1).strip("\"'")}
                entries.append(e)
                continue
            kv = re.match(r"\s{2,}(dimension|claim):\s*(.*?)\s*$", ln)
            if kv and e is not None:
                e[kv.group(1)] = kv.group(2).strip("\"'")
    return meta, entries


def entries_of(body):
    """The entries of a comment's or file's findings block with dimension and claim, or None."""
    fd, tmp = tempfile.mkstemp(prefix="review-metrics-", suffix=".md")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(body)
        rc, blk = findings_block(tmp)
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass
    if rc or not isinstance(blk, dict):
        return None, None
    meta, extra = block_extras(body)
    base = blk.get("entries") or []
    if [x.get("id") for x in base] != [x.get("id") for x in extra]:
        return None, None
    for b, x in zip(base, extra):
        b["dimension"], b["claim"] = x.get("dimension"), x.get("claim")
    return meta, base


# ---- agreement ----------------------------------------------------------------------------------
# A line reference: `line 47`, `lines 4-7`, `:47`, and an L-number only where it clearly is one: right
# after `#`, `:`, `(` or `[` (`session.ts#L47`, `(L47)`) or as a range (`L4-L7`, `L4-7`). A bare
# `L2` stays, so `L2 cache` and `L3 cache` are two claims.
LINE_REF = re.compile(r"\blines?\s+[0-9]+(\s*[-–]\s*[0-9]+)?\b"
                      r"|(?<=[#:(\[])l[0-9]+(\s*[-–]\s*l?[0-9]+)?\b"
                      r"|\bl[0-9]+\s*[-–]\s*l?[0-9]+\b"
                      r"|:[0-9]+\b", re.I)
# A token: a run of letters or digits, or a comparison operator, kept as its own characters so that
# `<` and `<=` stay two claims. Everything else separates tokens.
TOKEN = re.compile(r"[^\W_]+|[<>]=?|[!=]==?")


def normalize(claim):
    s = unicodedata.normalize("NFKC", claim or "").casefold()
    s = LINE_REF.sub(" ", s)
    return " ".join(TOKEN.findall(s))


def fingerprint(e):
    path = str(e.get("file") or "")
    path = path[2:] if path.startswith("./") else path
    dim = dimension(e.get("dimension"))
    h = hashlib.sha256("\0".join((path, dim, normalize(e.get("claim")))).encode("utf-8")).hexdigest()[:12]
    return h, path, dim


def jaccard(a, b):
    u = a | b
    return (len(a & b) / len(u)) if u else 1.0


def agreement(o):
    reports = []
    for p in o["files"]:
        try:
            with open(p, encoding="utf-8", errors="replace") as f:
                text = f.read()
        except OSError:
            die("cannot read the report %s" % safe(p))
        meta, ents = entries_of(text)
        if ents is None:
            die("%s has no readable findings block (review-cycle.sh findings-block refused it)" % safe(p))
        pr = meta.get("pr", "")
        head = meta.get("head", "").lower()
        if not re.fullmatch(r"[0-9]+", pr, re.ASCII) or not re.fullmatch(r"[0-9a-f]{7,40}", head, re.ASCII):
            die("%s: the findings block needs `pr:` (a number) and `head:` (7 to 40 hex digits)" % safe(p))
        fps = {}
        for e in ents:
            if e.get("status", "") in COUNTED:
                h, path, dim = fingerprint(e)
                fps[h] = (path, dim)
        reports.append({"file": p, "pr": int(pr), "head": head, "fps": fps})
    prs = {r["pr"] for r in reports}
    if len(prs) > 1:
        die("the reports are of different pull requests (%s); compare reports of one pull request" %
            ", ".join("#%d" % n for n in sorted(prs)))
    heads = sorted({r["head"] for r in reports}, key=len)
    # Every pair, not only each against the shortest: 7, 10 and 8 digits that share 7 are two heads.
    if any(not b.startswith(a) for a, b in itertools.combinations(heads, 2)):
        die("the reports are of different heads (%s); compare reports of one head" % ", ".join(heads))
    k = len(reports)
    names = {}
    for r in reports:
        names.update(r["fps"])
    pairs = []
    for i, j in itertools.combinations(range(k), 2):
        a, b = set(reports[i]["fps"]), set(reports[j]["fps"])
        pairs.append({"a": i + 1, "b": j + 1, "jaccard": round(jaccard(a, b), 4), "shared": len(a & b), "union": len(a | b)})
    sets = [set(r["fps"]) for r in reports]
    union = set().union(*sets)
    inall = set.intersection(*sets) if sets else set()
    mean = sum(p["jaccard"] for p in pairs) / len(pairs)
    overall = {"mean_pairwise": round(mean, 4), "all_k": round(len(inall) / len(union), 4) if union else 1.0,
               "in_all": len(inall), "union": len(union)}
    dims = []
    for d in sorted({v[1] for v in names.values()}):
        ds = [{h for h in s if names[h][1] == d} for s in sets]
        js = [jaccard(ds[i], ds[j]) for i, j in itertools.combinations(range(k), 2) if ds[i] or ds[j]]
        m = sum(js) / len(js)
        dims.append({"dimension": d, "mean_pairwise": round(m, 4), "pairs_judged": len(js),
                     "fingerprints": len(set().union(*ds)), "unstable": m < o["min"]})
    unstable = [x["dimension"] for x in dims if x["unstable"]]
    fps = [{"fp": h, "file": names[h][0], "dimension": names[h][1], "seen_in": sum(h in s for s in sets)}
           for h in sorted(union, key=lambda h: (names[h][1], names[h][0], h))]
    res = {"pr": reports[0]["pr"], "head": heads[-1], "k": k, "min": o["min"],
           "reports": [{"n": i + 1, "file": r["file"], "findings": len(r["fps"])} for i, r in enumerate(reports)],
           "pairs": pairs, "overall": overall, "overall_unstable": mean < o["min"], "dimensions": dims,
           "unstable": unstable, "fingerprints": fps}
    if o["json"]:
        text = json.dumps(res, sort_keys=True) + "\n"
    else:
        out = ["review-metrics agreement: PR #%d, head %s, k=%d report(s), threshold %.2f" % (res["pr"], heads[-1][:12], k, o["min"])]
        for r in res["reports"]:
            out.append("report %d: %s, %d counted finding(s)" % (r["n"], safe(r["file"]), r["findings"]))
        for p in pairs:
            out.append("pair %d-%d: jaccard %.2f (%d shared of %d)" % (p["a"], p["b"], p["jaccard"], p["shared"], p["union"]))
        out.append("overall: mean pairwise %.2f, in all %d reports %.2f (%d of %d)%s" % (
            mean, k, overall["all_k"], len(inall), len(union), ", UNSTABLE" if res["overall_unstable"] else ""))
        for x in dims:
            out.append("dimension %s: %.2f over %d pair(s), %d fingerprint(s), %s" % (
                x["dimension"], x["mean_pairwise"], x["pairs_judged"], x["fingerprints"], "UNSTABLE" if x["unstable"] else "stable"))
        for f in fps:
            out.append("fingerprint %s %s %s: in %d of %d report(s)" % (f["fp"], f["dimension"], safe(f["file"]), f["seen_in"], k))
        out.append("unstable: " + (", ".join(unstable) if unstable or res["overall_unstable"] else "none")
                   + (" (overall)" if res["overall_unstable"] and not unstable else ""))
        text = "\n".join(out) + "\n"
    emit(o, text)
    return 1 if (unstable or res["overall_unstable"]) else 0


# ---- scorecard ----------------------------------------------------------------------------------
def load_gate():
    path = os.path.join(HERE, "gate-pr-review-state.py")
    try:
        spec = importlib.util.spec_from_file_location("gate_pr_review_state", path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
    except Exception as e:  # missing or broken gate: no trust rule to apply
        die("cannot load the trust rules from %s (%s)" % (path, type(e).__name__))
    missing = [a for a in ("MARKER", "allowlist", "marker_author_allowed") if not hasattr(mod, a)]
    if missing:
        die("cannot load the trust rules from %s (no %s)" % (path, ", ".join(missing)))
    return mod


def read_pr(n, gate):
    """The pull request's findings with their attribution and outcome, or None when gh failed."""
    rc, out = run((sys.executable, "-I", os.path.join(HERE, "pr-json.py"), str(n)))
    try:
        pr = json.loads(out) if rc == 0 else None
    except ValueError:
        pr = None
    if not isinstance(pr, dict):
        return None
    verdicts, closures, untrusted = {}, set(), 0
    for c in pr.get("comments") or []:
        body = str(c.get("body") or "")
        vm, cm = gate.MARKER.match(body), CLOSURE.match(body)
        if not (vm or cm):
            continue
        if not gate.marker_author_allowed(c):
            untrusted += 1
            continue
        if vm:
            g = vm.groups()
            verdicts[int(g[2])] = {"verdict": g[1].upper(), "model": g[6], "tier": g[7],
                                   "block_at": (g[8] or "critical").lower(), "body": body}
        if cm:
            closures.add(int(cm.group(1)))

    def login(x, k):
        return str(((x or {}).get(k) or {}).get("login") or "").lower()
    edited = [c for c in pr.get("editedComments") or [] if gate.marker_author_allowed(c)
              and (gate.MARKER.match(str(c.get("body") or "")) or CLOSURE.match(str(c.get("body") or ""))
                   or login(c, "editor") != login(c, "author"))]
    deleted = [c for c in pr.get("deletedComments") or [] if gate.marker_author_allowed(c)
               and login(c, "actor") != login(c, "author")]
    reasons = []
    if edited:
        reasons.append("%d trusted marker comment(s) edited, or edited by someone else" % len(edited))
    if deleted:
        reasons.append("%d trusted comment(s) deleted by someone other than the author" % len(deleted))
    found, listed = {}, {}
    for p in sorted(verdicts):
        v = verdicts[p]
        _, ents = entries_of(v["body"])
        if ents is None:
            reasons.append("pass %d: the findings block could not be read" % p)
            continue
        for e in ents:
            fid = e.get("id")
            if not fid:
                continue
            if fid not in found:
                sev = str(e.get("severity") or "").upper()
                found[fid] = {"id": fid, "raised_at": p, "severity": sev, "dimension": dimension(e.get("dimension")),
                              "model": ("%s/%s" % (v["model"], v["tier"])) if v["model"] else "unrecorded",
                              "blocking": sev == "CRITICAL" or (sev == "WARNING" and v["block_at"] == "warning")}
            found[fid]["last_pass"], found[fid]["status"] = p, str(e.get("status") or "open")
            listed.setdefault(fid, {})[p] = found[fid]["status"]
    passes = sorted(verdicts)
    newest = verdicts[passes[-1]]["verdict"] if verdicts else None

    def fixer_between(a, b):
        """A trusted fixer closure for a cycle from pass a up to, not including, pass b."""
        return any(a <= c < b for c in closures)
    for f in found.values():
        st, hist = f["status"], listed[f["id"]]
        if st == "verified" and f["last_pass"] > f["raised_at"]:
            f["outcome"] = "verified" if fixer_between(f["raised_at"], f["last_pass"]) else "resolved"
        elif st == "refused-accepted":
            f["outcome"] = "refused"
        elif st == "not-applicable":
            # The pass that first marked it not-applicable in its final run, and the pass before it
            # that listed it: for a non-blocking finding, a fixer closure between the two means the
            # fixer fixed it (this repository's reviewer marks a fixed NOTE not-applicable). A blocking
            # finding the fixer fixed is marked verified, so a blocking not-applicable is withdrawn.
            q = f["last_pass"]
            while any(p < q for p in hist) and hist[max(p for p in hist if p < q)] == "not-applicable":
                q = max(p for p in hist if p < q)
            before = [p for p in hist if p < q]
            f["outcome"] = ("fixed" if not f["blocking"] and before and fixer_between(max(before), q)
                            else "withdrawn")
        elif (not f["blocking"] and f["last_pass"] < passes[-1]
              and fixer_between(f["last_pass"], min(p for p in passes if p > f["last_pass"]))):
            # A non-blocking finding open (or refused-rejected) and no longer listed by the next pass,
            # with a fixer closure between them: the reviewer dropped it because the fixer fixed it.
            f["outcome"] = "fixed"
        elif newest == "PASSED":
            f["outcome"] = "debt"
        else:
            f["outcome"] = "open"
    return {"pr": n, "complete": not reasons, "reasons": reasons, "findings": list(found.values()),
            "untrusted": untrusted, "edited": len(edited), "deleted": len(deleted)}


OUTCOMES = ("verified", "fixed", "resolved", "refused", "withdrawn", "debt", "open")
ACCEPTED = ("verified", "fixed", "resolved")


def tally(rows, key, o):
    acc = collections.OrderedDict()
    for f in sorted((f for r in rows for f in r["findings"]), key=lambda f: f[key]):
        u = acc.setdefault(f[key], dict({"unit": f[key], "raised": 0, "blocking": 0}, **{x: 0 for x in OUTCOMES}))
        u["raised"] += 1
        u["blocking"] += f["blocking"]
        u[f["outcome"]] += 1
        u.setdefault("_ba", 0)
        u["_ba"] += f["blocking"] and f["outcome"] in ACCEPTED
    out = []
    for u in acc.values():
        ba = u.pop("_ba")
        u["accepted_rate"] = round(ba / u["blocking"], 4) if u["blocking"] else None
        u["accepted_blocking"] = ba
        u["cost"] = None
        u["low_acceptance"] = bool(u["blocking"] >= o["min_blocking"] and u["accepted_rate"] < o["min_accept"])
        out.append(u)
    return out


def table(title, units):
    cols = ("raised", "blocking", "verified", "fixed", "resolved", "refused", "debt", "open", "withdrawn")
    w = max([len(title)] + [len(safe(u["unit"], 60)) for u in units])
    lines = ["%-*s  %s  accepted  cost" % (w, title, "  ".join("%8s" % c for c in cols))]
    for u in units:
        rate = ("%d/%d %.2f" % (u["accepted_blocking"], u["blocking"], u["accepted_rate"])) if u["blocking"] else "n/a"
        lines.append("%-*s  %s  %-8s  %s%s" % (w, safe(u["unit"], 60), "  ".join("%8d" % u[c] for c in cols), rate, COST,
                                               "  LOW: retune or retire" if u["low_acceptance"] else ""))
    return lines


def scorecard(o):
    gate = load_gate()
    if not gate.allowlist():
        die("REVIEW_MARKER_AUTHORS is not set or lists no login, so no marker can be trusted. "
            "Set it to the login the harness publishes as: gh api user --jq .login")
    if not any(os.access(os.path.join(d, "gh"), os.X_OK) for d in os.environ.get("PATH", "").split(os.pathsep) if d):
        die("gh is not installed, INCONCLUSIVE")
    prs = o["prs"]
    if prs is None:
        rc, out = run(("gh", "pr", "list", "--state", "merged", "--search", "merged:>=" + o["since"],
                       "--json", "number", "--limit", str(o["limit"])))
        try:
            got = json.loads(out) if rc == 0 else None
        except ValueError:
            got = None
        if not isinstance(got, list):
            die("gh pr list could not list the merged pull requests")
        prs = sorted({int(x["number"]) for x in got if isinstance(x, dict) and isinstance(x.get("number"), int)})
        if len(got) >= o["limit"]:
            print("review-metrics: gh returned --limit %d pull requests; there may be more, raise --limit" % o["limit"],
                  file=sys.stderr)
    rows, failed = [], []
    for n in prs:
        r = read_pr(n, gate)
        (failed.append(n) if r is None else rows.append(r))
    done = [r for r in rows if r["complete"]]
    res = {"prs": prs, "complete": [r["pr"] for r in done],
           "left_out": [{"pr": r["pr"], "reasons": r["reasons"]} for r in rows if not r["complete"]],
           "failed": failed,
           "ignored": {"untrusted_markers": sum(r["untrusted"] for r in rows), "edited_trusted": sum(r["edited"] for r in rows),
                       "deleted_trusted": sum(r["deleted"] for r in rows)},
           "thresholds": {"min_accept": o["min_accept"], "min_blocking": o["min_blocking"]},
           "cost": COST, "by_dimension": tally(done, "dimension", o), "by_model": tally(done, "model", o)}
    if o["json"]:
        text = json.dumps(res, sort_keys=True) + "\n"
    else:
        out = ["review-metrics scorecard: %d pull request(s), %d counted%s" % (
            len(prs), len(done), "".join("; #%d left out: %s" % (x["pr"], "; ".join(x["reasons"])) for x in res["left_out"]))]
        if failed:
            out.append("could not read: " + ", ".join("#%d" % n for n in failed))
        out.append("ignored: %d untrusted marker(s), %d edited and %d deleted trusted comment(s)" % (
            res["ignored"]["untrusted_markers"], res["ignored"]["edited_trusted"], res["ignored"]["deleted_trusted"]))
        out.append("accepted = verified, fixed or resolved / blocking; fixed (non-blocking only) and withdrawn are upper bounds (see the reference); "
                   "cost: not recorded (the verdict marker has no cost field)")
        out.append("")
        out.append("by dimension")
        out += table("dimension", res["by_dimension"])
        out.append("")
        out.append("by model")
        out += table("model/tier", res["by_model"])
        text = "\n".join(out) + "\n"
    emit(o, text)
    if failed:
        print("review-metrics: could not read pull request(s) %s (gh failed or the comments could not be checked)"
              % ",".join(map(str, failed)), file=sys.stderr)
        return 2
    return 0


def main():
    o = parse_args(ARGS)
    return agreement(o) if o["cmd"] == "agreement" else scorecard(o)


sys.exit(main())
PY
