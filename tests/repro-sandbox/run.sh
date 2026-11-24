#!/usr/bin/env bash
# Drives repro-sandbox.sh (the opt-in execution check for a CRITICAL candidate) and the optional
# `repro:` field that lint-report and findings-block read. No network and no GitHub access needed.
#
# The rows that run a repro need a working sandbox (sandbox-exec on macOS, bwrap on Linux).
# `repro-sandbox.sh --probe` decides: where it refuses, those rows print SKIP and the refusal rows
# still run. `unshare -rn` alone is never enough (PR 97 C3): runs are refused there too. Rows that
# only one platform can show (LaunchServices, the pasteboard and the keychain on macOS; the masked
# /run and /home under bwrap) print SKIP on the other one.
set -u
unset REVIEW_BLOCK_AT PUSH_GUARD_ALLOW_SENSITIVE REVIEW_REPRO REPRO_SANDBOX
T="$(cd "$(dirname "$0")" && pwd)"
SRC="$(cd "${1:-$T/../../.agents/skills/pr-reviewer/scripts}" && pwd)"
R="$SRC/repro-sandbox.sh"
RC="$SRC/review-cycle.sh"
W="$T/work-${TEST_TAG:-main}"
rm -rf "$W"; mkdir -p "$W/tmp"
W="$(cd "$W" && pwd -P)"
export TMPDIR="$W/tmp"
OS="$(uname -s)"
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
SLP="4$$.5"   # the setsid sleeper's argument, unique to this run
# Whatever a red run started is ended here: the LaunchServices entry of the probe app, the app
# itself, and the sleeper that left the run's session.
cleanup_probes() {
  local p
  if [ -x "$LSR" ] && [ -f "$W/app-path" ]; then
    while IFS= read -r p; do [ -n "$p" ] && "$LSR" -u "$p" >/dev/null 2>&1; done <"$W/app-path"
  fi
  pkill -KILL -f "pr97probe-$$" 2>/dev/null
  pkill -KILL -f "^/bin/sleep $SLP\$" 2>/dev/null
  return 0
}
trap cleanup_probes EXIT
PASS=0; FAIL=0; SKIP=0; ROWS=()
row() { if [ "$2" = ok ]; then PASS=$((PASS+1)); ROWS+=("PASS | $1"); else FAIL=$((FAIL+1)); ROWS+=("FAIL | $1 (${3:-})"); fi; }
skip() { SKIP=$((SKIP+1)); ROWS+=("SKIP | $1 ($2)"); }
# check <name> <command...>: the row passes when the command succeeds.
check() { local n="$1"; shift; if "$@"; then row "$n" ok; else row "$n" bad "rc=${r:-?}; out: $(head -c 400 "$W/out" 2>/dev/null)"; fi; }
has() { grep -qF -- "$1" "$2"; }

# ---- a fixture repository: the bug at the first commit, fixed at the second -----------------------
G=(env GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -c user.name=t -c user.email=t@e -c init.defaultBranch=main)
mkdir -p "$W/src"
"${G[@]}" -C "$W/src" init -q
printf 'echo "parsing an expired token"\nexit 1\n' >"$W/src/test.sh"
"${G[@]}" -C "$W/src" add test.sh; "${G[@]}" -C "$W/src" commit -qm bug
BUG="$("${G[@]}" -C "$W/src" rev-parse HEAD)"
printf 'exit 0\n' >"$W/src/test.sh"
"${G[@]}" -C "$W/src" commit -qam fix
FIX="$("${G[@]}" -C "$W/src" rev-parse HEAD)"
: >"$W/src/DIRTY"   # untracked in the working tree, so not in any commit
printf 'sh test.sh\n' >"$W/cmd-test.sh"
mkdir -p "$W/fakehome/.config/gh"; echo 'oauth_token: home-secret-value' >"$W/fakehome/.config/gh/hosts.yml"

# ---- rows that never run a repro --------------------------------------------------------------------
"$R" >"$W/out" 2>&1; r=$?
check "no arguments is a usage error, exit 2" eval '[ $r = 2 ] && has "usage:" "$W/out"'
"$R" --repo "$W/src" --sha "$BUG" --expect maybe --cmd-file "$W/cmd-test.sh" >"$W/out" 2>&1; r=$?
check "an --expect outside fail, crash, pass, exit=<n> is refused, exit 2" eval '[ $r = 2 ]'
"$R" --repo "$W/src" --sha "${BUG:0:12}" --expect fail --cmd-file "$W/cmd-test.sh" >"$W/out" 2>&1; r=$?
check "a short sha is refused, exit 2" eval '[ $r = 2 ]'
"$R" --repo "$W/src" --sha "$BUG" --expect fail --cmd-file "$W/cmd-test.sh" -- /bin/true >"$W/out" 2>&1; r=$?
check "--cmd-file and an argv together are refused, exit 2" eval '[ $r = 2 ]'
REVIEW_REPRO=1 REPRO_SANDBOX=none "$R" --probe >"$W/out" 2>&1; r=$?
check "an unknown REPRO_SANDBOX is refused, exit 2" eval '[ $r = 2 ]'
"$R" --repo "$W/src" --sha "$BUG" --expect fail --expect-log '' --cmd-file "$W/cmd-test.sh" >"$W/out" 2>&1; r=$?
check "an empty --expect-log is refused, exit 2" eval '[ $r = 2 ]'

# Opt-in: without REVIEW_REPRO=1 nothing runs, whatever the sandbox.
rm -f "$W/canary"
"$R" --repo "$W/src" --sha "$BUG" --expect fail -- /usr/bin/touch "$W/canary" >"$W/out" 2>&1; r=$?
check "opt-in off: skipped, exit 3, and the repro never ran" \
  eval '[ $r = 3 ] && has "repro: skipped (opt-in" "$W/out" && [ ! -e "$W/canary" ]'
REVIEW_REPRO=yes "$R" --repo "$W/src" --sha "$BUG" --expect fail -- /usr/bin/touch "$W/canary" >"$W/out" 2>&1; r=$?
check "opt-in takes exactly 1, not another value" eval '[ $r = 3 ] && [ ! -e "$W/canary" ]'

# No sandbox: the backend this platform lacks stands for a host with none (the backends are called by
# fixed paths, so a PATH without them no longer hides them).
if [ "$OS" = Darwin ]; then NOSB=bwrap; else NOSB=sandbox-exec; fi
REVIEW_REPRO=1 REPRO_SANDBOX="$NOSB" "$R" --repo "$W/src" --sha "$BUG" --expect fail \
  -- /usr/bin/touch "$W/canary" >"$W/out" 2>"$W/err"; r=$?
check "no sandbox ($NOSB on $OS): refused with exit 4, the message, and the repro never ran" \
  eval '[ $r = 4 ] && has "no network sandbox here; repro skipped" "$W/err" && has "repro: skipped (no network sandbox)" "$W/out" && [ ! -e "$W/canary" ]'
REPRO_SANDBOX="$NOSB" "$R" --probe >"$W/out" 2>"$W/err"; r=$?
check "--probe with no sandbox: exit 4 and the refusal" eval '[ $r = 4 ] && has "no network sandbox here" "$W/err"'

# C3: `unshare -rn` confines neither reads nor writes, so it is never a backend for a run. A
# pass-through stub on PATH stands for a working one (and for the caller's PATH steering the choice).
mkdir -p "$W/stub"
# (/bin/true, which the old probe ran, is /usr/bin/true on macOS.)
printf '#!/bin/sh\necho used >>"%s/stub-used"\nwhile [ $# -gt 0 ]; do case "$1" in -r|-n|-rn|-nr) shift ;; *) break ;; esac; done\n[ "$1" = /bin/true ] && exit 0\nexec "$@"\n' "$W" >"$W/stub/unshare"
chmod +x "$W/stub/unshare"
rm -f "$W/canary" "$W/stub-used"
PATH="$W/stub:$PATH" REVIEW_REPRO=1 REPRO_SANDBOX=unshare "$R" --repo "$W/src" --sha "$BUG" --expect fail \
  -- /usr/bin/touch "$W/canary" >"$W/out" 2>"$W/err"; r=$?
check "C3: the unshare backend is refused for a run, exit 4, and the repro never ran" \
  eval '[ $r = 4 ] && has "repro: skipped (no network sandbox)" "$W/out" && [ ! -e "$W/canary" ]'

# N2: the backend is called by a fixed path, never found through the caller's PATH.
rm -f "$W/stub/unshare"
printf '#!/bin/sh\necho used >>"%s/stub-used"\nwhile [ $# -gt 0 ]; do case "$1" in -p|-f|-D) shift 2 ;; --*) shift ;; *) break ;; esac; done\nexec "$@"\n' "$W" >"$W/stub/sandbox-exec"
cp "$W/stub/sandbox-exec" "$W/stub/bwrap"; chmod +x "$W/stub/sandbox-exec" "$W/stub/bwrap"
rm -f "$W/stub-used"
PATH="$W/stub:$PATH" REVIEW_REPRO=1 "$R" --repo "$W/src" --sha "$FIX" --expect pass -- /bin/true >"$W/out" 2>"$W/err"; r=$?
check "N2: a sandbox-exec or bwrap first on PATH is never used" eval '[ ! -e "$W/stub-used" ]'
rm -rf "$W/stub"

# N2: a home that does not resolve to a folder is refused before anything runs.
rm -f "$W/canary"
HOME="$W/no-such-home" REVIEW_REPRO=1 "$R" --repo "$W/src" --sha "$BUG" --expect fail \
  -- /usr/bin/touch "$W/canary" >"$W/out" 2>"$W/err"; r=$?
check "N2: a HOME that is not a folder is refused, exit 2, and the repro never ran" \
  eval '[ $r = 2 ] && has "HOME" "$W/err" && [ ! -e "$W/canary" ]'
( unset HOME; REVIEW_REPRO=1 "$R" --repo "$W/src" --sha "$BUG" --expect fail \
  -- /usr/bin/touch "$W/canary" >"$W/out" 2>"$W/err" ); r=$?
check "N2: an unset HOME is refused, exit 2, and the repro never ran" eval '[ $r = 2 ] && [ ! -e "$W/canary" ]'

# ---- lint-report and findings-block: the optional `repro:` field -------------------------------------
printf 'diff --git a/src/a.ts b/src/a.ts\n--- a/src/a.ts\n+++ b/src/a.ts\n@@ -1 +11,2 @@\n x\n+y\n' >"$W/d.patch"
: >"$W/nofloor.z"
# rep <file> <repro line or empty> [status]
rep() {
  { printf 'Declined to judge: none\nReview mode: single session\n\n```findings\nversion: 1\n'
    if [ "${3:-open}" = not-applicable ]; then printf 'counts: {critical: 0, warning: 0, note: 0}\n'
    else printf 'counts: {critical: 1, warning: 0, note: 0}\n'; fi
    printf 'mandatory_units: []\nfindings:\n  - id: C1\n    severity: CRITICAL\n    status: %s\n    file: src/a.ts\n    line: 11\n' "${3:-open}"
    printf '    claim: "Expired token accepted"\n    failure_scenario: "an expired token returns 200"\n'
    [ -z "$2" ] || printf '    repro: %s\n' "$2"
    printf '```\n'; } >"$1"
}
# review-cycle.sh checks that gh exists before any command; these rows never call it (the diff and the
# file list are files), so a stub that fails stands in for it.
mkdir -p "$W/bin"; printf '#!/bin/sh\nexit 1\n' >"$W/bin/gh"; chmod +x "$W/bin/gh"
RC() { PATH="$W/bin:$PATH" "$RC" "$@"; }
lint() { RC lint-report --report "$1" --diff "$W/d.patch" --files "$W/nofloor.z" >"$W/out" 2>&1; }
for v in reproduced not-reproduced skipped '"reproduced"'; do
  rep "$W/r.md" "$v"; lint "$W/r.md"; r=$?
  check "lint-report accepts repro: $v" eval '[ $r = 0 ]'
done
for v in maybe REPRODUCED 'reproduced yes'; do
  rep "$W/r.md" "$v"; lint "$W/r.md"; r=$?
  check "lint-report refuses repro: $v" eval '[ $r = 1 ] && has "is not one of reproduced, not-reproduced, skipped" "$W/out"'
done
rep "$W/r.md" maybe not-applicable; lint "$W/r.md"; r=$?
check "lint-report refuses a bad repro value on a not-applicable entry too" eval '[ $r = 1 ] && has "repro \`maybe\`" "$W/out"'
printf 'Declined to judge: none\nReview mode: single session\n\n```findings\nversion: 1\ncounts: {critical: 1, warning: 0, note: 0}\nfindings:\n  - id: C1\n    severity: CRITICAL\n    file: src/a.ts\n    line: 11\n    repro:\n```\n' >"$W/r.md"
lint "$W/r.md"; r=$?
check "lint-report refuses an empty repro:" eval '[ $r = 1 ] && has "repro \`\`" "$W/out"'
rep "$W/old.md" ""; lint "$W/old.md"; r=$?
check "an old report with no repro field still passes lint-report" eval '[ $r = 0 ] && has "lint-report: ok. 1 finding" "$W/out"'
RC findings-block --report "$W/old.md" >"$W/fb.json" 2>"$W/out"; r=$?
check "findings-block: an old report's entry has no repro key" eval '[ $r = 0 ] && jq -e ".entries[0] | has(\"repro\") | not" "$W/fb.json" >/dev/null'
rep "$W/r.md" not-reproduced; RC findings-block --report "$W/r.md" >"$W/fb.json" 2>"$W/out"; r=$?
check "findings-block prints repro as written" eval '[ $r = 0 ] && jq -e ".entries[0].repro == \"not-reproduced\"" "$W/fb.json" >/dev/null'

# ---- rows that run a repro in the sandbox ------------------------------------------------------------
"$R" --probe >"$W/probe" 2>&1; prc=$?
BACKEND="$(sed -n 's/^sandbox: \([a-z-]*\) .*/\1/p' "$W/probe")"
sb() { REVIEW_REPRO=1 "$R" --repo "$W/src" --timeout "${TOUT:-60}" --log "$W/log" "$@" >"$W/out" 2>&1; }
if [ "$prc" != 0 ]; then
  for n in reproduced not-reproduced clone-at-sha git-inside env network-local network-public write-outside \
           home-read python3-clt python3-path launchservices pasteboard keychain run-masked log-symlink log-fifo \
           expect-log-unchecked expect-log-checked sandbox-abort ulimit-kill timeout setsid-survivor nproc-cap \
           no-interpolation argv-file-name exit-127 crash exit-n no-scratch-left; do
    skip "sandboxed row $n" "no sandbox on this host: $(head -n 1 "$W/probe")"
  done
else
  check "--probe names the backend and its level ($(cat "$W/probe"))" eval 'grep -qE "^sandbox: (sandbox-exec|bwrap) net\+write$" "$W/probe"'
  sb --sha "$BUG" --expect fail --cmd-file "$W/cmd-test.sh"; r=$?
  check "reproduced: the failing test at the buggy head exits 0 with repro: reproduced" \
    eval '[ $r = 0 ] && has "repro: reproduced" "$W/out" && has "parsing an expired token" "$W/log"'
  sb --sha "$FIX" --expect fail --cmd-file "$W/cmd-test.sh"; r=$?
  check "not-reproduced: the same test at the fixed head exits 1" eval '[ $r = 1 ] && has "repro: not-reproduced" "$W/out"'
  sb --sha "$FIX" --expect pass -- /bin/sh -c 'test -e test.sh && test ! -e DIRTY'; r=$?
  check "the repro runs in a clone at the sha, not in the caller's working tree" eval '[ $r = 0 ]'
  sb --sha "$FIX" --expect pass -- /bin/sh -c 'git rev-parse HEAD'; r=$?
  check "git runs inside the sandbox and sees the clone at the sha" eval '[ $r = 0 ] && has "$FIX" "$W/log"'

  # The environment is empty: only the names the script sets (and what the shell or the OS adds).
  GH_TOKEN=tok-secret-value GITHUB_TOKEN=tok-secret-value SSH_AUTH_SOCK=/tmp/agent.sock \
    GIT_ASKPASS=/usr/bin/caller-helper sb --sha "$FIX" --expect pass -- /usr/bin/env; r=$?
  extra="$(sed -n 's/=.*//p' "$W/log" | grep -vxE 'PATH|HOME|TMPDIR|LANG|LC_ALL|GIT_CONFIG_NOSYSTEM|GIT_CONFIG_GLOBAL|GIT_TERMINAL_PROMPT|GIT_ASKPASS|GIT_SSH_COMMAND|PWD|OLDPWD|SHLVL|_|__CF_USER_TEXT_ENCODING')"
  check "env is empty: no GH_TOKEN, no SSH_AUTH_SOCK, no caller variable at all" \
    eval '[ $r = 0 ] && has "PATH=" "$W/log" && [ -z "$extra" ] && ! has "tok-secret-value" "$W/log" && ! has "agent.sock" "$W/log" && ! has "caller-helper" "$W/log"'
  check "HOME and TMPDIR are inside the scratch folder" \
    eval 'grep -qE "^HOME=$W/tmp/" "$W/log" && grep -qE "^TMPDIR=$W/tmp/" "$W/log"'

  # Network: a listener on 127.0.0.1 outside the sandbox; the control connects, the repro cannot.
  python3 -I -c '
import socket, sys
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(8)
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
s.settimeout(120)
n = 0
try:
    while True:
        c, _ = s.accept(); n += 1; open(sys.argv[2], "w").write(str(n)); c.close()
except Exception:
    pass' "$W/port" "$W/hits" &
LPID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$W/port" ] && break; sleep 0.2; done
  PORT="$(cat "$W/port" 2>/dev/null)"
  bash -c 'exec 3<>/dev/tcp/127.0.0.1/'"$PORT" 2>/dev/null; ctl=$?
  for _ in 1 2 3 4 5; do [ -s "$W/hits" ] && break; sleep 0.2; done
  before="$(cat "$W/hits" 2>/dev/null || echo 0)"
  printf 'exec 3<>/dev/tcp/127.0.0.1/%s && echo CONNECTED\n' "$PORT" >"$W/cmd-net.sh"
  sb --sha "$FIX" --expect pass --cmd-file "$W/cmd-net.sh"; r=$?
  sleep 0.5; after="$(cat "$W/hits" 2>/dev/null || echo 0)"
  kill "$LPID" 2>/dev/null; wait "$LPID" 2>/dev/null
  check "network blocked: the control connects to 127.0.0.1, the repro does not" \
    eval '[ "$ctl" = 0 ] && [ "$before" -ge 1 ] && [ $r = 1 ] && ! has CONNECTED "$W/log" && [ "$after" = "$before" ]'
  printf 'exec 3<>/dev/tcp/1.1.1.1/80 && echo CONNECTED\n' >"$W/cmd-net2.sh"
  TOUT=20 sb --sha "$FIX" --expect pass --cmd-file "$W/cmd-net2.sh"; r=$?
  check "network blocked: a connect to 1.1.1.1 fails inside" eval '[ $r = 1 ] && ! has CONNECTED "$W/log"'

  sb --sha "$FIX" --expect pass -- /bin/sh -c 'echo x >"$1"' sh "$W/outside.txt"; r=$?
  check "a write outside the scratch folder is denied" eval '[ $r = 1 ] && [ ! -e "$W/outside.txt" ]'
  HOME="$W/fakehome" sb --sha "$FIX" --expect pass -- /bin/cat "$W/fakehome/.config/gh/hosts.yml"; r=$?
  check "the caller's home is not readable inside" eval '[ $r = 1 ] && ! has "home-secret-value" "$W/log"'

  # A test in the usual runtimes still runs (PR 97 C1: the profile allows reads, never services).
  if [ -x /usr/bin/python3 ]; then
    sb --sha "$FIX" --expect pass -- /usr/bin/python3 -I -c 'print(6*7)'; r=$?
    check "/usr/bin/python3 runs inside" eval '[ $r = 0 ] && has 42 "$W/log"'
  else skip "/usr/bin/python3 runs inside" "no /usr/bin/python3"; fi
  sb --sha "$FIX" --expect pass -- /bin/sh -c 'python3 -I -c "import json, subprocess; print(6*7)"'; r=$?
  check "the python3 the repro's PATH finds first runs inside" eval '[ $r = 0 ] && has 42 "$W/log"'

  # C1 (macOS): no LaunchServices, pasteboard or keychain service is reachable from inside.
  if [ "$BACKEND" = sandbox-exec ]; then
    rm -f "$W/app-canary" "$W/app-path"
    # The repro builds a two-line app in its own folder and asks LaunchServices to start it; launchd
    # would run it outside the sandbox, where it writes the canary. Only the exit codes reach the log.
    cat >"$W/cmd-app.sh" <<EOF
A="\$PWD/pr97probe-$$.app"
mkdir -p "\$A/Contents/MacOS"
printf '#!/bin/sh\\necho ran >"%s"\\n' "$W/app-canary" >"\$A/Contents/MacOS/pr97probe-$$"
chmod +x "\$A/Contents/MacOS/pr97probe-$$"
printf '<?xml version="1.0" encoding="UTF-8"?>\\n<plist version="1.0"><dict><key>CFBundleExecutable</key><string>pr97probe-$$</string><key>CFBundleIdentifier</key><string>invalid.pr97probe.t$$</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>\\n' >"\$A/Contents/Info.plist"
echo "app-path=\$A"
open -g "\$A" >/dev/null 2>&1; echo "open-rc=\$?"
sleep 3
EOF
    sb --sha "$FIX" --expect pass --cmd-file "$W/cmd-app.sh"; r=$?
    sed -n 's/^app-path=//p' "$W/log" >"$W/app-path"
    sleep 2
    check "C1: open -g of an app the repro built fails inside and the app never runs" \
      eval '! grep -q "^open-rc=0$" "$W/log" && [ ! -e "$W/app-canary" ]'
    cleanup_probes
    # Only exit codes go to the log: the pasteboard and the keychain list never reach it.
    sb --sha "$FIX" --expect pass -- /bin/sh -c 'pbpaste >/dev/null 2>&1; echo "pb-rc=$?"'; r=$?
    check "C1: pbpaste fails inside" eval 'grep -q "^pb-rc=" "$W/log" && ! grep -q "^pb-rc=0$" "$W/log"'
    sb --sha "$FIX" --expect pass -- /bin/sh -c 'security list-keychains >/dev/null 2>&1; echo "sec-rc=$?"'; r=$?
    check "C1: security list-keychains fails inside" eval 'grep -q "^sec-rc=" "$W/log" && ! grep -q "^sec-rc=0$" "$W/log"'
  else
    for n in "C1: open -g of an app the repro built fails inside" "C1: pbpaste fails inside" "C1: security list-keychains fails inside"; do
      skip "$n" "macOS services, backend $BACKEND"; done
  fi
  if [ "$BACKEND" = bwrap ]; then
    sb --sha "$FIX" --expect pass -- /bin/sh -c 'ls -A /run /var/run /home'; r=$?
    check "C3: /run, /var/run and /home are empty inside bwrap (no host socket)" \
      eval '[ $r = 0 ] && [ -z "$(grep -v ":$" "$W/log" | grep -v "^$")" ]'
  else
    skip "C3: /run, /var/run and /home are empty inside bwrap" "bwrap only, backend $BACKEND"
  fi

  # C2: the repro cannot reach the script's own copy of its output. It replaces every out.log a few
  # levels up with a symlink to a home file, then with a FIFO; the log never holds the file and the
  # script still ends.
  printf 'for p in ../out.log ../../out.log ../../../out.log; do rm -f "$p"; ln -s "%s" "$p"; done; echo replaced\n' \
    "$W/fakehome/.config/gh/hosts.yml" >"$W/cmd-ln.sh"
  start=$SECONDS
  HOME="$W/fakehome" TOUT=10 timeout 90 env REVIEW_REPRO=1 "$R" --repo "$W/src" --timeout 10 --log "$W/log" \
    --sha "$FIX" --expect pass --cmd-file "$W/cmd-ln.sh" >"$W/out" 2>&1; r=$?
  check "C2: a symlink in place of the log copies no home file into --log" \
    eval '[ $r != 124 ] && ! has "home-secret-value" "$W/log" && ! has "home-secret-value" "$W/out"'
  printf 'for p in ../out.log ../../out.log ../../../out.log; do rm -f "$p"; mkfifo "$p"; done; echo replaced\n' >"$W/cmd-fifo.sh"
  start=$SECONDS
  timeout 90 env REVIEW_REPRO=1 "$R" --repo "$W/src" --timeout 10 --log "$W/log" \
    --sha "$FIX" --expect pass --cmd-file "$W/cmd-fifo.sh" >"$W/out" 2>&1; r=$?
  el=$((SECONDS - start))
  check "C2: a FIFO in place of the log does not hang the script (ended in ${el}s)" \
    eval '[ $r != 124 ] && has "repro: " "$W/out" && [ "$el" -lt 60 ]'

  # W1: an infrastructure failure is never evidence. A missing dependency reads as reproduced under
  # --expect fail alone (documented); --expect-log turns it into not-reproduced.
  sb --sha "$FIX" --expect fail -- /bin/sh -c 'python3 -I -c "import no_such_dep_pr97"'; r=$?
  check "W1: --expect fail alone counts a ModuleNotFoundError as reproduced (documented: pair it with --expect-log)" \
    eval '[ $r = 0 ] && has "repro: reproduced" "$W/out" && has "ModuleNotFoundError" "$W/log"'
  sb --sha "$FIX" --expect fail --expect-log "parsing an expired token" -- /bin/sh -c 'python3 -I -c "import no_such_dep_pr97"'; r=$?
  check "W1: with --expect-log the same failure is not-reproduced" eval '[ $r = 1 ] && has "repro: not-reproduced" "$W/out"'
  sb --sha "$BUG" --expect fail --expect-log "parsing an expired token" --cmd-file "$W/cmd-test.sh"; r=$?
  check "W1: with --expect-log the real failure is reproduced" eval '[ $r = 0 ] && has "repro: reproduced" "$W/out"'
  if [ "$BACKEND" = sandbox-exec ]; then
    # HOME=/ hides every path from the sandbox, so sandbox-exec cannot even start the wrapper.
    HOME=/ sb --sha "$FIX" --expect fail -- /bin/sh -c 'exit 1'; r=$?
    check "W1: a sandbox that aborts before the repro starts is skipped, never reproduced" \
      eval '[ $r = 3 ] && has "repro: skipped" "$W/out" && ! has "repro: reproduced" "$W/out"'
  else
    skip "W1: a sandbox that aborts before the repro starts is skipped" "the HOME=/ trigger is sandbox-exec only"
  fi
  sb --sha "$FIX" --expect crash -- /bin/sh -c 'kill -XFSZ $$'; r=$?
  check "W1: a death by SIGXFSZ (the file-size limit) is skipped, not a crash" eval '[ $r = 3 ] && has "repro: skipped" "$W/out"'

  TOUT=2 sb --sha "$FIX" --expect fail -- /bin/sleep 30; r=$?
  check "timeout gives skipped, exit 3" eval '[ $r = 3 ] && has "repro: skipped (timeout" "$W/out"'

  # W2: a process that leaves the run's session does not outlive the script.
  TOUT=10 sb --sha "$FIX" --expect pass -- /usr/bin/perl -MPOSIX -e 'fork and exit; POSIX::setsid(); exec "/bin/sleep", $ARGV[0]' "$SLP"; r=$?
  sleep 1
  check "W2: a setsid sleeper does not outlive the script" eval '! pgrep -f "^/bin/sleep $SLP\$" >/dev/null'
  cleanup_probes
  # The cap is the uid's current process count plus a margin, so it is lower than the caller's own.
  outer_nproc="$(ulimit -u)"
  sb --sha "$FIX" --expect pass -- /bin/sh -c 'ulimit -u'; r=$?
  inner_nproc="$(head -n 1 "$W/log")"
  check "W2: the repro runs under a lower process-count cap ($inner_nproc, caller $outer_nproc)" \
    eval '[ $r = 0 ] && [[ "$inner_nproc" =~ ^[0-9]+$ ]] && { [ "$outer_nproc" = unlimited ] || [ "$inner_nproc" -lt "$outer_nproc" ]; }'

  # The command is argv or a file, never a string the script builds: $(...) and spaces stay text.
  ( cd "$W" && sb --sha "$FIX" --expect pass -- /bin/echo '$(touch pwned)' 'a  b;touch pwned2' ); r=$?
  check "no interpolation: argv with \$(...) and ; is printed, not run" \
    eval '[ $r = 0 ] && has "\$(touch pwned) a  b;touch pwned2" "$W/log" && [ ! -e "$W/pwned" ] && [ ! -e "$W/pwned2" ] && [ -z "$(find "$W" -name "pwned*")" ]'
  f="$W/my \$(touch pwned3) repro.sh"; printf 'echo file-ran\n' >"$f"
  sb --sha "$FIX" --expect pass --cmd-file "$f"; r=$?
  check "no interpolation: a --cmd-file name with \$(...) and spaces is a path" \
    eval '[ $r = 0 ] && has "file-ran" "$W/log" && [ -z "$(find "$W" -name "pwned3*" ! -name "my*")" ]'

  sb --sha "$FIX" --expect fail -- no-such-command-here; r=$?
  check "exit 127 (command not found) is skipped, never reproduced" eval '[ $r = 3 ] && has "repro: skipped (exit 127" "$W/out"'
  sb --sha "$FIX" --expect crash -- /bin/sh -c 'kill -SEGV $$'; r=$?
  check "--expect crash: a signal death is reproduced" eval '[ $r = 0 ] && has "repro: reproduced" "$W/out"'
  sb --sha "$FIX" --expect crash -- /bin/sh -c 'exit 1'; r=$?
  check "--expect crash: a plain failure is not-reproduced" eval '[ $r = 1 ]'
  sb --sha "$FIX" --expect exit=3 -- /bin/sh -c 'exit 3'; r=$?
  check "--expect exit=3 matches exit 3" eval '[ $r = 0 ] && has "repro: reproduced (exit 3" "$W/out"'
  sb --sha "$FIX" --expect exit=3 -- /bin/sh -c 'exit 4'; r=$?
  check "--expect exit=3 does not match exit 4" eval '[ $r = 1 ]'
  check "every scratch clone is removed" eval '[ -z "$(ls -A "$W/tmp")" ]'
fi

for x in "${ROWS[@]}"; do echo "$x"; done
echo "repro-sandbox: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" = 0 ]
