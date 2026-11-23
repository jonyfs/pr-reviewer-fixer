#!/usr/bin/env bash
#
# proof-check.sh: re-runs the proofs a pr-fixer closure comment claims, and compares the results.
#
# Usage:
#   proof-check.sh --file FILE          [options]   the closure (or any text) in a local file
#   proof-check.sh --pr N [--cycle C]   [options]   the newest trusted closure comment on pull request N
#                                                   (of cycle C when given), read through pr-json.py
# Options:
#   --repo DIR          the git repository holding the commits (default: the current directory)
#   --head SHA          the head the proofs must belong to (default: the PR's head with --pr, else the
#                       head= of the closure marker when the text has one)
#   --sample N          re-run N entries, not all of them (default: all)
#   --seed S            the seed that picks the sample; the same seed picks the same entries. Default:
#                       a random seed the checker draws and prints, so the prover cannot know in
#                       advance which entries a sample skips; pass the printed seed to repeat a run
#   --check-output      also compare output_sha256
#   --allow-file FILE   permitted command prefixes, one per line (# starts a comment)
#   --timeout SECS      per command (default 600)
#
# THE BLOCK. The text holds exactly one fenced block opened by a line that is exactly ```proofs and
# closed by a line that is exactly ```. It is a JSON array with one object per proof case:
#   {"command": "bash tests/x/run.sh", "exit_code": 0, "head_sha": "<40 hex>", "tree_hash": "<40 hex>",
#    "tool_versions": {"bash": "5.2.37"}, "output_sha256": "<64 hex>"}
# Format and rules: references/falsify-and-prove.md, "Proof block".
#
# THE COMMANDS ARE UNTRUSTED TEXT. They come from a comment on a pull request, so nothing in them is
# run unless all of this holds, for every entry, before any entry runs:
#   - an allowlist is configured: PROOF_CHECK_ALLOW (entries separated by newlines or commas) or
#     --allow-file. No allowlist refuses every command. The person sets it; an agent never does.
#   - the command uses only letters, digits, space and . _ / = : , + @ % - (no quote, no $, no ;, no |,
#     no &, no redirection, no backtick, no glob, no newline), has no `..` path part, and no / or ~
#     at the start of a word or right after = : , @ + % inside one (`--output=/x`, `@/x` and
#     `file:///x` are refused like `/x`).
#   - its words start with the words of one allowlist entry: every entry word but the last must equal
#     the command word; the last must equal it too, unless it ends with /, in which case it is a
#     prefix of the command word (`bash tests/` permits `bash tests/a/run.sh`, not `bashx` nor
#     `bash testsx/`).
#   - an entry is a prefix, and the words after it are passed to the program, so none of them may
#     start with - (`git diff` does not permit `git diff --output=x`, `bash` does not permit
#     `bash -c x`). To permit an option, write it into the entry (`bash tests/run-all.sh --fresh`).
# A command that passes is split on spaces and run as an argument list: no eval, no shell, stdin from
# /dev/null, in a fresh clone checked out at its head_sha, with HOME set to an empty scratch folder,
# an environment holding only PATH (its absolute elements), HOME, TMPDIR, LANG and LC_ALL,
# in a process group of its own whose every member is killed when the command exits, times out or
# prints more than 64 MiB (output goes to a file, never held in memory).
# The allowlist limits WHICH command runs, not WHAT it does: the checkout is the pull request's code,
# so permit only commands you would run on that code anyway.
#
# THE HEAD AND THE TREE. Every head_sha must be a commit in --repo, its tree must equal tree_hash, and
# when an expected head is known, head_sha must be that head or an ancestor of it (a red run sits on
# the commit before the fix). The final ok line names that head and where it came from (--pr, --head
# or the closure marker, which is the untrusted text's own claim), or says there was none. tool_versions is printed with a mismatch, never compared.
#
# EXIT CODES. 0 every re-run entry matched. 1 at least one re-run entry did not match (exit code, or
# output hash with --check-output); a mismatch wins over a later failure to check. 2 nothing could be
# checked: bad usage, no block, two blocks, malformed JSON, an empty array, a missing or malformed
# field, a refused command, no allowlist, a wrong head or tree, a clone or checkout that failed, a
# timeout, output past 64 MiB, or a pull request that could not be read. Exit 2 never means "proved"; it means nobody
# could look. Every entry is validated before any entry runs.
#
# Needs bash, git and python3 (3.9+); --pr also needs gh, through pr-json.py.
set -uo pipefail
command -v python3 >/dev/null 2>&1 || { echo "proof-check: python3 is not installed, cannot check" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "proof-check: git is not installed, cannot check" >&2; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"
PROOF_CHECK_HERE="$HERE" exec python3 -I - "$@" <<'PY'
import hashlib, json, os, re, secrets, shutil, signal, subprocess, sys, tempfile, time

def say(msg): print("proof-check: " + msg, flush=True)
def cannot(msg):
    say(msg + ", cannot check"); sys.exit(2)
LIVE = {"group": None, "work": None}   # what a crash must still stop and delete
def stop_group(pgid):
    try:
        os.killpg(pgid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):   # gone already (macOS may say EPERM for zombies)
        pass
# An error nobody foresaw is "cannot check" (2), never a mismatch (1).
def _crash(kind, value, tb):
    if LIVE["group"]:
        stop_group(LIVE["group"])
    if LIVE["work"]:
        shutil.rmtree(LIVE["work"], ignore_errors=True)
    say("internal error (%s), cannot check" % kind.__name__); os._exit(2)
sys.excepthook = _crash

USAGE = ("usage: proof-check.sh (--file FILE | --pr N [--cycle C]) [--repo DIR] [--head SHA] "
         "[--sample N] [--seed S] [--check-output] [--allow-file FILE] [--timeout SECS]")
args = sys.argv[1:]
opt = {"file": None, "pr": None, "cycle": None, "repo": ".", "head": None, "sample": None,
       "seed": None, "check_output": False, "allow_file": None, "timeout": "600"}
head_from = None   # where the expected head came from, named on the final line
i = 0
while i < len(args):
    a = args[i]
    if a == "--check-output":
        opt["check_output"] = True; i += 1; continue
    if a in ("-h", "--help"):
        print(USAGE); sys.exit(0)
    key = {"--file": "file", "--pr": "pr", "--cycle": "cycle", "--repo": "repo", "--head": "head",
           "--sample": "sample", "--seed": "seed", "--allow-file": "allow_file", "--timeout": "timeout"}.get(a)
    if key is None or i + 1 >= len(args):
        print(USAGE, file=sys.stderr); cannot("unknown option or missing value: %s" % a)
    opt[key] = args[i + 1]; i += 2
if (opt["file"] is None) == (opt["pr"] is None):
    print(USAGE, file=sys.stderr); cannot("give exactly one of --file and --pr")
for k in ("pr", "cycle", "sample", "timeout"):
    if opt[k] is not None and not re.fullmatch(r"[0-9]{1,6}", opt[k]):
        cannot("--%s needs a whole number" % k)
if opt["sample"] is not None and int(opt["sample"]) < 1:
    cannot("--sample needs a number of 1 or more")
if opt["seed"] is None:
    opt["seed"] = secrets.token_hex(8)
if not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", opt["seed"]):
    cannot("--seed takes letters, digits, dot, underscore and dash only")
HEX = re.compile(r"[0-9a-f]{40}([0-9a-f]{24})?")
if opt["head"] is not None and not HEX.fullmatch(opt["head"]):
    cannot("--head needs a full lowercase commit sha")

def git(*a, cwd=None):
    r = subprocess.run(["git", "-c", "core.hooksPath=/dev/null", *a], cwd=cwd or opt["repo"],
                       stdin=subprocess.DEVNULL, capture_output=True, text=True)
    return r.returncode, r.stdout.strip()

rc, top = git("rev-parse", "--show-toplevel")
if rc != 0:
    cannot("%s is not a git repository" % opt["repo"])
opt["repo"] = top

# ---- the text ----------------------------------------------------------------------------------
if opt["file"] is not None:
    try:
        text = open(opt["file"], encoding="utf-8").read()
    except (OSError, UnicodeDecodeError) as e:
        cannot("cannot read %s (%s)" % (opt["file"], e.__class__.__name__))
else:
    authors = [x.strip().lower() for x in os.environ.get("REVIEW_MARKER_AUTHORS", "").split(",")]
    authors = [x for x in authors if re.fullmatch(r"[a-z0-9][a-z0-9_-]*", x)]
    if not authors:
        cannot("REVIEW_MARKER_AUTHORS names no login, so no closure comment can be trusted")
    pj = os.path.join(os.environ["PROOF_CHECK_HERE"], "pr-json.py")
    r = subprocess.run([sys.executable, "-I", pj, opt["pr"]], cwd=opt["repo"], stdin=subprocess.DEVNULL,
                       capture_output=True, text=True)
    try:
        pr = json.loads(r.stdout) if r.returncode == 0 else None
    except ValueError:
        pr = None
    if not isinstance(pr, dict):
        cannot("pull request %s could not be read" % opt["pr"])
    prefix = "<" + "!-- pr-fixer-closure: cycle=" + (opt["cycle"] + " " if opt["cycle"] else "")
    found = [c for c in pr.get("comments") or []
             if isinstance(c, dict) and ((c.get("author") or {}).get("login") or "").lower() in authors
             and isinstance(c.get("body"), str) and c["body"].startswith(prefix)]
    if not found:
        cannot("no trusted pr-fixer-closure comment%s on pull request %s"
               % (" for cycle " + opt["cycle"] if opt["cycle"] else "", opt["pr"]))
    text = found[-1]["body"]
    pr_head = pr.get("headRefOid") or ""
    if not HEX.fullmatch(pr_head):
        cannot("pull request %s has no readable head" % opt["pr"])
    if opt["head"] is not None and opt["head"] != pr_head:
        cannot("--head %s is not the pull request's head %s" % (opt["head"], pr_head))
    opt["head"] = pr_head
    head_from = "the pull request"
lines = text.replace("\r\n", "\n").split("\n")
if opt["head"] is not None and opt["pr"] is None:
    head_from = "--head"

if opt["head"] is None:
    m = re.match("<" + r"!-- pr-fixer-closure: .*\bhead=([0-9a-f]{7,64})\b", lines[0] if lines else "")
    if m:
        rc, full = git("rev-parse", "--verify", "--quiet", m.group(1) + "^{commit}")
        if rc != 0 or not HEX.fullmatch(full):
            cannot("the closure marker names head %s, which is not a commit in %s" % (m.group(1), opt["repo"]))
        opt["head"] = full
        head_from = "the closure marker"

# ---- the block ---------------------------------------------------------------------------------
blocks, cur = [], None
for ln in lines:
    if cur is None:
        if ln.strip() == "```proofs":
            cur = []
    elif ln.strip() == "```":
        blocks.append("\n".join(cur)); cur = None
    else:
        cur.append(ln)
if cur is not None:
    cannot("the proofs block is not closed")
if len(blocks) != 1:
    cannot("expected exactly one ```proofs block, found %d" % len(blocks))
try:
    data = json.loads(blocks[0])
except (ValueError, RecursionError) as e:
    cannot("the proofs block is not valid JSON (%s)" % getattr(e, "msg", e.__class__.__name__))
if not isinstance(data, list) or not data:
    cannot("the proofs block must be a non-empty JSON array")
if len(data) > 200:
    cannot("the proofs block holds %d entries; the limit is 200" % len(data))

# ---- the allowlist -----------------------------------------------------------------------------
SAFE = re.compile(r"[A-Za-z0-9 ._/=:,+@%-]{1,1000}")
def words_ok(s):
    if not SAFE.fullmatch(s):
        return "it holds a character outside letters, digits, space and . _ / = : , + @ % -"
    w = s.split()
    if not w:
        return "it is empty"
    for x in w:
        # A path hides in an option value too (--output=/x, @/x, file:///x, a,../x), so the rules
        # apply after = : , @ + % as well as at the start of a word and after /.
        if re.search(r"(^|[/=:,@+%])\.\.([/=:,@+%]|$)", x):
            return "a word has a .. path part"
        if re.search(r"(^|[=:,@+%])[/~]", x):
            return "a word starts with / or ~, or holds one after = : , @ + %"
    return None
raw = []
for part in re.split(r"[\n,]", os.environ.get("PROOF_CHECK_ALLOW", "")):
    raw.append(part)
if opt["allow_file"] is not None:
    try:
        raw += open(opt["allow_file"], encoding="utf-8").read().split("\n")
    except (OSError, UnicodeDecodeError):
        cannot("cannot read the allowlist %s" % opt["allow_file"])
allow = []
for e in raw:
    e = e.split("#", 1)[0].strip()
    if not e:
        continue
    why = words_ok(e)
    if why:
        cannot("allowlist entry %r is refused: %s" % (e, why))
    allow.append(e.split())
if not allow:
    cannot("no allowlist is configured (PROOF_CHECK_ALLOW or --allow-file), so every command is refused")
# An entry is a prefix: the command may add words after it. Those words are passed to the program,
# so one that starts with - would be an option the person never permitted (git diff --output=x,
# bash -c x). They are refused; a person who wants an option writes it into the entry itself.
def allowed(w):
    why = "it is not on the allowlist"
    for a in allow:
        if len(w) < len(a) or w[:len(a) - 1] != a[:-1]:
            continue
        last, cw = a[-1], w[len(a) - 1]
        if cw == last or (last.endswith("/") and cw.startswith(last) and len(cw) > len(last)):
            if any(x.startswith("-") for x in w[len(a):]):
                why = "a word after the allowlist entry %r starts with -" % " ".join(a)
                continue
            return None
    return why

# ---- validate every entry before any runs ------------------------------------------------------
FIELDS = ("command", "exit_code", "head_sha", "tree_hash", "tool_versions", "output_sha256")
entries = []
for n, e in enumerate(data, 1):
    if not isinstance(e, dict):
        cannot("entry %d is not an object" % n)
    missing = [f for f in FIELDS if f not in e]
    if missing:
        cannot("entry %d lacks %s" % (n, ", ".join(missing)))
    cmd, code = e["command"], e["exit_code"]
    if not isinstance(cmd, str):
        cannot("entry %d: command is not a string" % n)
    if isinstance(code, bool) or not isinstance(code, int) or not 0 <= code <= 255:
        cannot("entry %d: exit_code is not a whole number from 0 to 255" % n)
    for f in ("head_sha", "tree_hash"):
        if not isinstance(e[f], str) or not HEX.fullmatch(e[f]):
            cannot("entry %d: %s is not a full lowercase hex sha" % (n, f))
    if not isinstance(e["output_sha256"], str) or not re.fullmatch(r"[0-9a-f]{64}", e["output_sha256"]):
        cannot("entry %d: output_sha256 is not 64 lowercase hex digits" % n)
    tv = e["tool_versions"]
    if not isinstance(tv, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in tv.items()):
        cannot("entry %d: tool_versions is not an object of strings" % n)
    why = words_ok(cmd)
    if why:
        cannot("entry %d: command refused (%s); nothing was run" % (n, why))
    why = allowed(cmd.split())
    if why:
        cannot("entry %d: command %r refused (%s); nothing was run" % (n, cmd, why))
    entries.append((n, e))

# ---- the head and the tree ---------------------------------------------------------------------
for n, e in entries:
    h = e["head_sha"]
    rc, _ = git("cat-file", "-e", h + "^{commit}")
    if rc != 0:
        cannot("entry %d: head_sha %s is not a commit in %s" % (n, h, opt["repo"]))
    rc, tree = git("rev-parse", "--verify", "--quiet", h + "^{tree}")
    if rc != 0 or tree != e["tree_hash"]:
        cannot("entry %d: tree_hash %s is not the tree of %s (%s)" % (n, e["tree_hash"], h, tree or "none"))
    if opt["head"] is not None and h != opt["head"]:
        rc, _ = git("merge-base", "--is-ancestor", h, opt["head"])
        if rc != 0:
            cannot("entry %d: head_sha %s is neither the head %s nor an ancestor of it" % (n, h, opt["head"]))
if opt["head"] is None:
    say("no expected head (no --head, no --pr, no closure marker): heads are checked as commits only")

# ---- the sample ------------------------------------------------------------------------------
if opt["sample"] is not None and int(opt["sample"]) < len(entries):
    order = sorted(entries, key=lambda x: hashlib.sha256(("%s:%d" % (opt["seed"], x[0])).encode()).hexdigest())
    say("sample seed %s (repeat this pick with --seed %s)" % (opt["seed"], opt["seed"]))
    picked = {n for n, _ in order[:int(opt["sample"])]}
    entries = [x for x in entries if x[0] in picked]
say("re-running %d of %d entries: %s" % (len(entries), len(data), " ".join(str(n) for n, _ in entries)))

# ---- run -----------------------------------------------------------------------------------------
OUT_CAP = 64 * 1024 * 1024
work = tempfile.mkdtemp(prefix="proof-check-")
LIVE["work"] = work
clones, mismatch, failed = {}, 0, None
try:
    for n, e in entries:
        h = e["head_sha"]
        if h not in clones:
            d = os.path.join(work, "c%d" % len(clones))
            rc1, _ = git("clone", "-q", "--shared", "--no-checkout", opt["repo"], d)
            rc2, _ = git("checkout", "-q", "--detach", h, cwd=d) if rc1 == 0 else (1, "")
            if rc2 != 0:
                failed = "entry %d: the clean checkout at %s failed" % (n, h); break
            clones[h] = d
        home = tempfile.mkdtemp(dir=work, prefix="home-")
        # Only absolute PATH elements: a relative or empty one would find a bare program name inside
        # the checkout, which is the pull request's code.
        path = ":".join(x for x in os.environ.get("PATH", "/usr/bin:/bin").split(":") if x.startswith("/"))
        env = {"PATH": path or "/usr/bin:/bin", "HOME": home, "TMPDIR": home,
               "LANG": os.environ.get("LANG", "C"), "LC_ALL": os.environ.get("LC_ALL", "")}
        env = {k: v for k, v in env.items() if v}
        # Its own process group (session), output to a file: a child left in the background neither
        # holds the run open nor outlives it, and the whole group is killed when the command exits,
        # times out or prints past the cap. A child that starts a new session of its own escapes this.
        outp = os.path.join(work, "out-%d" % n)
        over = None
        with open(outp, "wb") as fo:
            try:
                p = subprocess.Popen(e["command"].split(), cwd=clones[h], env=env, stdin=subprocess.DEVNULL,
                                     stdout=fo, stderr=subprocess.STDOUT, start_new_session=True)
            except OSError as x:
                failed = "entry %d: %s could not start (%s)" % (n, e["command"], x.strerror); break
            LIVE["group"] = p.pid
            deadline = time.monotonic() + int(opt["timeout"])
            while p.poll() is None:
                if time.monotonic() >= deadline:
                    over = "timed out after %s s" % opt["timeout"]; break
                if os.path.getsize(outp) > OUT_CAP:
                    over = "printed more than %d MiB" % (OUT_CAP >> 20); break
                time.sleep(0.05)
            stop_group(p.pid)
            p.wait()
            LIVE["group"] = None
        if over is None and os.path.getsize(outp) > OUT_CAP:
            over = "printed more than %d MiB" % (OUT_CAP >> 20)
        if over:
            failed = "entry %d: %s %s" % (n, e["command"], over); break
        hs = hashlib.sha256()
        with open(outp, "rb") as fi:
            for chunk in iter(lambda: fi.read(1 << 20), b""):
                hs.update(chunk)
        os.unlink(outp)
        r = p
        got_hash = hs.hexdigest()
        tv = ", ".join("%s %s" % kv for kv in sorted(e["tool_versions"].items())) or "none"
        bad = []
        if r.returncode != e["exit_code"]:
            bad.append("exit %d, claimed %d" % (r.returncode, e["exit_code"]))
        if opt["check_output"] and got_hash != e["output_sha256"]:
            bad.append("output sha256 %s, claimed %s" % (got_hash[:12], e["output_sha256"][:12]))
        if bad:
            mismatch += 1
            say("entry %d MISMATCH: %s at %s: %s (claimed tools: %s)" % (n, e["command"], h[:12], "; ".join(bad), tv))
        else:
            say("entry %d match: %s at %s exit %d%s" % (n, e["command"], h[:12], r.returncode,
                ", output sha256 equal" if opt["check_output"] else ""))
finally:
    shutil.rmtree(work, ignore_errors=True)
if mismatch:
    say("%d of %d re-run entries did not match%s" % (mismatch, len(entries), ("; also " + failed) if failed else ""))
    sys.exit(1)
if failed:
    cannot(failed)
say("ok, %d of %d entries re-run, all match, head bound %s" % (len(entries), len(data),
    "%s (%s)" % (opt["head"][:12], head_from) if opt["head"] else "none (heads checked as commits only)"))
sys.exit(0)
PY
