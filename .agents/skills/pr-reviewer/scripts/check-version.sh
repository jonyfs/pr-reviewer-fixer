#!/usr/bin/env bash
#
# check-version.sh: tells a person that a newer release of pr-reviewer and pr-fixer exists.
#
# It reads the installed version from `metadata.version` in the SKILL.md next to this script's
# folder, asks GitHub for the latest release, and prints one notice when the release is newer. It
# never downloads or installs anything: updating skills changes controlled configuration, so a
# person decides. The notice tells the agent to put one yes/no question to the person; on yes the
# agent runs `update.sh --yes --version X.Y.Z` (next to this script), on no it runs
# `check-version.sh --decline`, which stops the notice for that release only. A newer release asks
# again.
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
#                           It only changes which version is read. When it is set, the notice says
#                           so, and update.sh refuses to run unless the person allowed that source
#                           (update.sh --allow-custom-source).
#   PR_SKILLS_DOWNLOAD_URL  only read here to warn that it is set (update.sh uses it).
#   PR_SKILLS_CACHE_DIR     where the answer is cached for 24 hours; default
#                           ${XDG_CACHE_HOME:-$HOME/.cache}/pr-reviewer-fixer
#
# What the notice prints from the network is checked first: the version must be X.Y.Z and the
# release page must be one https://github.com/jonyfs/pr-reviewer-fixer/... address with no space,
# control character or `..` segment, else it prints no link. The same check applies to the cache
# file. A source variable is shown as scheme and host only (a file:// one as `file://`), never with
# its user, password, path, query or fragment: a mirror URL can hold a token or a signature, and
# the notice goes to the agent's transcript.
#
# Usage: check-version.sh [--installed | --latest | --decline [X.Y.Z]]
#   (none)        print the notice when a newer release exists, nothing otherwise
#   --installed   print the installed version only, no network
#   --latest      print "<version> <release page>" of the latest release, read fresh from GitHub
#                 (the 24 hour cache is refreshed, not read); prints nothing when it cannot. Used by
#                 update.sh. Runs even when the opt-out variable or CI would silence the notice,
#                 since someone asked for it.
#   --decline     remember "no" for the release X.Y.Z the notice named (or, with no argument, the
#                 latest release known now): the notice stays quiet until a newer one appears.
#                 Prints one line either way: that it stopped asking, or that it could not
#                 record the answer (offline with no version given, no cache directory).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL_MD="$HERE/../SKILL.md"
UPSTREAM="https://api.github.com/repos/jonyfs/pr-reviewer-fixer/releases/latest"
TTL=86400

MODE=notice
case "${1:-}" in --installed) MODE=installed ;; --latest) MODE=latest ;; --decline) MODE=decline ;; esac

if ! command -v python3 >/dev/null 2>&1; then
  [ "$MODE" = decline ] && echo "pr-skills: could not record the answer" \
    "(python3 is not installed); you will be asked again." >&2
  exit 0
fi

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

VERSION_RE='^[0-9]+\.[0-9]+\.[0-9]+$'
PAGE_RE='^https://github\.com/jonyfs/pr-reviewer-fixer(/[A-Za-z0-9._~%+/-]*)?$'
DOTS_RE='(^|/)(\.|%2[eE]){2}(/|$)'   # a `..` segment, also percent-encoded
page_ok() { [[ "$1" =~ $PAGE_RE ]] && ! [[ "$1" =~ $DOTS_RE ]]; }

# <scheme>://<host[:port]> of a URL and nothing else, safe to print.
url_host() {
  local u scheme rest auth
  u="$(printf '%s' "$1" | tr -cd '[:print:]')"
  case "$u" in *://*) ;; *) echo "(not a URL)"; return 0 ;; esac
  scheme="$(printf '%s' "${u%%://*}" | tr 'A-Z' 'a-z')"
  [[ "$scheme" =~ ^[a-z][a-z0-9+.-]*$ ]] || { echo "(not a URL)"; return 0; }
  rest="${u#*://}"; auth="${rest%%[/?#]*}"; auth="${auth##*@}"
  if [ "$scheme" = file ] && [ -z "$auth" ]; then echo "file://"; return 0; fi
  if [[ "$auth" =~ ^([A-Za-z0-9.-]+|\[[0-9A-Fa-f:.]+\])(:[0-9]{1,5})?$ ]]; then
    echo "$scheme://$auth"
  else
    echo "$scheme://(host not readable)"
  fi
}

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
# curl is held to https for an https address (the redirects too); a file:// address is a test's.
CURL_PROTO=()
case "$URL" in https://*) CURL_PROTO=(--proto '=https' --proto-redir '=https') ;; esac
# No HOME and no XDG_CACHE_HOME (a bare container): run without a cache instead of failing.
if [ -n "${PR_SKILLS_CACHE_DIR:-}" ]; then CACHE_DIR="$PR_SKILLS_CACHE_DIR"
elif [ -n "${XDG_CACHE_HOME:-}" ]; then CACHE_DIR="$XDG_CACHE_HOME/pr-reviewer-fixer"
elif [ -n "${HOME:-}" ]; then CACHE_DIR="$HOME/.cache/pr-reviewer-fixer"
else CACHE_DIR=""; fi
CACHE="${CACHE_DIR:+$CACHE_DIR/latest}"
DECLINED="${CACHE_DIR:+$CACHE_DIR/declined}"

record_decline() { # <version>
  if [ -n "$DECLINED" ] && mkdir -p "$CACHE_DIR" 2>/dev/null \
     && printf '%s\n' "$1" >"$DECLINED" 2>/dev/null; then
    echo "pr-skills: not asking again about version $1; a newer release asks again."
  else
    echo "pr-skills: could not record the answer; you will be asked again." >&2
  fi
}
# The latest release could not be read: silent, except that --decline says it recorded nothing.
no_answer() {
  [ "$MODE" = decline ] && echo "pr-skills: could not record the answer (the latest release" \
    "could not be read); you will be asked again." >&2
  exit 0
}
# A version given to --decline is the one the notice named; no network is needed for it.
if [ "$MODE" = decline ] && [ -n "${2:-}" ]; then
  if [[ "$2" =~ $VERSION_RE ]]; then record_decline "$2"
  else
    echo "pr-skills: '$(printf '%s' "$2" | tr -cd '[:print:]')' is not a version;" \
      "could not record the answer." >&2
  fi
  exit 0
fi

latest=""
now="$(date +%s)"
if [ "$MODE" != latest ] && [ -n "$CACHE" ] && [ -r "$CACHE" ]; then
  read -r stamp tag link <"$CACHE" 2>/dev/null || stamp=0
  case "$stamp" in ''|*[!0-9]*) stamp=0 ;; esac
  if [ $((now - stamp)) -lt "$TTL" ] && [[ "${tag:-}" =~ $VERSION_RE ]]; then
    latest="$tag"; page="${link:-}"
  fi
fi

if [ -z "$latest" ]; then
  command -v curl >/dev/null 2>&1 || no_answer
  body="$(curl -fsSL ${CURL_PROTO[@]+"${CURL_PROTO[@]}"} --max-time 5 \
    -H 'Accept: application/vnd.github+json' "$URL" 2>/dev/null)" || no_answer
  field() { # <name>: one field of the answer; a bad one is checked below, never printed raw
    printf '%s' "$body" | python3 -I -c '
import json, sys
try:
    v = json.load(sys.stdin).get(sys.argv[1], "")
    print(v if isinstance(v, str) else "")
except Exception:
    pass
' "$1" 2>/dev/null
  }
  latest="$(field tag_name)"; latest="${latest#v}"
  [[ "$latest" =~ $VERSION_RE ]] || no_answer
  page="$(field html_url)"; page_ok "$page" || page=""
  [ -n "$CACHE" ] && mkdir -p "$CACHE_DIR" 2>/dev/null && printf '%s %s %s\n' "$now" "$latest" "$page" >"$CACHE" 2>/dev/null
fi

page_ok "$page" || page=""
if [ "$MODE" = latest ]; then
  echo "$latest${page:+ $page}"
  exit 0
fi
if [ "$MODE" = decline ]; then
  record_decline "$latest"
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

qhere="$(printf '%q' "$HERE")"
repo="https://github.com/jonyfs/pr-reviewer-fixer/releases/download/v$latest"
echo "pr-skills: version $latest is available, installed is $installed.${page:+ Release notes: $page}"
echo "  Updating changes the skills your agent follows, so a person decides. Ask the person one yes/no question with the harness's question form (in prose, if it has none) and wait for the answer. Name in it: both versions, where the code comes from, and that local edits inside the installed skill folders are replaced."
if [ -z "${PR_SKILLS_DOWNLOAD_URL:-}" ]; then
  echo "  The code comes from $repo/pr-reviewer-fixer-$latest.tar.gz," \
    "checked against the SHA256SUMS of that release."
else
  echo "  The code does not come from the upstream release: see the WARNING below for its source."
fi
if [ -n "${PR_SKILLS_RELEASE_URL:-}" ]; then
  echo "  WARNING: PR_SKILLS_RELEASE_URL is set (host $(url_host "$PR_SKILLS_RELEASE_URL"))," \
    "so the version above was read from there, not from the upstream release answer. update.sh" \
    "refuses to run while it is set, unless it is given --allow-custom-source. Tell the person," \
    "and add that flag only if the yes was for that source."
fi
if [ -n "${PR_SKILLS_DOWNLOAD_URL:-}" ]; then
  echo "  WARNING: PR_SKILLS_DOWNLOAD_URL is set (host $(url_host "$PR_SKILLS_DOWNLOAD_URL"))," \
    "so the archive and its SHA256SUMS would come from there, both from the same place." \
    "update.sh refuses to run while it is set, unless it is given --allow-custom-source. Tell" \
    "the person, and add that flag only if the yes was for that source."
fi
echo "  Yes: bash $qhere/update.sh --yes --version $latest" \
  "   No: bash $qhere/check-version.sh --decline $latest    Not answered: do neither."
echo "  Silence this check with PR_SKILLS_NO_UPDATE_CHECK=1."
exit 0
