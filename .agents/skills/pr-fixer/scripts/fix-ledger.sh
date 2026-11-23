#!/usr/bin/env bash
#
# fix-ledger.sh: the accepted-fix ledger and the false-refusal audit, with no server.
#
# Usage:
#   fix-ledger.sh [record] (--prs 65,70 | --since YYYY-MM-DD) [--limit N] [--ledger FILE] [--allow-in-repo]
#   fix-ledger.sh summary [--ledger FILE] [--prs 65,70]
#   fix-ledger.sh audit   [--ledger FILE] [--prs 65,70] [--sample N] [--seed S]
#
# WHAT IT MEASURES. `record` reads each pull request (through pr-json.py, so an edited comment is
# never read) and the trusted markers on it, and appends one JSON line per pull request to the
# ledger. Per pull request: the fixer commits, each judged kept, overwritten or reverted at the
# pull request's last head; the findings closed, refused, escalated and declared as debt; the new
# CRITICAL and WARNING findings on the pass after each fix cycle; and every refused finding with
# what happened to it later. Then it prints a summary with the accepted-fix rate. `summary` prints
# the same summary from the ledger alone, taking the newest line per pull request. `audit` samples
# the refused findings from the ledger and prints the false-refusal rate.
#
# WHICH COMMITS ARE THE FIXER'S. Cycle c is the fixer's answer to the verdict of pass c. Its commits
# are those after the commit the trusted pass-c verdict names (`sha=`) up to and including the head
# the trusted closure comment for cycle c names (`head=`), in the pull request's commit order. A
# cycle that only refused pushes nothing, so its head equals the verdict's and it has no commit.
# Every other commit of the pull request counts as a person's (the author's own work, a commit
# pushed outside a fix cycle, or a commit whose closure was not trusted). A merge commit is never
# judged as a later commit, and one inside a fixer range is not a fixer commit. A pure rename by a
# person removes every line of the old path (renames are not followed), so it overwrites them.
#
# KEPT, OVERWRITTEN, REVERTED. For every later non-fixer commit H with one parent, the lines H
# removes or replaces are blamed at H's parent. Lines that blame names a fixer commit C for count as
# C's lines overwritten by a person. C is `reverted` when H's message says `This reverts commit
# <C's full sha>`, `overwritten` when the overwritten lines are at least half the lines C added
# (from `git diff --numstat`), and `kept` otherwise. A commit that added no line is kept unless it
# was reverted. The accepted-fix rate is kept / (kept + overwritten + reverted), over the pull
# requests whose row is complete. When the local clone lacks a commit of the pull request, its
# fixer commits are `unknown` and leave the rate, and so do its refused findings that no later pass
# re-raised: they are recorded with `human_fix_checked: false` and `false_refusal: null`, and the
# audit prints them as not judged. Nothing is fetched: fetch the pull request heads
# first if they are not on a local branch (`git fetch origin 'refs/pull/*/head:refs/remotes/origin/pr/*'`).
#
# FINDINGS. closed and refused are the sums of the trusted closure markers' `closed=` and
# `refused=`; debt is the newest trusted closure's `debt=` (the pr-debt block is replaced on every
# run, so the newest count is the debt). escalated counts the closure layout's labelled lines
# `<id> escalated:` (falsify-and-prove.md); a closure written without those lines counts none.
# The new findings after cycle c are the CRITICAL and WARNING entries of the pass c+1 findings
# block, status open, whose id the pass c block does not have. The findings blocks are read by
# `review-cycle.sh findings-block`, the one parser the other scripts use.
#
# FALSE REFUSALS. A refused finding of cycle c is an id the pass c+1 block marks refused-accepted
# or refused-rejected, or one the closure labels `<id> refused:`. It is a false refusal when a
# later pass lists it as open or refused-rejected (re-raised), or when a later non-fixer commit
# removes or replaces the line the pass c block cites, tracked by blame from the commit pass c
# reviewed (a person fixed it after all).
#
# TRUST. Only what review-cycle.sh trusts is read: the marker must open a comment by a login on
# REVIEW_MARKER_AUTHORS (the gate's own `allowlist`, `marker_author_allowed` and `MARKER`, imported
# from gate-pr-review-state.py), and pr-json.py has already dropped every edited comment. A pull
# request where a trusted comment holding a marker was edited, or a trusted comment was edited or
# deleted by someone other than its author, is recorded with `complete: false` and its reasons, and
# it leaves every rate: a dropped closure would turn fixer commits into a person's. A status
# comment edited in place by its author does not count. An unset or login-less list refuses (exit 2). Comment text is data: only the fixed
# marker formats, the findings block and the closure's labelled lines are parsed, and nothing
# read from a pull request is executed or followed. Only ids, counts, shas, paths and line
# numbers reach the ledger, never comment prose.
#
# THE LEDGER. Append-only JSON lines: a run opens the file for appending and never rewrites it, so
# a rerun adds a newer line for the same pull request and the readers take the newest. Default
# ${XDG_DATA_HOME:-$HOME/.local/share}/pr-reviewer-fixer/fix-ledger.jsonl. A ledger inside the
# current git repository is refused unless --allow-in-repo is given.
#
# EXIT CODES. 0 when every pull request was read. 2 for a refusal (bad argument, no allowlist, a
# ledger in the repository) or when gh could not read a pull request; the rows that were read are
# still appended. It never writes to GitHub.
#
# Needs gh, git and python3 3.9+. Read-only on GitHub and on the git repository.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
command -v gh >/dev/null 2>&1 || { echo "fix-ledger: gh is not installed, INCONCLUSIVE" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "fix-ledger: python3 is not installed, INCONCLUSIVE" >&2; exit 2; }
FL_HERE="$HERE" exec python3 -I - "$@" <<'PY'
import collections, datetime, importlib.util, json, os, random, re, subprocess, sys, tempfile

HERE = os.environ["FL_HERE"]
ARGS = sys.argv[1:]
# The closure marker, anchored at the start of the comment as protocol filter F3 reads it. The
# opener is written in two pieces so this file holds no literal comment opener.
CLOSURE = re.compile(r"\A<" r"!-- pr-fixer-closure: cycle=([0-9]+) head=([0-9a-f]{7,40}) "
                     r"closed=([0-9]+) refused=([0-9]+) debt=([0-9]+) -->", re.ASCII)
LABEL = re.compile(r"^([CWN][0-9]+) (closed|refused|escalated|open):", re.M | re.ASCII)
REFUSED_BY_REVIEWER = ("refused-accepted", "refused-rejected")
STILL_OPEN = ("", "open", "refused-rejected")


def die(msg, code=2):
    print("fix-ledger: " + msg, file=sys.stderr)
    sys.exit(code)


def load_gate():
    path = os.path.join(HERE, "gate-pr-review-state.py")
    try:
        spec = importlib.util.spec_from_file_location("gate_pr_review_state", path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
    except Exception as e:  # missing or broken gate: no trust rule to apply
        die("cannot load the trust rules from %s (%s)" % (path, type(e).__name__))
    missing = [a for a in ("MARKER", "allowlist", "marker_author_allowed") if not hasattr(mod, a)]
    if missing:  # a renamed name would otherwise be a traceback and exit 1
        die("cannot load the trust rules from %s (no %s)" % (path, ", ".join(missing)))
    return mod


def run(cmd, timeout=120):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return 127, ""
    return r.returncode, r.stdout


def gh_json(*args):
    rc, out = run(("gh",) + args)
    if rc:
        return None
    try:
        return json.loads(out)
    except ValueError:
        return None


# ---- arguments ----------------------------------------------------------------------------------
def parse_args(argv):
    cmd = "record"
    if argv and not argv[0].startswith("--"):
        cmd = argv[0]
        argv = argv[1:]
    if cmd not in ("record", "summary", "audit"):
        die("unknown command %r: use record, summary or audit" % cmd)
    o = {"cmd": cmd, "prs": None, "since": None, "limit": 200, "ledger": None, "in_repo": False,
         "sample": None, "seed": 0}
    flags = {"record": {"--prs", "--since", "--limit", "--ledger", "--allow-in-repo"},
             "summary": {"--ledger", "--prs"}, "audit": {"--ledger", "--prs", "--sample", "--seed"}}[cmd]
    i = 0
    while i < len(argv):
        a = argv[i]
        if a not in flags:
            die("%s does not take %r" % (cmd, a))
        if a == "--allow-in-repo":
            o["in_repo"] = True
            i += 1
            continue
        if i + 1 >= len(argv):
            die("%s needs a value" % a)
        v = argv[i + 1]
        i += 2
        if a == "--prs":
            if not re.fullmatch(r"[0-9]+(,[0-9]+)*", v, re.ASCII):
                die("--prs takes pull request numbers separated by commas, such as 65,70")
            o["prs"] = sorted({int(x) for x in v.split(",")})
        elif a == "--since":
            try:
                if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", v, re.ASCII):
                    raise ValueError
                datetime.date.fromisoformat(v)
            except ValueError:
                die("--since takes a date as YYYY-MM-DD")
            o["since"] = v
        elif a in ("--limit", "--sample"):
            if not re.fullmatch(r"[1-9][0-9]{0,5}", v, re.ASCII):
                die("%s takes a positive whole number" % a)
            o[a[2:]] = int(v)
        elif a == "--seed":
            if not re.fullmatch(r"[0-9]{1,9}", v, re.ASCII):
                die("--seed takes a whole number")
            o["seed"] = int(v)
        elif a == "--ledger":
            if not v:
                die("--ledger needs a file")
            o["ledger"] = v
    if cmd == "record" and (o["prs"] is None) == (o["since"] is None):
        die("record takes exactly one of --prs 65,70 or --since YYYY-MM-DD")
    return o


def ledger_path(o):
    if o["ledger"]:
        return os.path.abspath(o["ledger"])
    base = os.environ.get("XDG_DATA_HOME") or (os.path.join(os.environ["HOME"], ".local", "share")
                                               if os.environ.get("HOME") else "")
    if not base:
        die("neither XDG_DATA_HOME nor HOME is set; name the ledger with --ledger FILE")
    return os.path.join(base, "pr-reviewer-fixer", "fix-ledger.jsonl")


# ---- git ----------------------------------------------------------------------------------------
def git(*args):
    # Literal pathspecs: a path read from a diff is a file name, never pathspec magic such as `:(top)`.
    return run(("git", "--literal-pathspecs", "-c", "core.quotePath=false") + args)


def have(sha):
    return git("cat-file", "-e", sha + "^{commit}")[0] == 0


def parents(sha):
    rc, out = git("rev-list", "--parents", "-n", "1", sha)
    return out.split()[1:] if rc == 0 else None


def message(sha):
    return git("log", "-1", "--format=%B", sha)[1]


def lines_added(sha, parent):
    rc, out = git("diff", "--no-renames", "--numstat", parent, sha)
    n = 0
    for ln in out.splitlines():
        f = ln.split("\t")
        if len(f) >= 3 and f[0].isdigit():
            n += int(f[0])
    return n


def removed_hunks(sha, parent):
    """(path, start, count) for each range of the parent's lines that `sha` removes or replaces.

    The paths come from `--name-only -z`, never from the `---` header: under -U0 a removed line
    whose text starts with `-- ` prints as `--- ...`, and a path with a space gets a tab appended.
    Each file is diffed alone and only its `@@` lines are read; a content line always starts with
    a space, `+` or `-`, so it cannot be taken for one."""
    rc, out = git("diff", "--no-renames", "--name-only", "-z", parent, sha)
    hunks = []
    for path in (p for p in out.split("\0") if p) if rc == 0 else ():
        rc2, diff = git("diff", "--no-renames", "--no-color", "--no-ext-diff", "-U0", parent, sha, "--", path)
        for m in re.finditer(r"^@@ -([0-9]+)(?:,([0-9]+))? \+", diff if rc2 == 0 else "", re.M):
            count = 1 if m.group(2) is None else int(m.group(2))
            if count:
                hunks.append((path, int(m.group(1)), count))
    return hunks


BLAME = {}


def blame(rev, path, start, count):
    """[(origin commit, origin line)] for each line, or [] when blame cannot answer."""
    key = (rev, path, start, count)
    if key not in BLAME:
        rc, out = git("blame", "--porcelain", "-L", "%d,+%d" % (start, count), rev, "--", path)
        BLAME[key] = [] if rc else [(m.group(1), int(m.group(2))) for m in
                                    re.finditer(r"^([0-9a-f]{40}) ([0-9]+) [0-9]+(?: [0-9]+)?$", out, re.M)]
    return BLAME[key]


# ---- one pull request ---------------------------------------------------------------------------
def findings_entries(body):
    """The entries of a verdict comment's findings block, via review-cycle.sh, or None."""
    fd, tmp = tempfile.mkstemp(prefix="fix-ledger-", suffix=".md")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(body)
        rc, out = run(("bash", os.path.join(HERE, "review-cycle.sh"), "findings-block", "--report", tmp))
        if rc:
            return None
        return json.loads(out).get("entries") or []
    except (OSError, ValueError):
        return None
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def record_pr(n, gate):
    rc, out = run((sys.executable, "-I", os.path.join(HERE, "pr-json.py"), str(n)))
    try:
        pr = json.loads(out) if rc == 0 else None
    except ValueError:
        pr = None
    meta = gh_json("pr", "view", str(n), "--json", "commits,mergeCommit,mergedAt,state,headRefOid")
    if not isinstance(pr, dict) or not isinstance(meta, dict):
        return None
    m = re.match(r"https?://[^/]+/([^/]+/[^/]+)/pull/", str(pr.get("url") or ""))
    commits = [str(c.get("oid") or "").lower() for c in meta.get("commits") or []]
    idx = {c: i for i, c in enumerate(commits)}
    reasons = []

    def resolve(prefix):
        hit = [c for c in commits if c.startswith(prefix.lower())]
        return hit[0] if len(hit) == 1 else None

    # Trusted, unedited comments only; count what was left out.
    verdicts, closures, untrusted = {}, {}, 0
    for c in pr.get("comments") or []:
        body = str(c.get("body") or "")
        vm, cm = gate.MARKER.match(body), CLOSURE.match(body)
        if not (vm or cm):
            continue
        if not gate.marker_author_allowed(c):
            untrusted += 1
            continue
        if vm:
            verdicts[int(vm.group(3))] = {"sha": vm.group(1).lower(), "verdict": vm.group(2).upper(), "body": body}
        if cm:
            closures[int(cm.group(1))] = {"head": cm.group(2), "closed": int(cm.group(3)),
                                          "refused": int(cm.group(4)), "debt": int(cm.group(5)), "body": body}
    # As review-cycle.sh reads them: an edited marker is dropped (pr-json.py did that), and a trusted
    # comment edited or deleted by someone other than its author may have held one. Either leaves the
    # row incomplete, since a dropped closure would turn fixer commits into a person's. A status
    # comment its author edited in place, as the protocol has it, is neither.
    def login(x, k):
        return str(((x or {}).get(k) or {}).get("login") or "").lower()
    edited = [c for c in pr.get("editedComments") or [] if gate.marker_author_allowed(c)
              and (gate.MARKER.match(str(c.get("body") or "")) or CLOSURE.match(str(c.get("body") or ""))
                   or login(c, "editor") != login(c, "author"))]
    deleted = [c for c in pr.get("deletedComments") or [] if gate.marker_author_allowed(c)
               and login(c, "actor") != login(c, "author")]
    if edited:
        reasons.append("%d trusted marker comment(s) edited, or edited by someone else, so a marker was dropped" % len(edited))
    if deleted:
        reasons.append("%d trusted comment(s) deleted by someone other than the author" % len(deleted))

    parsed = {p: findings_entries(v["body"]) for p, v in verdicts.items()}
    fixer, cycles = {}, []
    for c in sorted(closures):
        cl, v = closures[c], verdicts.get(c)
        start = resolve(v["sha"]) if v else None
        end = resolve(cl["head"])
        cyc = {"cycle": c, "pass_sha": start, "closure_head": end, "closed": cl["closed"],
               "refused": cl["refused"], "debt": cl["debt"],
               "escalated": sum(1 for x in LABEL.finditer(cl["body"]) if x.group(2) == "escalated"),
               "fixer_commits": [], "new_critical": None, "new_warning": None}
        if start is None or end is None or idx[end] < idx[start]:
            reasons.append("cycle %d: the pass-%d commit or the closure head is not in the commit list" % (c, c))
        else:
            for s in commits[idx[start] + 1: idx[end] + 1]:
                fixer[s] = c
                cyc["fixer_commits"].append(s)
        before, after = parsed.get(c), parsed.get(c + 1)
        if before is not None and after is not None:
            ids = {e.get("id") for e in before}
            new = [e for e in after if e.get("id") not in ids and e.get("status", "") in ("", "open")]
            cyc["new_critical"] = sum(1 for e in new if e.get("severity") == "CRITICAL")
            cyc["new_warning"] = sum(1 for e in new if e.get("severity") == "WARNING")
        cycles.append(cyc)

    # Git: the later non-fixer commits, what they remove, and which fixer lines that was.
    git_ok = bool(commits) and all(have(s) for s in commits)
    removed_ids, over, reverted, added = {}, collections.Counter(), set(), {}
    reasons_git = "ok"
    if git_ok:
        # A merge commit inside a fixer range is not a fix: it leaves the range, and a merge is never
        # judged as a later commit either.
        for s in [s for s in fixer if len(parents(s) or ()) > 1]:
            del fixer[s]
            for cyc in cycles:
                if s in cyc["fixer_commits"]:
                    cyc["fixer_commits"].remove(s)
        for s in fixer:
            ps = parents(s)
            added[s] = lines_added(s, ps[0]) if ps else 0
        first = min([idx[s] for s in fixer] + [idx[x] for x in (resolve(v["sha"]) for v in verdicts.values()) if x]
                    or [len(commits)])
        for h in commits[first + 1:]:
            if h in fixer:
                continue
            ps = parents(h)
            if not ps or len(ps) != 1:
                continue
            msg = message(h)
            for s in fixer:
                if idx[s] < idx[h] and ("This reverts commit " + s) in msg:
                    reverted.add(s)
            ids = set()
            for path, start, count in removed_hunks(h, ps[0]):
                for origin, oline in blame(ps[0], path, start, count):
                    ids.add((path, origin, oline))
                    if origin in fixer and idx[origin] < idx[h]:
                        over[origin] += 1
            removed_ids[h] = ids
    else:
        reasons_git = "a commit of the pull request is not in the local clone" if commits else "no commit list"

    fixer_rows = []
    for s in sorted(fixer, key=lambda x: idx[x]):
        if not git_ok:
            st = "unknown"
        elif s in reverted:
            st = "reverted"
        elif added.get(s, 0) and over[s] * 2 >= added[s]:
            st = "overwritten"
        else:
            st = "kept"
        fixer_rows.append({"sha": s, "cycle": fixer[s], "lines_added": added.get(s) if git_ok else None,
                           "lines_overwritten": over[s] if git_ok else None, "status": st})

    # Refused findings and what happened to them.
    refused_rows = []
    for cyc in cycles:
        c = cyc["cycle"]
        before, after = parsed.get(c) or [], parsed.get(c + 1) or []
        # A findings block carries every id forward with its status, so an id the reviewer already
        # judged refused on pass c was refused in an earlier cycle: it is counted there, once.
        earlier = {e.get("id") for e in before if e.get("status") in REFUSED_BY_REVIEWER}
        ids = [e.get("id") for e in after if e.get("status") in REFUSED_BY_REVIEWER and e.get("id") not in earlier]
        ids += [x.group(1) for x in LABEL.finditer(closures[c]["body"]) if x.group(2) == "refused"]
        for fid in sorted(set(i for i in ids if i), key=lambda i: (i[0], int(i[1:]) if i[1:].isdigit() else 0)):
            src = next((e for e in before if e.get("id") == fid), {})
            path, line = src.get("file"), src.get("line")
            line = int(line) if isinstance(line, str) and line.isdigit() else None
            reraised = None
            for p in sorted(q for q in parsed if q > c and parsed[q] is not None):
                if any(e.get("id") == fid and e.get("status", "") in STILL_OPEN for e in parsed[p]):
                    reraised = p
                    break
            fixed_by = None
            pass_sha = cyc["pass_sha"]
            if git_ok and path and line and pass_sha:
                ident = blame(pass_sha, path, line, 1)
                if ident:
                    key = (path,) + ident[0]
                    for h in commits[idx[pass_sha] + 1:]:
                        if key in removed_ids.get(h, ()):
                            fixed_by = h
                            break
            # Without the commits a person's fix cannot be seen: a refusal no pass re-raised is then
            # not judged (null), never held.
            false = True if (reraised or fixed_by) else (False if git_ok else None)
            refused_rows.append({"id": fid, "cycle": c, "file": path, "line": line,
                                 "reviewer_status": next((e.get("status") for e in after if e.get("id") == fid), None),
                                 "reraised_at_pass": reraised, "human_fix": fixed_by,
                                 "human_fix_checked": git_ok, "false_refusal": false})

    newest = closures[max(closures)] if closures else None
    count = collections.Counter(r["status"] for r in fixer_rows)
    row = {
        "schema": 1, "kind": "pr",
        "recorded_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "repo": m.group(1) if m else None, "pr": n, "state": meta.get("state"), "merged_at": meta.get("mergedAt"),
        "merge_commit": ((meta.get("mergeCommit") or {}).get("oid")), "head": meta.get("headRefOid"),
        "complete": not reasons, "incomplete_reasons": reasons, "git": reasons_git,
        "passes": max(verdicts) if verdicts else 0, "cycles": cycles, "fixer_commits": fixer_rows,
        "commits": {k: count.get(k, 0) for k in ("kept", "overwritten", "reverted", "unknown")},
        "findings": {"closed": sum(c["closed"] for c in closures.values()),
                     "refused": sum(c["refused"] for c in closures.values()),
                     "escalated": sum(c["escalated"] for c in cycles),
                     "debt": newest["debt"] if newest else 0},
        "refused_findings": refused_rows,
        "ignored": {"untrusted_markers": untrusted, "edited_trusted": len(edited), "deleted_trusted": len(deleted)},
    }
    return row


# ---- reading and summing ------------------------------------------------------------------------
def read_ledger(path, prs):
    rows, bad = collections.OrderedDict(), 0
    try:
        with open(path, encoding="utf-8") as f:
            for ln in f:
                if not ln.strip():
                    continue
                try:
                    r = json.loads(ln)
                except ValueError:
                    bad += 1
                    continue
                if not isinstance(r, dict) or r.get("kind") != "pr" or not isinstance(r.get("pr"), int):
                    bad += 1
                    continue
                if prs is None or r["pr"] in prs:
                    key = (r.get("repo"), r["pr"])
                    rows.pop(key, None)
                    rows[key] = r  # the newest line for a pull request wins
    except FileNotFoundError:
        die("no ledger at %s; run record first" % path)
    except OSError as e:
        die("cannot read the ledger %s (%s)" % (path, e.strerror))
    if bad:
        print("fix-ledger: %d unreadable ledger line(s) skipped" % bad, file=sys.stderr)
    return list(rows.values())


def rate(num, den):
    return "%d/%d (%.1f%%)" % (num, den, 100.0 * num / den) if den else "n/a (nothing to judge)"


def summary(rows):
    done = [r for r in rows if r.get("complete")]
    out = [r for r in rows if not r.get("complete")]
    k = collections.Counter()
    for r in done:
        for s, v in (r.get("commits") or {}).items():
            k[s] += v
        for s, v in (r.get("findings") or {}).items():
            k["f_" + s] += v
        for c in r.get("cycles") or []:
            if c.get("new_critical") is not None:
                k["measured"] += 1
                k["new_c"] += c["new_critical"]
                k["new_w"] += c.get("new_warning") or 0
    judged = k["kept"] + k["overwritten"] + k["reverted"]
    print("fix-ledger: %d pull request(s), %d complete%s" % (
        len(rows), len(done), "".join("; #%s left out: %s" % (r["pr"], "; ".join(r.get("incomplete_reasons") or []))
                                      for r in out)))
    print("fixer commits: %d (kept %d, overwritten %d, reverted %d, unknown %d)" % (
        judged + k["unknown"], k["kept"], k["overwritten"], k["reverted"], k["unknown"]))
    print("accepted-fix rate: " + rate(k["kept"], judged))
    print("findings: closed %d, refused %d, escalated %d, debt %d" % (
        k["f_closed"], k["f_refused"], k["f_escalated"], k["f_debt"]))
    print("new after a fix cycle: critical %d, warning %d, over %d cycle(s) measured" % (
        k["new_c"], k["new_w"], k["measured"]))


def audit(rows, o):
    pool = [(r, f) for r in rows if r.get("complete") for f in r.get("refused_findings") or []]
    pool.sort(key=lambda x: (str(x[0].get("repo")), x[0]["pr"], x[1].get("cycle") or 0, str(x[1].get("id"))))
    n = len(pool) if o["sample"] is None else min(o["sample"], len(pool))
    picked = random.Random(o["seed"]).sample(pool, n) if n < len(pool) else pool
    picked.sort(key=lambda x: (str(x[0].get("repo")), x[0]["pr"], x[1].get("cycle") or 0, str(x[1].get("id"))))
    print("fix-ledger audit: %d refused finding(s) in %d complete pull request(s), %d sampled (seed %d)" % (
        len(pool), sum(1 for r in rows if r.get("complete")), n, o["seed"]))
    false = unjudged = 0
    for r, f in picked:
        where = "%s:%s" % (f.get("file"), f.get("line")) if f.get("file") else "no file cited"
        if f.get("reraised_at_pass"):
            what = "false refusal: re-raised as open at pass %d" % f["reraised_at_pass"]
        elif f.get("human_fix"):
            what = "false refusal: a later commit %s changed the cited line" % f["human_fix"][:7]
        elif f.get("false_refusal") is None:
            what = "not judged: the commits were not in the local clone"
            unjudged += 1
        else:
            what = "held"
        false += bool(f.get("reraised_at_pass") or f.get("human_fix"))
        print("#%s %s (cycle %s, %s): %s" % (r["pr"], f.get("id"), f.get("cycle"), where, what))
    print("false-refusal rate: " + rate(false, n - unjudged))
    if unjudged:
        print("%d refused finding(s) not judged and left out of the rate: their commits were not in the "
              "local clone; fetch them and record again" % unjudged)


# ---- main ---------------------------------------------------------------------------------------
def main():
    o = parse_args(ARGS)
    path = ledger_path(o)
    if o["cmd"] == "summary":
        summary(read_ledger(path, o["prs"]))
        return 0
    if o["cmd"] == "audit":
        audit(read_ledger(path, o["prs"]), o)
        return 0
    gate = load_gate()
    if not gate.allowlist():
        die("REVIEW_MARKER_AUTHORS is not set or lists no login, so no marker can be trusted. "
            "Set it to the login the harness publishes as: gh api user --jq .login")
    rc, top = git("rev-parse", "--show-toplevel")
    target = os.path.realpath(path)  # the file itself: a symlink to a file in the repository is in it
    if rc == 0 and top.strip() and not o["in_repo"]:
        root = os.path.realpath(top.strip())
        if target == root or target.startswith(root + os.sep):
            die("the ledger %s is inside the repository %s; pick a file outside it, or pass --allow-in-repo" % (path, root))
    prs = o["prs"]
    if prs is None:
        got = gh_json("pr", "list", "--state", "merged", "--search", "merged:>=" + o["since"],
                      "--json", "number", "--limit", str(o["limit"]))
        if not isinstance(got, list):
            die("gh pr list could not list the merged pull requests")
        prs = sorted({int(x["number"]) for x in got if isinstance(x, dict) and isinstance(x.get("number"), int)})
        if len(got) >= o["limit"]:
            print("fix-ledger: gh returned --limit %d pull requests; there may be more, raise --limit" % o["limit"],
                  file=sys.stderr)
    rows, failed = [], []
    for n in prs:
        r = record_pr(n, gate)
        if r is None:
            failed.append(n)
        else:
            rows.append(r)
    if rows:
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
        data = "".join(json.dumps(r, sort_keys=True) + "\n" for r in rows)
        with open(path, "a", encoding="utf-8") as f:  # append only: never truncated, never rewritten
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
    summary(rows)
    print("ledger: %s (+%d line(s))" % (path, len(rows)))
    if failed:
        print("fix-ledger: could not read pull request(s) %s (gh failed or the comments could not be checked)"
              % ",".join(map(str, failed)), file=sys.stderr)
        return 2
    return 0


sys.exit(main())
PY
