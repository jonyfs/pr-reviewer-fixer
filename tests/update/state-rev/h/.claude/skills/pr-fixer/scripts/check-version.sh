#!/usr/bin/env bash
#
# check-version.sh: tells a person that a newer release of pr-reviewer and pr-fixer exists.
#
# It reads the installed version from `metadata.version` in the SKILL.md next to this script's
# folder, asks GitHub for the latest release, and prints one notice when the release is newer. It
# never downloads or installs anything: updating skills changes controlled configuration, so a
# person decides. The notice tells the agent to put one yes/no question to the person; on yes the
# agent runs `update.sh --yes` (next to this script), on no it runs `check-version.sh --decline`,
# which stops the notice for that release only. A newer release asks again.
#
# It must never get in the way of a review, so every failure path is silent and exits 0:
# offline, no python3, a 404, a rate limit, an unreadable version, a malformed answer.
#
# Skipped without any request when:
#   PR_SKILLS_NO_UPDATE_CHECK=1   the person opted out
#   CI=true or GITHUB_ACTIONS=true  automatic runs must not depend on the network for this
#
# Environment (all optional):
#   PR_SKILLS_RELEASE_URL   release API URL; default is the latest release of the upstream repo.
#                           Any URL curl understands works, which is how the tests feed a file.
#   PR_SKILLS_CACHE_DIR     where the answer is cached for 24 hours; default
#                           ${XDG_CACHE_HOME:-$HOME/.cache}/pr-reviewer-fixer
#
# Usage: check-version.sh [--installed | --latest | --decline]
#   (none)        print the notice when a newer release exists, nothing otherwise
#   --installed   print the installed version only, no network
#   --latest      print "<version> <release page>" of the latest release, read fresh from GitHub
#                 (the 24 hour cache is refreshed, not read); prints nothing when it cannot. Used by
#                 update.sh. Runs even when the opt-out variable or CI would silence the notice,
#                 since someone asked for it.
#   --decline     remember "no" for the latest release known now: the notice stays quiet until a
#                 newer one appears. Prints one line saying so, or that it could not record it.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL_MD="$HERE/../SKILL.md"
UPSTREAM="https://api.github.com/repos/jonyfs/pr-reviewer-fixer/releases/latest"
TTL=86400

command -v python3 >/dev/null 2>&1 || exit 0

installed="$(python3 -I - "$SKILL_MD" <<'PY' 2>/dev/null
import re, sys
try:
    text = open(sys.argv[1], encoding="utf-8").read()
except OSError:
    sys.exit(0)
m = re.match(r"---\n(.*?)\n---", text, re.S)
if m:
    v = re.search(r"^metadata:\s*\n(?:[ \t]+.*\n)*?[ \t]+version:\s*[\"']?(\d+\.\d+\.\d+)", m.group(1) + "\n", re.M)
    if v:
        print(v.group(1))
PY
)"

MODE=notice
case "${1:-}" in --installed) MODE=installed ;; --latest) MODE=latest ;; --decline) MODE=decline ;; esac

if [ "$MODE" = installed ]; then
  [ -n "$installed" ] && echo "$installed"
  exit 0
fi

if [ "$MODE" = notice ]; then
  [ -n "$installed" ] || exit 0
  [ "${PR_SKILLS_NO_UPDATE_CHECK:-}" = "1" ] && exit 0
  [ "${CI:-}" = "true" ] && exit 0
  [ "${GITHUB_ACTIONS:-}" = "true" ] && exit 0
fi

URL="${PR_SKILLS_RELEASE_URL:-$UPSTREAM}"
# No HOME and no XDG_CACHE_HOME (a bare container): run without a cache instead of failing.
if [ -n "${PR_SKILLS_CACHE_DIR:-}" ]; then CACHE_DIR="$PR_SKILLS_CACHE_DIR"
elif [ -n "${XDG_CACHE_HOME:-}" ]; then CACHE_DIR="$XDG_CACHE_HOME/pr-reviewer-fixer"
elif [ -n "${HOME:-}" ]; then CACHE_DIR="$HOME/.cache/pr-reviewer-fixer"
else CACHE_DIR=""; fi
CACHE="${CACHE_DIR:+$CACHE_DIR/latest}"

latest=""
now="$(date +%s)"
if [ "$MODE" != latest ] && [ -n "$CACHE" ] && [ -r "$CACHE" ]; then
  read -r stamp tag link <"$CACHE" 2>/dev/null || stamp=0
  case "$stamp" in ''|*[!0-9]*) stamp=0 ;; esac
  if [ $((now - stamp)) -lt "$TTL" ] && [ -n "${tag:-}" ]; then latest="$tag"; page="${link:-}"; fi
fi

if [ -z "$latest" ]; then
  command -v curl >/dev/null 2>&1 || exit 0
  body="$(curl -fsSL --max-time 5 -H 'Accept: application/vnd.github+json' "$URL" 2>/dev/null)" || exit 0
  parsed="$(printf '%s' "$body" | python3 -I -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(str(d.get("tag_name", "")).lstrip("v"), d.get("html_url", ""))
except Exception:
    pass
' 2>/dev/null)"
  latest="${parsed%% *}"
  page="${parsed#* }"
  [ -n "$latest" ] || exit 0
  [ -n "$CACHE" ] && mkdir -p "$CACHE_DIR" 2>/dev/null && printf '%s %s %s\n' "$now" "$latest" "$page" >"$CACHE" 2>/dev/null
fi

DECLINED="${CACHE_DIR:+$CACHE_DIR/declined}"
if [ "$MODE" = latest ]; then
  echo "$latest${page:+ $page}"
  exit 0
fi
if [ "$MODE" = decline ]; then
  if [ -n "$DECLINED" ] && mkdir -p "$CACHE_DIR" 2>/dev/null && printf '%s\n' "$latest" >"$DECLINED" 2>/dev/null; then
    echo "pr-skills: not asking again about version $latest; a newer release asks again."
  else
    echo "pr-skills: could not record the answer; you will be asked again." >&2
  fi
  exit 0
fi
if [ -n "$DECLINED" ] && [ -r "$DECLINED" ]; then
  read -r said <"$DECLINED" 2>/dev/null || said=""
  [ "$said" = "$latest" ] && exit 0
fi

newer="$(python3 -I - "$installed" "$latest" <<'PY' 2>/dev/null
import re, sys
def parse(v):
    m = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", v.strip())
    return tuple(int(x) for x in m.groups()) if m else None
a, b = parse(sys.argv[1]), parse(sys.argv[2])
print("yes" if a and b and b > a else "")
PY
)"
[ "$newer" = "yes" ] || exit 0

echo "pr-skills: version $latest is available, installed is $installed.${page:+ Release notes: $page}"
echo "  Updating changes the skills your agent follows, so a person decides. Ask the person one yes/no question with the harness's question form (in prose, if it has none) and wait for the answer."
echo "  Yes: bash $HERE/update.sh --yes    No: bash $HERE/check-version.sh --decline    Not answered: do neither."
echo "  Silence this check with PR_SKILLS_NO_UPDATE_CHECK=1."
exit 0
