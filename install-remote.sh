#!/usr/bin/env bash
#
# install-remote.sh: install pr-reviewer, pr-fixer and pr-merge-fixer from a GitHub release.
#
# Use it when you have no clone of the repository:
#
#   curl -fsSLO https://raw.githubusercontent.com/jonyfs/pr-reviewer-fixer/main/install-remote.sh
#   bash install-remote.sh                       # shows the plan, changes nothing
#   bash install-remote.sh --harness auto --yes  # installs where it finds a harness
#
# It downloads the release archive and SHA256SUMS from github.com, checks the archive's SHA-256,
# refuses an archive whose members escape the folder, unpacks it into a fresh temporary folder, and
# runs that release's own install.sh with the options you gave. Every other option (--harness,
# --scope, --skill, --target, --yes) is passed to install.sh unchanged, and without --yes nothing is
# written. Read the script before running it; it is short on purpose.
#
# --version X.Y.Z  install that release (default: the latest release).
# --archive FILE   use a local archive, and --sums FILE a local SHA256SUMS (tests, air-gapped copies).
#
# EXIT CODES. 0 = installed or dry run. 1 = refused or a step failed; nothing installed.
set -uo pipefail

REPO="jonyfs/pr-reviewer-fixer"
die() { echo "install-remote: $*" >&2; exit 1; }

VERSION="" ARCHIVE="" SUMS="" PASS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --version) [ $# -ge 2 ] || die "--version needs a value"; VERSION="$2"; shift 2 ;;
    --archive) [ $# -ge 2 ] || die "--archive needs a file"; ARCHIVE="$2"; shift 2 ;;
    --sums)    [ $# -ge 2 ] || die "--sums needs a file"; SUMS="$2"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) PASS+=("$1"); shift ;;
  esac
done

for tool in tar; do command -v "$tool" >/dev/null 2>&1 || die "$tool is needed; nothing installed"; done
if command -v sha256sum >/dev/null 2>&1; then SUM="sha256sum"
elif command -v shasum >/dev/null 2>&1; then SUM="shasum -a 256"
else die "sha256sum or shasum is needed to check the download; nothing installed"; fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/pr-skills-XXXXXXXX")" || die "cannot create a temporary folder"
trap 'rm -rf "$TMP"' EXIT

if [ -z "$ARCHIVE" ]; then
  command -v curl >/dev/null 2>&1 || die "curl is needed to download the release; nothing installed"
  if [ -z "$VERSION" ]; then
    VERSION="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
      | sed -n 's/.*"tag_name": *"v\{0,1\}\([0-9][0-9.]*\)".*/\1/p' | head -n 1)"
    [ -n "$VERSION" ] || die "could not read the latest release (offline, rate limit, or no release); give --version X.Y.Z"
  fi
  case "$VERSION" in *[!0-9.]*|"") die "--version must be X.Y.Z, got '$VERSION'" ;; esac
  BASE="https://github.com/$REPO/releases/download/v$VERSION"
  ARCHIVE="$TMP/pr-reviewer-fixer-$VERSION.tar.gz"
  SUMS="$TMP/SHA256SUMS"
  curl -fsSL -o "$ARCHIVE" "$BASE/pr-reviewer-fixer-$VERSION.tar.gz" || die "download of the archive failed; nothing installed"
  curl -fsSL -o "$SUMS" "$BASE/SHA256SUMS" || die "download of SHA256SUMS failed; nothing installed"
else
  [ -f "$ARCHIVE" ] || die "--archive $ARCHIVE is not a file"
  [ -n "$SUMS" ] && [ -f "$SUMS" ] || die "--archive needs --sums FILE"
  ARCHIVE_NAME="$(basename "$ARCHIVE")"
  VERSION="$(printf '%s' "$ARCHIVE_NAME" | sed -n 's/^pr-reviewer-fixer-\(.*\)\.tar\.gz$/\1/p')"
  [ -n "$VERSION" ] || die "the archive must be named pr-reviewer-fixer-X.Y.Z.tar.gz"
fi

# The checksum line for this archive. Its name must be the archive's own file name.
NAME="pr-reviewer-fixer-$VERSION.tar.gz"
WANT="$(awk -v n="$NAME" '$2 == n || $2 == "*" n { print $1; exit }' "$SUMS")"
[ -n "$WANT" ] || die "SHA256SUMS has no line for $NAME; nothing installed"
GOT="$($SUM "$ARCHIVE" | awk '{print $1}')"
[ "$GOT" = "$WANT" ] || die "SHA-256 of $NAME does not match SHA256SUMS; the download is not trusted, nothing installed"

# No member may be absolute or step out of the folder: a path with .. or a leading slash is refused.
if tar -tzf "$ARCHIVE" | awk '/^\// || /(^|\/)\.\.(\/|$)/ { bad=1 } END { exit bad }'; then :; else
  die "the archive has a member outside its folder; nothing installed"
fi
tar -xzf "$ARCHIVE" -C "$TMP" || die "could not unpack $NAME; nothing installed"

RELEASE_DIR="$TMP/pr-reviewer-fixer-$VERSION"
[ -f "$RELEASE_DIR/install.sh" ] || die "the archive has no install.sh; nothing installed"
echo "install-remote: release $VERSION, checksum verified"
bash "$RELEASE_DIR/install.sh" --source "$RELEASE_DIR/.agents/skills" ${PASS[@]+"${PASS[@]}"}
